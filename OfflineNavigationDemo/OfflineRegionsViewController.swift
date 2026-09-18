import NbmapCoreNavigation
import UIKit

@available(iOS 13.0, *)
@MainActor
/// Combined routing-data and map-tile management screen.
///
/// `OfflineRegionListRow` joins independently available routing catalog, map catalog,
/// and installed-map records by `regionId`; callers must not assume every component exists.
final class OfflineRegionsViewController: UIViewController {
    private struct HierarchyPath: Hashable {
        let components: [String]
    }

    private struct HierarchyEntry {
        let row: NBNavigation.OfflineRegionListRow
        let components: [String]
    }

    private enum VisibleItem {
        case group(
            path: HierarchyPath,
            title: String,
            level: Int,
            regionCount: Int,
            installedCount: Int
        )
        case region(row: NBNavigation.OfflineRegionListRow, level: Int)
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let refreshControl = UIRefreshControl()
    private let discoveryModeControl = UISegmentedControl(items: ["Regions", "Radius", "Route"])
    private var rows: [NBNavigation.OfflineRegionListRow] = []
    private var visibleItems: [VisibleItem] = []
    private var expandedGroups = Set<HierarchyPath>()
    private var hierarchyGroupCount = 0
    private var progressByRegion: [Int64: NBNavigation.OfflineRegionProgress] = [:]
    private var progressSubscription: NBNavigation.OfflineProgressSubscription?
    private var loadTask: Task<Void, Never>?
    private var loadRequestID = UUID()
    private var activeOperations = Set<Int64>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Offline Regions"
        view.backgroundColor = .systemBackground
        discoveryModeControl.selectedSegmentIndex = 0
        discoveryModeControl.addTarget(self, action: #selector(discoveryModeChanged), for: .valueChanged)
        discoveryModeControl.accessibilityLabel = "Offline download mode"
        navigationItem.titleView = discoveryModeControl
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.triangle.2.circlepath"),
            style: .plain,
            target: self,
            action: #selector(forceRefresh)
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(RegionCell.self, forCellReuseIdentifier: RegionCell.reuseIdentifier)
        tableView.register(
            HierarchyGroupCell.self,
            forCellReuseIdentifier: HierarchyGroupCell.reuseIdentifier
        )
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        discoveryModeControl.selectedSegmentIndex = 0
        // Page ownership is UI lifecycle state only. Ending it later stops observation owned
        // by this screen but does not cancel SDK downloads that are already in progress.
        NBNavigation.beginDownloadPageWithOwner(self)
        subscribeToProgress()
        loadRegions(syncMode: .auto)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadRequestID = UUID()
        loadTask?.cancel()
        loadTask = nil
        progressSubscription?.cancel()
        progressSubscription = nil
        NBNavigation.endDownloadPage()
    }

    deinit {
        loadTask?.cancel()
        progressSubscription?.cancel()
    }

    @objc private func refresh() {
        loadRegions(syncMode: .auto)
    }

    @objc private func forceRefresh() {
        loadRegions(syncMode: .force)
    }

    @objc private func discoveryModeChanged() {
        let mode: OfflineDiscoveryMode
        switch discoveryModeControl.selectedSegmentIndex {
        case 1:
            mode = .radius
        case 2:
            mode = .route
        default:
            return
        }

        discoveryModeControl.selectedSegmentIndex = 0
        navigationController?.pushViewController(
            OfflineDiscoveryViewController(mode: mode),
            animated: true
        )
    }

    private func subscribeToProgress() {
        guard progressSubscription == nil else { return }
        // Retain the subscription for exactly as long as this screen is visible. Canceling
        // it stops polling/UI updates; it does not pause or cancel the underlying transfer.
        progressSubscription = NBNavigation.observeOfflineRegionProgress(intervalMs: 1_000) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                progressByRegion = progress.reduce(into: [:]) { values, item in
                    values[item.regionId] = item
                }
                updateVisibleRegionCells()
            }
        }
    }

    private func updateVisibleRegionCells() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard case let .region(row, level) = item(at: indexPath) else { continue }
            guard let cell = tableView.cellForRow(at: indexPath) as? RegionCell else { continue }
            configure(cell, with: row, level: level)
        }
    }

    private func loadRegions(syncMode: RegionListSyncMode) {
        loadTask?.cancel()
        let requestID = UUID()
        loadRequestID = requestID
        navigationItem.prompt = "Initializing offline engine…"
        loadTask = Task { [weak self] in
            defer {
                // A replaced request must not stop the refresh indicator owned by the
                // newer request.
                if let self, self.loadRequestID == requestID {
                    self.refreshControl.endRefreshing()
                }
            }
            do {
                // Safe even if AppDelegate initialization is still running. This call waits
                // for that same initialization rather than racing a second engine instance.
                try await NBNavigation.initializeOffline()
                try Task.checkCancellation()
                self?.navigationItem.prompt = "Syncing region catalog…"
                _ = try await NBNavigation.syncOfflineRegionList(syncMode: syncMode)
                try Task.checkCancellation()

                // The no-argument API intentionally uses the SDK's default United States
                // catalog. Pass `countries:` only when a host app explicitly supports more.
                let result = await NBNavigation.fetchRegionLists()
                try Task.checkCancellation()
                guard let self, self.loadRequestID == requestID else { return }
                self.loadTask = nil
                rows = result.regionRows
                rebuildHierarchy()
                tableView.reloadData()
                navigationItem.prompt = "\(rows.count) regions · \(hierarchyGroupCount) administrative groups"

                // Component failures are intentionally non-fatal: keep rows assembled from
                // successful sources and surface the failed routing/map component separately.
                let warnings = [result.routeError, result.mapError, result.mapInstalledError]
                    .compactMap { $0 }
                if !warnings.isEmpty {
                    showMessage(
                        title: "Partial region data",
                        message: warnings.joined(separator: "\n")
                    )
                }
            } catch is CancellationError {
                // A newer refresh replaced this task.
            } catch {
                // Some SDK operations can report their own error after cancellation. The
                // generation check keeps that stale result from replacing newer UI state.
                guard let self, self.loadRequestID == requestID else { return }
                self.loadTask = nil
                navigationItem.prompt = "Unable to load regions"
                showMessage(title: "Offline regions", message: error.localizedDescription)
            }
        }
    }

    private func rebuildHierarchy() {
        let entries = rows.map { row in
            HierarchyEntry(row: row, components: administrativeComponents(for: row))
        }
        var items: [VisibleItem] = []
        var knownPaths = Set<HierarchyPath>()
        appendHierarchy(
            entries: entries,
            componentIndex: 0,
            parentPath: HierarchyPath(components: []),
            isVisible: true,
            items: &items,
            knownPaths: &knownPaths
        )
        expandedGroups.formIntersection(knownPaths)
        hierarchyGroupCount = knownPaths.count
        visibleItems = items
    }

    private func appendHierarchy(
        entries: [HierarchyEntry],
        componentIndex: Int,
        parentPath: HierarchyPath,
        isVisible: Bool,
        items: inout [VisibleItem],
        knownPaths: inout Set<HierarchyPath>
    ) {
        // A node can contain both a directly downloadable region and deeper administrative
        // children. Render the direct rows first, then recursively append expandable groups.
        let terminalEntries = entries
            .filter { $0.components.count <= componentIndex }
            .sorted { administrativeRegionComesBefore($0.row, $1.row) }
        if isVisible {
            items.append(contentsOf: terminalEntries.map {
                .region(row: $0.row, level: parentPath.components.count)
            })
        }

        let childEntries = entries.filter { $0.components.count > componentIndex }
        let grouped = Dictionary(grouping: childEntries) { $0.components[componentIndex] }
        for title in grouped.keys.sorted(by: localizedNameComesBefore) {
            guard let groupEntries = grouped[title] else { continue }
            let path = HierarchyPath(components: parentPath.components + [title])
            knownPaths.insert(path)
            let isExpanded = expandedGroups.contains(path)

            if isVisible {
                items.append(.group(
                    path: path,
                    title: title,
                    level: parentPath.components.count,
                    regionCount: groupEntries.count,
                    installedCount: groupEntries.filter { isInstalled($0.row) }.count
                ))
            }

            appendHierarchy(
                entries: groupEntries,
                componentIndex: componentIndex + 1,
                parentPath: path,
                isVisible: isVisible && isExpanded,
                items: &items,
                knownPaths: &knownPaths
            )
        }
    }

    private func administrativeComponents(for row: NBNavigation.OfflineRegionListRow) -> [String] {
        let rawComponents = [
            normalizedAdministrativeName(row.country, fallback: "Other countries"),
            normalizedAdministrativeName(row.adminL1),
            normalizedAdministrativeName(row.adminL2),
            normalizedAdministrativeName(row.adminL3)
        ].filter { !$0.isEmpty }

        var components: [String] = []
        for component in rawComponents where components.last?.caseInsensitiveCompare(component) != .orderedSame {
            components.append(component)
        }

        // Always retain the country + admin-L1 path. A state-level catalog row can
        // have the same display name as admin-L1 while county rows use that value
        // as their parent (for example United States > Alabama > Autauga). Removing
        // admin-L1 here would incorrectly render the state row directly below the
        // country, alongside the Alabama group.
        if components.count > 2,
           components.last?.caseInsensitiveCompare(row.displayName) == .orderedSame {
            components.removeLast()
        }
        return components.isEmpty ? ["Other countries"] : components
    }

    private func administrativeRegionComesBefore(
        _ lhs: NBNavigation.OfflineRegionListRow,
        _ rhs: NBNavigation.OfflineRegionListRow
    ) -> Bool {
        let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        return order == .orderedSame ? lhs.regionId < rhs.regionId : order == .orderedAscending
    }

    private func localizedNameComesBefore(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private func normalizedAdministrativeName(_ value: String?, fallback: String = "") -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return fallback
        }
        return value
    }

    private func isInstalled(_ row: NBNavigation.OfflineRegionListRow) -> Bool {
        (row.routeRegion?.isDownloaded ?? false) || row.mapInstalledRegion != nil
    }

    private func item(at indexPath: IndexPath) -> VisibleItem {
        visibleItems[indexPath.row]
    }

    private func toggleGroup(_ path: HierarchyPath) {
        if expandedGroups.contains(path) {
            expandedGroups.remove(path)
        } else {
            expandedGroups.insert(path)
        }
        rebuildHierarchy()
        tableView.reloadData()
    }

    private func presentActions(for row: NBNavigation.OfflineRegionListRow, sourceView: UIView?) {
        let title = "\(row.displayName) (#\(row.regionId))"
        let alert = UIAlertController(title: title, message: rowDetails(row), preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Download / Update", style: .default) { [weak self] _ in
            self?.perform(.download, row: row)
        })
        alert.addAction(UIAlertAction(title: "Pause", style: .default) { [weak self] _ in
            self?.perform(.pause, row: row)
        })
        alert.addAction(UIAlertAction(title: "Resume", style: .default) { [weak self] _ in
            self?.perform(.resume, row: row)
        })
        alert.addAction(UIAlertAction(title: "Cancel download", style: .destructive) { [weak self] _ in
            self?.perform(.cancel, row: row)
        })
        alert.addAction(UIAlertAction(title: "Delete route + map data", style: .destructive) { [weak self] _ in
            self?.confirmDelete(row)
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        preparePopover(alert, sourceView: sourceView)
        present(alert, animated: true)
    }

    private enum RegionAction {
        case download, pause, resume, cancel, delete
    }

    private func perform(_ action: RegionAction, row: NBNavigation.OfflineRegionListRow) {
        guard !activeOperations.contains(row.regionId) else { return }
        activeOperations.insert(row.regionId)
        updateVisibleRegionCells()

        Task { [weak self] in
            do {
                try await NBNavigation.initializeOffline()
                switch action {
                case .download:
                    // downloadRegion is the combined convenience API. It requires matching
                    // routing and map catalog entries for the same stable regionId.
                    guard row.routeRegion != nil, row.mapRegion != nil else {
                        throw DemoError.missingCombinedDataset
                    }
                    _ = try await NBNavigation.downloadRegion(
                        regionId: row.regionId,
                        requestTimestampMs: Int64(Date().timeIntervalSince1970 * 1_000),
                        onProgress: { _ in }
                    )
                case .pause:
                    _ = try await NBNavigation.pauseRegionDownload(regionId: row.regionId)
                case .resume:
                    _ = try await NBNavigation.resumeRegionDownload(regionId: row.regionId)
                case .cancel:
                    _ = try await NBNavigation.cancelRegionDownload(regionId: row.regionId)
                case .delete:
                    _ = try await NBNavigation.deleteRegionAllData(regionId: row.regionId)
                }
                // Combined controls are not transactional. Always reload the merged state
                // after success so the UI reflects what each routing/map sub-operation wrote.
                self?.finishRegionOperation(regionID: row.regionId, error: nil)
            } catch {
                self?.finishRegionOperation(regionID: row.regionId, error: error)
            }
        }
    }

    private func finishRegionOperation(regionID: Int64, error: Error?) {
        activeOperations.remove(regionID)
        updateVisibleRegionCells()
        if let error {
            if viewIfLoaded?.window != nil {
                showMessage(title: "Region operation failed", message: error.localizedDescription)
            }
        } else if viewIfLoaded?.window != nil {
            loadRegions(syncMode: .auto)
        }
    }

    private func confirmDelete(_ row: NBNavigation.OfflineRegionListRow) {
        let alert = UIAlertController(
            title: "Delete \(row.displayName)?",
            message: "This removes both routing and map data for region \(row.regionId).",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.perform(.delete, row: row)
        })
        present(alert, animated: true)
    }

    private func rowDetails(_ row: NBNavigation.OfflineRegionListRow) -> String {
        let hierarchy = [row.country, row.adminL1, row.adminL2, row.adminL3]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " › ")

        let route = row.routeRegion.map {
            "route: \($0.downloadStatus) · \($0.tilesDone)/\($0.tilesTotal) tiles · update \($0.updateAvailable ? "YES" : "NO")"
        } ?? "route: unavailable"
        let map = row.mapRegion.map {
            "map: \(formatBytes($0.totalSizeBytes)) · update \($0.updateAvailable ? "YES" : "NO")"
        } ?? "map: unavailable"
        let installedMap = row.mapInstalledRegion.map {
            "installed map: \($0.packageCount) packages · \($0.allPackagesOk ? "healthy" : "incomplete")"
        } ?? "installed map: no"
        let estimated = estimatedSizeDetails(row)
        return [hierarchy, estimated, route, map, installedMap]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func estimatedSizeDetails(_ row: NBNavigation.OfflineRegionListRow) -> String {
        let routeText = row.routeSizeBytes.map(formatBytes) ?? "N/A"
        let mapText = row.mapSizeBytes.map(formatBytes) ?? "N/A"
        let totalText: String
        if let routeBytes = row.routeSizeBytes, let mapBytes = row.mapSizeBytes {
            let (total, overflow) = routeBytes.addingReportingOverflow(mapBytes)
            totalText = formatBytes(overflow ? Int64.max : total)
        } else {
            // Do not display a partial sum as the combined size. A nil component means that
            // its catalog failed or has no entry, not that its size is zero.
            totalText = "N/A"
        }
        return "estimated sizes — route: \(routeText) · map: \(mapText) · total: \(totalText)"
    }

    private enum DemoError: LocalizedError {
        case missingCombinedDataset

        var errorDescription: String? {
            "This row does not contain both routing and map catalog data. Use the dataset-specific API for a route-only or map-only region."
        }
    }
}

extension OfflineRegionsViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        if visibleItems.isEmpty {
            let label = UILabel()
            label.text = "Pull to refresh the offline region catalog."
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch item(at: indexPath) {
        case let .group(path, title, level, regionCount, installedCount):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: HierarchyGroupCell.reuseIdentifier,
                for: indexPath
            ) as? HierarchyGroupCell else {
                return UITableViewCell()
            }
            cell.configure(
                title: title,
                regionCount: regionCount,
                installedCount: installedCount,
                level: level,
                expanded: expandedGroups.contains(path)
            )
            return cell

        case let .region(row, level):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: RegionCell.reuseIdentifier,
                for: indexPath
            ) as? RegionCell else {
                return UITableViewCell()
            }
            configure(cell, with: row, level: level)
            return cell
        }
    }

    private func configure(
        _ cell: RegionCell,
        with row: NBNavigation.OfflineRegionListRow,
        level: Int
    ) {
        let progress = progressByRegion[row.regionId]
        let updateAvailable = (row.routeRegion?.updateAvailable ?? false) || (row.mapRegion?.updateAvailable ?? false)
        let state = progress.map { "\($0.overallState.rawValue) · \($0.overallPercent)%" } ?? "idle"
        let busy = activeOperations.contains(row.regionId) ? " · operation pending" : ""
        let details = "\(state)\(busy)\n\(rowDetails(row))"
        cell.configure(
            title: row.displayName,
            details: details,
            progress: progress?.overallPercent,
            updateAvailable: updateAvailable,
            indentationLevel: level
        )
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch item(at: indexPath) {
        case let .group(path, _, _, _, _):
            toggleGroup(path)
        case let .region(row, _):
            presentActions(for: row, sourceView: tableView.cellForRow(at: indexPath))
        }
    }

    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard case let .region(row, _) = item(at: indexPath) else { return }
        presentActions(for: row, sourceView: tableView.cellForRow(at: indexPath))
    }
}

private final class HierarchyGroupCell: UITableViewCell {
    static let reuseIdentifier = "HierarchyGroupCell"

    private let chevronView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        textLabel?.font = .preferredFont(forTextStyle: .headline)
        textLabel?.adjustsFontForContentSizeCategory = true
        detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        detailTextLabel?.textColor = .secondaryLabel
        detailTextLabel?.adjustsFontForContentSizeCategory = true
        chevronView.tintColor = .tertiaryLabel
        chevronView.contentMode = .center
        accessoryView = chevronView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        regionCount: Int,
        installedCount: Int,
        level: Int,
        expanded: Bool
    ) {
        textLabel?.text = title
        let regions = regionCount == 1 ? "1 region" : "\(regionCount) regions"
        detailTextLabel?.text = installedCount > 0
            ? "\(regions) · \(installedCount) installed"
            : regions
        indentationLevel = level
        indentationWidth = 18
        chevronView.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
        accessibilityTraits = .button
        accessibilityLabel = title
        accessibilityValue = expanded ? "Expanded" : "Collapsed"
        accessibilityHint = "Double tap to \(expanded ? "collapse" : "expand")"
    }
}
