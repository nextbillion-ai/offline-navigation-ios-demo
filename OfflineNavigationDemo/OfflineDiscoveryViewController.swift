import CoreLocation
import Nbmap
import NbmapCoreNavigation
@preconcurrency import NbmapNavigation
import UIKit

@available(iOS 13.0, *)
enum OfflineDiscoveryMode {
    case radius
    case route

    var title: String {
        switch self {
        case .radius: return "Download by Radius"
        case .route: return "Download Along Route"
        }
    }
}

@available(iOS 13.0, *)
@MainActor
/// Finds downloadable administrative regions either around a coordinate or along
/// a generated route, then downloads the selected routing and map datasets.
final class OfflineDiscoveryViewController: UIViewController {
    private let mode: OfflineDiscoveryMode
    private let mapView = NavigationMapView(frame: .zero)
    private let controlsView = UIView()
    private let controlsStack = UIStackView()
    private let centerField = UITextField()
    private let originField = UITextField()
    private let destinationField = UITextField()
    private let radiusSlider = UISlider()
    private let radiusLabel = UILabel()
    private let queryButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let selectAllButton = UIButton(type: .system)
    private let downloadButton = UIButton(type: .system)

    private var queryTask: Task<Void, Never>?
    private var batchDownloadTask: Task<Void, Never>?
    private var progressSubscription: NBNavigation.OfflineProgressSubscription?
    private var queryID = UUID()
    private var results: [OfflineRegionLeaf] = []
    private var selectedRegionIDs = Set<Int64>()
    private var activeDownloadIDs = Set<Int64>()
    private var completedRegionIDs = Set<Int64>()
    private var installedMapRegionIDs = Set<Int64>()
    private var mapSizeByRegionID: [Int64: Int64] = [:]
    private var progressByRegionID: [Int64: NBNavigation.OfflineRegionProgress] = [:]
    private var queryIsRunning = false
    private var centerAnnotation: NGLPointAnnotation?
    private var destinationAnnotation: NGLPointAnnotation?
    private var downloadedRegionOverlay: DownloadedRegionMapOverlay?
    private var displayedRoutes: [Route] = []
    private var displayedPrimaryRoute: Route?

    private static let minimumRadiusKilometers: Float = 5
    private static let maximumRadiusKilometers: Float = 100
    private static let defaultRadiusKilometers: Float = 25

    init(mode: OfflineDiscoveryMode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mode.title
        view.backgroundColor = .systemBackground
        configureMap()
        configureControls()
        configureResults()
        configureLayout()
        updateRadiusLabel()
        updateButtons()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Pair begin/end with screen visibility. This ownership does not own the lifetime
        // of downloads, which are expected to continue after the user leaves this page.
        NBNavigation.beginDownloadPageWithOwner(self)
        NBNavigation.onOfflineMapViewWillAppear()
        NBNavigation.registerOfflineMapStyle(mapView: mapView, styleURL: mapView.styleURL)
        downloadedRegionOverlay?.refresh()
        subscribeToProgress()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        progressSubscription?.cancel()
        progressSubscription = nil
        downloadedRegionOverlay?.cancelRefresh()
        NBNavigation.endDownloadPage()
    }

    deinit {
        queryID = UUID()
        queryTask?.cancel()
        progressSubscription?.cancel()
        // Do not cancel batchDownloadTask here. SDK downloads are expected to continue after
        // leaving this page, and the task only holds weak references back to this controller.
    }

    private func configureMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsUserLocation = true
        let defaultCoordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        mapView.setCenter(defaultCoordinate, zoomLevel: 8, animated: false)
        downloadedRegionOverlay = DownloadedRegionMapOverlay(
            mapView: mapView,
            identifierPrefix: "discovery-downloaded-region"
        )

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(mapLongPressed(_:)))
        longPress.minimumPressDuration = 0.6
        mapView.addGestureRecognizer(longPress)
    }

    private func configureControls() {
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        controlsView.backgroundColor = .secondarySystemBackground
        controlsView.layer.cornerRadius = 14
        controlsView.layer.cornerCurve = .continuous

        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.axis = .vertical
        controlsStack.spacing = 8
        controlsView.addSubview(controlsStack)

        [centerField, originField, destinationField].forEach(configureCoordinateField)
        centerField.placeholder = "Center latitude,longitude"
        centerField.text = "37.774900,-122.419400"
        originField.placeholder = "Origin latitude,longitude"
        originField.text = "37.774900,-122.419400"
        destinationField.placeholder = "Destination latitude,longitude"
        destinationField.text = "37.784900,-122.409400"

        radiusSlider.minimumValue = Self.minimumRadiusKilometers
        radiusSlider.maximumValue = Self.maximumRadiusKilometers
        radiusSlider.value = Self.defaultRadiusKilometers
        radiusSlider.addTarget(self, action: #selector(radiusChanged), for: .valueChanged)
        radiusSlider.accessibilityLabel = "Download radius"

        radiusLabel.font = .preferredFont(forTextStyle: .subheadline)
        radiusLabel.textColor = .secondaryLabel
        radiusLabel.setContentHuggingPriority(.required, for: .horizontal)
        let radiusRow = UIStackView(arrangedSubviews: [radiusLabel, radiusSlider])
        radiusRow.axis = .horizontal
        radiusRow.alignment = .center
        radiusRow.spacing = 12

        queryButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        queryButton.backgroundColor = .systemBlue
        queryButton.tintColor = .white
        queryButton.layer.cornerRadius = 10
        queryButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        queryButton.addTarget(self, action: #selector(queryTapped), for: .touchUpInside)

        switch mode {
        case .radius:
            controlsStack.addArrangedSubview(centerField)
            controlsStack.addArrangedSubview(radiusRow)
            controlsStack.addArrangedSubview(queryButton)
            queryButton.setTitle("Find regions in radius", for: .normal)
            statusLabel.text = "Long-press the map to choose the center, then select a radius."
        case .route:
            controlsStack.addArrangedSubview(originField)
            controlsStack.addArrangedSubview(destinationField)
            controlsStack.addArrangedSubview(queryButton)
            queryButton.setTitle("Generate route and find regions", for: .normal)
            statusLabel.text = "Enter coordinates or long-press the map to set the destination."
        }
    }

    private func configureCoordinateField(_ field: UITextField) {
        field.borderStyle = .roundedRect
        field.keyboardType = .numbersAndPunctuation
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    private func configureResults() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.keyboardDismissMode = .onDrag

        selectAllButton.setTitle("Select all", for: .normal)
        selectAllButton.addTarget(self, action: #selector(selectAllTapped), for: .touchUpInside)

        downloadButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        downloadButton.backgroundColor = .systemGreen
        downloadButton.tintColor = .white
        downloadButton.layer.cornerRadius = 10
        downloadButton.addTarget(self, action: #selector(downloadSelectedTapped), for: .touchUpInside)
    }

    private func configureLayout() {
        let actionBar = UIStackView(arrangedSubviews: [selectAllButton, downloadButton])
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.axis = .horizontal
        actionBar.spacing = 12
        actionBar.distribution = .fillEqually

        view.addSubview(mapView)
        view.addSubview(controlsView)
        view.addSubview(statusLabel)
        view.addSubview(tableView)
        view.addSubview(actionBar)

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            mapView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.28),

            controlsView.topAnchor.constraint(equalTo: mapView.bottomAnchor, constant: 8),
            controlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            controlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            controlsStack.topAnchor.constraint(equalTo: controlsView.topAnchor, constant: 10),
            controlsStack.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 10),
            controlsStack.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -10),
            controlsStack.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor, constant: -10),

            statusLabel.topAnchor.constraint(equalTo: controlsView.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            actionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            actionBar.heightAnchor.constraint(equalToConstant: 44),

            tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -6)
        ])
    }

    private func subscribeToProgress() {
        guard progressSubscription == nil else { return }
        // The subscription drives visible UI only. SDK transfers remain active after it is
        // canceled, so retain it while visible and release it in viewWillDisappear.
        progressSubscription = NBNavigation.observeOfflineRegionProgress(intervalMs: 1_000) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                progressByRegionID = progress.reduce(into: [:]) { values, item in
                    values[item.regionId] = item
                }
                updateVisibleCells()
                updateButtons()
            }
        }
    }

    @objc private func radiusChanged() {
        updateRadiusLabel()
    }

    private func updateRadiusLabel() {
        let kilometers = radiusSlider.value
        radiusLabel.text = kilometers.rounded() == kilometers
            ? String(format: "%.0f km", kilometers)
            : String(format: "%.1f km", kilometers)
        radiusSlider.accessibilityValue = radiusLabel.text
    }

    @objc private func mapLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        view.endEditing(true)
        let point = gesture.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }

        switch mode {
        case .radius:
            centerField.text = coordinateText(coordinate)
            updateCenterAnnotation(coordinate)
            statusLabel.text = "Center selected. Adjust the radius and search."
        case .route:
            destinationField.text = coordinateText(coordinate)
            updateDestinationAnnotation(coordinate)
            statusLabel.text = "Destination selected. Generate the route to find matching regions."
        }
    }

    @objc private func queryTapped() {
        view.endEditing(true)
        switch mode {
        case .radius:
            findRegionsInRadius()
        case .route:
            findRegionsAlongRoute()
        }
    }

    private func findRegionsInRadius() {
        guard let coordinate = parseCoordinate(centerField.text) else {
            showMessage(title: "Invalid center", message: "Use latitude,longitude, for example 37.7749,-122.4194.")
            return
        }
        updateCenterAnnotation(coordinate)
        mapView.setCenter(coordinate, zoomLevel: radiusZoomLevel(radiusSlider.value), animated: true)

        let radiusMeters = Double(radiusSlider.value) * 1_000
        startQuery(status: "Finding regions in the selected radius…") { [coordinate] in
            let catalog = try await NBNavigation.getCountiesInRadius(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMeters: radiusMeters
            )
            return catalog.leaves
        }
    }

    private func findRegionsAlongRoute() {
        guard SDKConfiguration.hasUsableAPIKey else {
            showMessage(
                title: "API key required",
                message: "Replace YOUR_NEXTBILLION_API_KEY in Info.plist before requesting a route."
            )
            return
        }
        guard let origin = parseCoordinate(originField.text),
              let destination = parseCoordinate(destinationField.text) else {
            showMessage(title: "Invalid coordinates", message: "Use latitude,longitude for both route endpoints.")
            return
        }

        updateDestinationAnnotation(destination)
        let waypoints = [
            Waypoint(coordinate: origin, name: "Origin"),
            Waypoint(coordinate: destination, name: "Destination")
        ]
        let options = NavigationRouteOptions(waypoints: waypoints, profile: .truck)
        // Keep discovery consistent with Route & Navigate: the recommended regions must
        // cover the same truck route the user will later navigate.
        TruckConfigurationStore.load().apply(to: options)
        let routingConfig = RoutingConfig(
            mode: .onlineOnly,
            onlineTimeoutMs: 20_000,
            offlineTimeoutMs: 20_000,
            onlineRetryCount: 1
        )

        startQuery(status: "Generating route…") { [weak self] in
            let routeResult = try await NBNavigation.fetchRoute(options: options, routingConfig: routingConfig)
            try Task.checkCancellation()
            guard let route = routeResult.routes.first else {
                throw DiscoveryError.noRoute
            }
            self?.showRoute(routeResult.routes, primaryRoute: route)
            self?.setQueryStatus("Finding regions along the route…")
            let catalog = try await NBNavigation.getCountiesAlongRoute(route: route)
            return catalog.leaves
        }
    }

    private func startQuery(
        status: String,
        operation: @escaping () async throws -> [OfflineRegionLeaf]
    ) {
        queryID = UUID()
        let requestID = queryID
        queryTask?.cancel()
        queryIsRunning = true
        results = []
        selectedRegionIDs.removeAll()
        statusLabel.text = status
        tableView.reloadData()
        updateButtons()

        queryTask = Task { [weak self] in
            do {
                // Region recommendation can retrieve missing catalog detail. Initialize and
                // synchronize first so returned leaves contain current names, sizes and state.
                try await NBNavigation.initializeOffline()
                try Task.checkCancellation()
                _ = try await NBNavigation.syncOfflineRegionList(syncMode: .auto)
                try Task.checkCancellation()
                let regions = try await operation()
                try Task.checkCancellation()
                // Match the sample's United States catalog scope. Applications that expose
                // other countries should pass the same explicit country list on every screen.
                let regionLists = await NBNavigation.fetchRegionLists()
                try Task.checkCancellation()
                guard let self, self.queryID == requestID else { return }
                self.queryTask = nil
                self.queryIsRunning = false
                self.applyRegionMetadata(regionLists)
                self.applyQueryResults(regions)
            } catch is CancellationError {
                guard let self, self.queryID == requestID else { return }
                self.queryTask = nil
                self.queryIsRunning = false
                self.statusLabel.text = "Query cancelled."
                self.updateButtons()
            } catch {
                guard let self, self.queryID == requestID else { return }
                self.queryTask = nil
                self.queryIsRunning = false
                self.statusLabel.text = "Query failed: \(error.localizedDescription)"
                self.updateButtons()
                self.showMessage(title: "Unable to find regions", message: error.localizedDescription)
            }
        }
    }

    private func applyQueryResults(_ regions: [OfflineRegionLeaf]) {
        var seen = Set<Int64>()
        results = regions
            .filter { seen.insert($0.regionId).inserted }
            .sorted(by: regionComesBefore)
        selectedRegionIDs.removeAll()
        statusLabel.text = results.isEmpty
            ? "No matching downloadable regions were found."
            : "Found \(results.count) regions. Select the regions to download."
        tableView.reloadData()
        updateButtons()
    }

    private func applyRegionMetadata(_ regionLists: NBNavigation.OfflineRegionListResult) {
        var installedMapIDs = Set<Int64>()
        var mapSizes: [Int64: Int64] = [:]

        for row in regionLists.regionRows {
            if let installedMap = row.mapInstalledRegion {
                installedMapIDs.insert(row.regionId)
                if installedMap.totalBytes > 0 {
                    mapSizes[row.regionId] = installedMap.totalBytes
                }
            }
            if let mapSize = row.mapSizeBytes, mapSize > 0 {
                mapSizes[row.regionId] = mapSize
            } else if let catalogMapSize = row.mapRegion?.totalSizeBytes, catalogMapSize > 0 {
                mapSizes[row.regionId] = catalogMapSize
            }
        }

        for mapRegion in regionLists.mapRegionList?.regions ?? [] where mapRegion.totalSizeBytes > 0 {
            if mapSizes[mapRegion.regionId] == nil {
                mapSizes[mapRegion.regionId] = mapRegion.totalSizeBytes
            }
        }

        for installedMap in regionLists.mapInstalledRegionList ?? [] where installedMap.totalBytes > 0 {
            installedMapIDs.insert(installedMap.regionId)
            if mapSizes[installedMap.regionId] == nil {
                mapSizes[installedMap.regionId] = installedMap.totalBytes
            }
        }

        installedMapRegionIDs = installedMapIDs
        mapSizeByRegionID = mapSizes
    }

    @objc private func selectAllTapped() {
        let eligibleIDs = Set(results.filter { isDownloadEligible($0) }.map(\.regionId))
        if !eligibleIDs.isEmpty, eligibleIDs.isSubset(of: selectedRegionIDs) {
            selectedRegionIDs.subtract(eligibleIDs)
        } else {
            selectedRegionIDs.formUnion(eligibleIDs)
        }
        tableView.reloadData()
        updateButtons()
    }

    @objc private func downloadSelectedTapped() {
        guard batchDownloadTask == nil else { return }
        let regions = results.filter {
            selectedRegionIDs.contains($0.regionId) && isDownloadEligible($0)
        }
        guard !regions.isEmpty else { return }

        let batchRegionIDs = Set(regions.map(\.regionId))
        selectedRegionIDs.subtract(batchRegionIDs)
        activeDownloadIDs.formUnion(batchRegionIDs)
        statusLabel.text = "Queued \(regions.count) region(s) for sequential download."
        tableView.reloadData()
        updateButtons()

        batchDownloadTask = Task { [weak self] in
            // Sequential requests keep this reference UI deterministic and avoid starting a
            // large number of routing + map transfers at once. SDK downloads themselves may
            // continue even if this view controller is released.
            var wasCancelled = false
            defer {
                self?.finishBatchDownload(
                    regionIDs: batchRegionIDs,
                    wasCancelled: wasCancelled
                )
            }
            for region in regions {
                guard !Task.isCancelled else { return }
                do {
                    let result = try await NBNavigation.downloadRegion(
                        regionId: region.regionId,
                        requestTimestampMs: Int64(Date().timeIntervalSince1970 * 1_000),
                        onProgress: { [weak self] _ in
                            Task { @MainActor [weak self] in
                                self?.updateVisibleCells()
                            }
                        }
                    )
                    guard result.errorCode == 0, result.downloadStatus != .failed else {
                        throw DiscoveryError.downloadFailed(region.displayName)
                    }
                    self?.markDownloadCompleted(regionID: region.regionId)
                } catch is CancellationError {
                    wasCancelled = true
                    self?.markDownloadStopped(regionID: region.regionId)
                    return
                } catch {
                    self?.markDownloadFailed(region: region, error: error)
                }
            }
        }
        updateButtons()
    }

    private func markDownloadCompleted(regionID: Int64) {
        activeDownloadIDs.remove(regionID)
        completedRegionIDs.insert(regionID)
        installedMapRegionIDs.insert(regionID)
        downloadedRegionOverlay?.refresh()
        updateVisibleCells()
        updateButtons()
    }

    private func markDownloadStopped(regionID: Int64) {
        activeDownloadIDs.remove(regionID)
        updateVisibleCells()
        updateButtons()
    }

    private func markDownloadFailed(region: OfflineRegionLeaf, error: Error) {
        activeDownloadIDs.remove(region.regionId)
        statusLabel.text = "\(region.displayName) failed: \(error.localizedDescription)"
        updateVisibleCells()
        updateButtons()
    }

    private func finishBatchDownload(regionIDs: Set<Int64>, wasCancelled: Bool) {
        // Cancellation may occur before later sequential items start. Clear the whole batch
        // so no row remains stuck in a synthetic "Downloading 0%" state.
        activeDownloadIDs.subtract(regionIDs)
        batchDownloadTask = nil
        if activeDownloadIDs.isEmpty {
            statusLabel.text = wasCancelled
                ? "Selected region downloads stopped."
                : "Selected region downloads finished."
        }
        updateButtons()
    }

    private func updateButtons() {
        let hasActiveBatch = batchDownloadTask != nil
        queryButton.isEnabled = !queryIsRunning && !hasActiveBatch
        queryButton.alpha = queryButton.isEnabled ? 1 : 0.55

        let eligibleIDs = Set(results.filter { isDownloadEligible($0) }.map(\.regionId))
        let allSelected = !eligibleIDs.isEmpty && eligibleIDs.isSubset(of: selectedRegionIDs)
        selectAllButton.setTitle(allSelected ? "Clear selection" : "Select all", for: .normal)
        selectAllButton.isEnabled = !eligibleIDs.isEmpty

        let selectedCount = selectedRegionIDs.intersection(eligibleIDs).count
        downloadButton.setTitle(
            selectedCount == 0 ? "Select regions" : "Download selected (\(selectedCount))",
            for: .normal
        )
        downloadButton.isEnabled = selectedCount > 0 && !hasActiveBatch
        downloadButton.alpha = downloadButton.isEnabled ? 1 : 0.45
    }

    private func updateVisibleCells() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard results.indices.contains(indexPath.row),
                  let cell = tableView.cellForRow(at: indexPath) else { continue }
            configure(cell, region: results[indexPath.row])
        }
    }

    private func configure(_ cell: UITableViewCell, region: OfflineRegionLeaf) {
        cell.textLabel?.text = region.displayName
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.numberOfLines = 1
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel

        let progress = progressByRegionID[region.regionId]
        let status: String
        if completedRegionIDs.contains(region.regionId) || progress?.overallState == .completed {
            status = "Downloaded"
        } else if activeDownloadIDs.contains(region.regionId) {
            status = "Downloading \(progress?.overallPercent ?? 0)%"
        } else if region.isDownloaded && installedMapRegionIDs.contains(region.regionId) {
            status = "Downloaded"
        } else if region.isDownloaded {
            status = "Routing data installed"
        } else {
            status = "Not downloaded"
        }
        let path = administrativePath(region)
        let details = [path, sizeSummary(region), status].filter { !$0.isEmpty }
        cell.detailTextLabel?.text = details.joined(separator: "\n")

        if !isDownloadEligible(region) {
            cell.accessoryType = .checkmark
            cell.tintColor = .systemGreen
            cell.selectionStyle = .none
        } else {
            cell.accessoryType = selectedRegionIDs.contains(region.regionId) ? .checkmark : .none
            cell.tintColor = .systemBlue
            cell.selectionStyle = .default
        }
    }

    private func isDownloadEligible(_ region: OfflineRegionLeaf) -> Bool {
        if activeDownloadIDs.contains(region.regionId) || completedRegionIDs.contains(region.regionId) {
            return false
        }
        if let progress = progressByRegionID[region.regionId] {
            return progress.overallState != .running
                && progress.overallState != .queued
                && progress.overallState != .completed
        }
        return !(region.isDownloaded && installedMapRegionIDs.contains(region.regionId))
    }

    private func sizeSummary(_ region: OfflineRegionLeaf) -> String {
        // Radius/route recommendation returns routing leaves. Map size comes from the merged
        // map catalog or live map progress and may legitimately remain unavailable.
        let routeBytes = max(0, region.totalSizeBytes)
        let observedMapBytes = progressByRegionID[region.regionId]?.mapTile?.total
        let mapBytes = mapSizeByRegionID[region.regionId]
            ?? observedMapBytes.flatMap { $0 > 0 ? $0 : nil }
        let mapText = mapBytes.map(formatBytes) ?? "N/A"
        let totalText = mapBytes.map { mapBytes in
            let (totalBytes, overflow) = routeBytes.addingReportingOverflow(mapBytes)
            return formatBytes(overflow ? Int64.max : totalBytes)
        } ?? "N/A"
        return "Route \(formatBytes(routeBytes)) · Map \(mapText) · Total \(totalText)"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func showRoute(_ routes: [Route], primaryRoute: Route) {
        guard !routes.isEmpty else { return }
        displayedRoutes = routes
        displayedPrimaryRoute = primaryRoute
        mapView.removeRoutes()
        mapView.removeWaypoints()
        mapView.showRoutes(routes)
        mapView.showWaypoints(primaryRoute)
        mapView.showcase(
            routes,
            padding: UIEdgeInsets(top: 24, left: 28, bottom: 24, right: 28),
            animated: true
        )
    }

    private func setQueryStatus(_ text: String) {
        statusLabel.text = text
    }

    private func updateCenterAnnotation(_ coordinate: CLLocationCoordinate2D) {
        if let centerAnnotation {
            mapView.removeAnnotation(centerAnnotation)
        }
        let annotation = NGLPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = "Radius center"
        mapView.addAnnotation(annotation)
        centerAnnotation = annotation
    }

    private func updateDestinationAnnotation(_ coordinate: CLLocationCoordinate2D) {
        if let destinationAnnotation {
            mapView.removeAnnotation(destinationAnnotation)
        }
        let annotation = NGLPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = "Destination"
        mapView.addAnnotation(annotation)
        destinationAnnotation = annotation
    }

    private func parseCoordinate(_ text: String?) -> CLLocationCoordinate2D? {
        let parts = (text ?? "").split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]),
              latitude.isFinite,
              longitude.isFinite else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }

    private func radiusZoomLevel(_ radiusKilometers: Float) -> Double {
        switch radiusKilometers {
        case ..<10: return 9
        case ..<25: return 8
        case ..<50: return 7
        default: return 6
        }
    }

    private func administrativePath(_ region: OfflineRegionLeaf) -> String {
        var components = [region.country, region.adminL1, region.adminL2, region.adminL3]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if components.last?.caseInsensitiveCompare(region.displayName) == .orderedSame {
            components.removeLast()
        }
        return components.joined(separator: " › ")
    }

    private func regionComesBefore(_ lhs: OfflineRegionLeaf, _ rhs: OfflineRegionLeaf) -> Bool {
        let left = [lhs.country, lhs.adminL1, lhs.adminL2, lhs.adminL3, lhs.displayName]
        let right = [rhs.country, rhs.adminL1, rhs.adminL2, rhs.adminL3, rhs.displayName]
        for (leftPart, rightPart) in zip(left, right) {
            let order = leftPart.localizedCaseInsensitiveCompare(rightPart)
            if order != .orderedSame {
                return order == .orderedAscending
            }
        }
        return lhs.regionId < rhs.regionId
    }

    private enum DiscoveryError: LocalizedError {
        case noRoute
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .noRoute:
                return "The SDK returned no route."
            case let .downloadFailed(name):
                return "The download for \(name) did not complete."
            }
        }
    }
}

@available(iOS 13.0, *)
extension OfflineDiscoveryViewController: @preconcurrency NGLMapViewDelegate {
    func mapView(_ mapView: NGLMapView, didFinishLoading style: NGLStyle) {
        // Runtime layers and route sources are removed by a style reload. Restore offline
        // registration, installed-region boundaries and the generated route in that order.
        NBNavigation.registerOfflineMapStyle(mapView: mapView, styleURL: mapView.styleURL)
        downloadedRegionOverlay?.refresh()

        guard mode == .route,
              !displayedRoutes.isEmpty,
              let displayedPrimaryRoute else { return }
        self.mapView.showRoutes(displayedRoutes)
        self.mapView.showWaypoints(displayedPrimaryRoute)
    }
}

@available(iOS 13.0, *)
extension OfflineDiscoveryViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if results.isEmpty {
            let label = UILabel()
            label.text = queryIsRunning ? "Finding matching regions…" : "Run a query to find downloadable regions."
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
        return results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard results.indices.contains(indexPath.row) else { return UITableViewCell() }
        let reuseIdentifier = "DiscoveryRegionDetailCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: reuseIdentifier)
        configure(cell, region: results[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard results.indices.contains(indexPath.row) else { return }
        let region = results[indexPath.row]
        guard isDownloadEligible(region) else { return }
        if selectedRegionIDs.contains(region.regionId) {
            selectedRegionIDs.remove(region.regionId)
        } else {
            selectedRegionIDs.insert(region.regionId)
        }
        if let cell = tableView.cellForRow(at: indexPath) {
            configure(cell, region: region)
        }
        updateButtons()
    }
}
