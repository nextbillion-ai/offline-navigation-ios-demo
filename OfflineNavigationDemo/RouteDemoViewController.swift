import CoreLocation
import Nbmap
import NbmapCoreNavigation
@preconcurrency import NbmapNavigation
import UIKit

@available(iOS 13.0, *)
@MainActor
/// End-to-end route example: collect coordinates, build truck route options,
/// select an online/offline strategy, display the result, and launch Default UI.
final class RouteDemoViewController: UIViewController {
    private let mapView = NavigationMapView(frame: .zero)
    private let originField = UITextField()
    private let destinationField = UITextField()
    private let routeMode = UISegmentedControl(items: ["Smart", "Online", "Offline"])
    private let simulationSwitch = UISwitch()
    private let statusLabel = UILabel()
    private let installedRegionsButton = UIButton(type: .system)
    private let truckSettingsButton = UIButton(type: .system)
    private let requestButton = UIButton(type: .system)
    private let startNavigationButton = UIButton(type: .system)
    private let controlPanel = UIView()
    private var controlPanelBottomConstraint: NSLayoutConstraint?

    private var requestTask: Task<Void, Never>?
    private var routeRequestID = UUID()
    private var installedRegionsTask: Task<Void, Never>?
    private var installedRegionsRequestID = UUID()
    private var currentRoutes: [Route] = []
    private var currentRouteOptions: NavigationRouteOptions?
    private var installedRows: [NBNavigation.OfflineRegionListRow] = []
    private var selectedDestinationAnnotation: NGLPointAnnotation?
    private var downloadedRegionOverlay: DownloadedRegionMapOverlay?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Route & Navigate"
        view.backgroundColor = .systemBackground

        configureMap()
        configureControls()
        configureLayout()
        configureKeyboardHandling()

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self,
            action: #selector(refreshInstalledRegions)
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Register the currently active style every time the screen becomes visible.
        // This lets the SDK redirect style tile requests to installed offline packages.
        NBNavigation.onOfflineMapViewWillAppear()
        NBNavigation.registerOfflineMapStyle(mapView: mapView, styleURL: mapView.styleURL)
        downloadedRegionOverlay?.refresh()
        updateTruckSettingsButton()
        loadInstalledRegions()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        downloadedRegionOverlay?.cancelRefresh()
    }

    deinit {
        requestTask?.cancel()
        installedRegionsTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.setCenter(
            CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            zoomLevel: 11,
            animated: false
        )
        downloadedRegionOverlay = DownloadedRegionMapOverlay(
            mapView: mapView,
            identifierPrefix: "route-downloaded-region"
        )

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(mapLongPressed(_:)))
        longPress.minimumPressDuration = 0.65
        mapView.addGestureRecognizer(longPress)
    }

    private func configureControls() {
        [originField, destinationField].forEach {
            $0.borderStyle = .roundedRect
            $0.keyboardType = .numbersAndPunctuation
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
            $0.clearButtonMode = .whileEditing
            $0.delegate = self
            $0.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        }
        originField.placeholder = "Origin latitude,longitude"
        originField.text = "37.7749,-122.4194"
        originField.returnKeyType = .next
        originField.accessibilityLabel = "Origin coordinates"
        destinationField.placeholder = "Destination latitude,longitude"
        destinationField.text = "37.7849,-122.4094"
        destinationField.returnKeyType = .go
        destinationField.accessibilityLabel = "Destination coordinates"

        routeMode.selectedSegmentIndex = 0
        routeMode.accessibilityLabel = "Routing mode"

        simulationSwitch.isOn = true
        simulationSwitch.accessibilityLabel = "Simulate navigation"

        installedRegionsButton.setTitle("Installed offline regions: Loading…", for: .normal)
        installedRegionsButton.contentHorizontalAlignment = .left
        installedRegionsButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        installedRegionsButton.titleLabel?.numberOfLines = 2
        installedRegionsButton.addTarget(self, action: #selector(showInstalledRegions), for: .touchUpInside)

        truckSettingsButton.contentHorizontalAlignment = .left
        truckSettingsButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        truckSettingsButton.titleLabel?.numberOfLines = 2
        truckSettingsButton.setImage(UIImage(systemName: "truck.box"), for: .normal)
        truckSettingsButton.tintColor = .systemBlue
        truckSettingsButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        truckSettingsButton.accessibilityLabel = "Truck settings"
        truckSettingsButton.addTarget(self, action: #selector(showTruckSettings), for: .touchUpInside)
        updateTruckSettingsButton()

        configurePrimaryButton(requestButton, title: "Generate route")
        requestButton.addTarget(self, action: #selector(requestRouteFromFields), for: .touchUpInside)

        configurePrimaryButton(startNavigationButton, title: "Start navigation")
        startNavigationButton.addTarget(self, action: #selector(startNavigation), for: .touchUpInside)
        setStartNavigationEnabled(false)

        statusLabel.text = "Long-press the map to select a destination, or enter coordinates."
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.numberOfLines = 0

        controlPanel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
        controlPanel.layer.cornerRadius = 16
        controlPanel.layer.cornerCurve = .continuous
        controlPanel.layer.shadowColor = UIColor.black.cgColor
        controlPanel.layer.shadowOpacity = 0.14
        controlPanel.layer.shadowRadius = 12
        controlPanel.layer.shadowOffset = CGSize(width: 0, height: 4)
        controlPanel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureLayout() {
        let instructionLabel = UILabel()
        instructionLabel.text = "Long-press anywhere on the map to route there"
        instructionLabel.font = .preferredFont(forTextStyle: .subheadline)
        instructionLabel.textAlignment = .center
        instructionLabel.textColor = .label
        instructionLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.88)
        instructionLabel.layer.cornerRadius = 10
        instructionLabel.layer.masksToBounds = true
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false

        let simulationLabel = UILabel()
        simulationLabel.text = "Simulate navigation"
        simulationLabel.font = .preferredFont(forTextStyle: .subheadline)

        let simulationRow = UIStackView(arrangedSubviews: [simulationLabel, simulationSwitch])
        simulationRow.axis = .horizontal
        simulationRow.alignment = .center
        simulationRow.distribution = .equalSpacing

        let buttonRow = UIStackView(arrangedSubviews: [requestButton, startNavigationButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 10
        buttonRow.distribution = .fillEqually

        let contentStack = UIStackView(arrangedSubviews: [
            installedRegionsButton,
            truckSettingsButton,
            originField,
            destinationField,
            routeMode,
            simulationRow,
            buttonRow,
            statusLabel
        ])
        contentStack.axis = .vertical
        contentStack.spacing = 9
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(mapView)
        view.addSubview(instructionLabel)
        view.addSubview(controlPanel)
        controlPanel.addSubview(contentStack)

        let panelBottom = controlPanel.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: -10
        )
        controlPanelBottomConstraint = panelBottom

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            instructionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            instructionLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            instructionLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

            controlPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            controlPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            panelBottom,

            contentStack.topAnchor.constraint(equalTo: controlPanel.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: controlPanel.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: controlPanel.trailingAnchor, constant: -14),
            contentStack.bottomAnchor.constraint(equalTo: controlPanel.bottomAnchor, constant: -12)
        ])
    }

    private func configureKeyboardHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    private func configurePrimaryButton(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.backgroundColor = .systemBlue
        button.tintColor = .white
        button.layer.cornerRadius = 10
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }

        let keyboardFrame = view.convert(endFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY - view.safeAreaInsets.bottom)
        controlPanelBottomConstraint?.constant = -(overlap + 10)

        let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func mapLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        view.endEditing(true)

        let point = gesture.location(in: mapView)
        let destination = mapView.convert(point, toCoordinateFrom: mapView)
        destinationField.text = coordinateText(destination)
        updateDestinationAnnotation(destination)

        let origin = usableUserCoordinate ?? parseCoordinate(originField.text)
        if let currentLocation = usableUserCoordinate {
            originField.text = coordinateText(currentLocation)
            statusLabel.text = "Using current location as the origin. Requesting the selected destination…"
        } else {
            statusLabel.text = "Current location is unavailable. Using the origin field…"
        }
        requestRoute(origin: origin, destination: destination)
    }

    @objc private func requestRouteFromFields() {
        view.endEditing(true)
        requestRoute(
            origin: parseCoordinate(originField.text),
            destination: parseCoordinate(destinationField.text)
        )
    }

    private func requestRoute(origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?) {
        guard SDKConfiguration.hasUsableAPIKey else {
            showMessage(
                title: "API key required",
                message: "Replace YOUR_NEXTBILLION_API_KEY in Info.plist before requesting a route."
            )
            return
        }
        guard let origin, let destination else {
            showMessage(title: "Invalid coordinates", message: "Use latitude,longitude, for example 37.7749,-122.4194.")
            return
        }

        updateDestinationAnnotation(destination)
        let waypoints = [
            Waypoint(coordinate: origin, name: "Origin"),
            Waypoint(coordinate: destination, name: "Destination")
        ]
        let options = NavigationRouteOptions(waypoints: waypoints, profile: .truck)
        // Truck size uses [height, width, length] in centimeters; weight uses kilograms.
        TruckConfigurationStore.load().apply(to: options)
        let mode = selectedRouteMode
        let config = RoutingConfig(
            mode: mode,
            onlineTimeoutMs: 20_000,
            offlineTimeoutMs: 20_000,
            onlineRetryCount: 1
        )

        requestTask?.cancel()
        let requestID = UUID()
        routeRequestID = requestID
        currentRoutes = []
        currentRouteOptions = nil
        mapView.removeRoutes()
        mapView.removeWaypoints()
        requestButton.isEnabled = false
        setStartNavigationEnabled(false)
        statusLabel.text = "Requesting route…"

        requestTask = Task { [weak self] in
            do {
                // Online-only requests do not require the offline engine. Every other mode
                // may select local routing and must ensure that initialization has started.
                if mode != .onlineOnly {
                    try await NBNavigation.initializeOffline()
                }
                let result = try await NBNavigation.fetchRoute(options: options, routingConfig: config)
                try Task.checkCancellation()
                guard let primaryRoute = result.routes.first else {
                    throw DemoRouteError.emptyRoutes
                }
                // A canceled SDK operation can finish after a newer request starts. The ID
                // prevents that stale result from replacing the newer route or button state.
                guard let self, self.routeRequestID == requestID else { return }
                self.requestTask = nil
                self.requestButton.isEnabled = true

                self.currentRoutes = result.routes
                self.currentRouteOptions = options
                self.mapView.showRoutes(result.routes)
                self.mapView.showWaypoints(primaryRoute)
                self.mapView.showcase(
                    result.routes,
                    padding: UIEdgeInsets(top: 90, left: 36, bottom: 330, right: 36),
                    animated: true
                )
                self.setStartNavigationEnabled(true)

                let source = result.source == .online ? "online" : "offline"
                let distance = MeasurementFormatter().string(
                    from: Measurement(value: primaryRoute.distance / 1_000, unit: UnitLength.kilometers)
                )
                let durationMinutes = max(1, Int(primaryRoute.expectedTravelTime / 60))
                self.statusLabel.text = "Truck · \(result.routes.count) route(s) · \(source) · \(distance) · about \(durationMinutes) min"
            } catch is CancellationError {
                guard let self, self.routeRequestID == requestID else { return }
                self.requestTask = nil
                self.requestButton.isEnabled = true
                self.statusLabel.text = "Route request cancelled."
            } catch {
                guard let self, self.routeRequestID == requestID else { return }
                self.requestTask = nil
                self.requestButton.isEnabled = true
                self.statusLabel.text = "Route failed: \(error.localizedDescription)"
                self.showMessage(title: "Route request failed", message: error.localizedDescription)
            }
        }
    }

    @objc private func startNavigation() {
        guard !currentRoutes.isEmpty, let options = currentRouteOptions else { return }
        presentNavigation(routes: currentRoutes, options: options)
    }

    @objc private func refreshInstalledRegions() {
        loadInstalledRegions()
    }

    @objc private func showTruckSettings() {
        let controller = TruckSettingsViewController(configuration: TruckConfigurationStore.load())
        controller.onSave = { [weak self] configuration in
            self?.applySavedTruckConfiguration(configuration)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func applySavedTruckConfiguration(_ configuration: TruckConfiguration) {
        // A displayed route is tied to the options used to create it. Invalidate it so the
        // user cannot start navigation with dimensions that no longer match the settings UI.
        routeRequestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        currentRoutes = []
        currentRouteOptions = nil
        mapView.removeRoutes()
        mapView.removeWaypoints()
        setStartNavigationEnabled(false)
        updateTruckSettingsButton(configuration)
        statusLabel.text = "Truck settings saved. Generate a new route to apply them."
    }

    private func updateTruckSettingsButton(
        _ configuration: TruckConfiguration = TruckConfigurationStore.load()
    ) {
        truckSettingsButton.setTitle("  Truck settings\n  \(configuration.summary)", for: .normal)
    }

    private func loadInstalledRegions() {
        installedRegionsTask?.cancel()
        let requestID = UUID()
        installedRegionsRequestID = requestID
        installedRegionsButton.isEnabled = false
        installedRegionsButton.setTitle("Installed offline regions: Loading…", for: .normal)

        installedRegionsTask = Task { [weak self] in
            do {
                try await NBNavigation.initializeOffline()
                try Task.checkCancellation()
                // Use the same default United States scope as the Regions screen.
                let result = await NBNavigation.fetchRegionLists()
                try Task.checkCancellation()
                guard let self, self.installedRegionsRequestID == requestID else { return }
                self.installedRegionsTask = nil
                self.installedRegionsButton.isEnabled = true

                self.installedRows = result.regionRows
                    .filter { $0.routeRegion?.isDownloaded == true || $0.mapInstalledRegion != nil }
                    .sorted(by: administrativeRegionComesBefore)
                self.updateInstalledRegionsDisplay()

                if let installedError = result.mapInstalledError {
                    self.statusLabel.text = "Installed map packages could not be fully read: \(installedError)"
                }
            } catch is CancellationError {
                // A newer refresh replaced this task.
            } catch {
                guard let self, self.installedRegionsRequestID == requestID else { return }
                self.installedRegionsTask = nil
                self.installedRegionsButton.isEnabled = true
                self.installedRows = []
                self.downloadedRegionOverlay?.remove()
                self.installedRegionsButton.setTitle("Installed offline regions: Unavailable", for: .normal)
                self.statusLabel.text = "Unable to read installed regions: \(error.localizedDescription)"
            }
        }
    }

    private func updateInstalledRegionsDisplay() {
        downloadedRegionOverlay?.refresh()

        guard !installedRows.isEmpty else {
            installedRegionsButton.setTitle("Installed offline regions: None", for: .normal)
            return
        }

        let visibleNames = installedRows.prefix(3).map(\.displayName).joined(separator: ", ")
        let remaining = installedRows.count - min(installedRows.count, 3)
        let suffix = remaining > 0 ? " +\(remaining) more" : ""
        installedRegionsButton.setTitle(
            "Installed offline regions (\(installedRows.count)): \(visibleNames)\(suffix)",
            for: .normal
        )
    }

    @objc private func showInstalledRegions() {
        guard !installedRows.isEmpty else {
            showMessage(title: "Installed offline regions", message: "No routing or map region is currently installed.")
            return
        }

        let alert = UIAlertController(
            title: "Installed offline regions",
            message: "Select a region to focus it on the map.",
            preferredStyle: .actionSheet
        )
        for row in installedRows.prefix(20) {
            alert.addAction(UIAlertAction(
                title: "\(administrativePath(row)) · \(installedStateText(row))",
                style: .default
            ) { [weak self] _ in
                self?.focusInstalledRegion(row)
            })
        }
        if installedRows.count > 20 {
            alert.message = "Showing the first 20 of \(installedRows.count) regions."
        }
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        preparePopover(alert, sourceView: installedRegionsButton)
        present(alert, animated: true)
    }

    private func focusInstalledRegion(_ row: NBNavigation.OfflineRegionListRow) {
        do {
            let focused = try NBNavigation.focusOfflineMapRegion(
                mapView: mapView,
                regionId: String(row.regionId)
            )
            if !focused, let bounds = row.routeRegion?.boundaryBbox {
                let coordinateBounds = NGLCoordinateBoundsMake(
                    CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLon),
                    CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.maxLon)
                )
                mapView.setVisibleCoordinateBounds(
                    coordinateBounds,
                    edgePadding: UIEdgeInsets(top: 80, left: 32, bottom: 330, right: 32),
                    animated: true,
                    completionHandler: nil
                )
            }
            statusLabel.text = "Focused installed region: \(row.displayName) · \(installedStateText(row))"
        } catch {
            showMessage(title: "Unable to focus region", message: error.localizedDescription)
        }
    }

    private func installedStateText(_ row: NBNavigation.OfflineRegionListRow) -> String {
        var components: [String] = []
        if row.routeRegion?.isDownloaded == true {
            components.append("routing")
        }
        if let map = row.mapInstalledRegion {
            components.append(map.allPackagesOk ? "map" : "map incomplete")
        }
        return components.isEmpty ? "unknown" : components.joined(separator: " + ")
    }

    private func administrativeRegionComesBefore(
        _ lhs: NBNavigation.OfflineRegionListRow,
        _ rhs: NBNavigation.OfflineRegionListRow
    ) -> Bool {
        let leftPath = administrativeComponents(lhs) + [lhs.displayName]
        let rightPath = administrativeComponents(rhs) + [rhs.displayName]
        for (left, right) in zip(leftPath, rightPath) {
            let order = left.localizedCaseInsensitiveCompare(right)
            if order != .orderedSame {
                return order == .orderedAscending
            }
        }
        return lhs.regionId < rhs.regionId
    }

    private func administrativePath(_ row: NBNavigation.OfflineRegionListRow) -> String {
        var path = administrativeComponents(row)
        if path.last?.localizedCaseInsensitiveCompare(row.displayName) != .orderedSame {
            path.append(row.displayName)
        }
        return path.isEmpty ? row.displayName : path.joined(separator: " › ")
    }

    private func administrativeComponents(_ row: NBNavigation.OfflineRegionListRow) -> [String] {
        [row.country, row.adminL1, row.adminL2, row.adminL3]
            .compactMap { value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    return nil
                }
                return value
            }
    }

    private func updateDestinationAnnotation(_ coordinate: CLLocationCoordinate2D) {
        if let selectedDestinationAnnotation {
            mapView.removeAnnotation(selectedDestinationAnnotation)
        }
        let annotation = NGLPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = "Selected destination"
        mapView.addAnnotation(annotation)
        selectedDestinationAnnotation = annotation
    }

    private var usableUserCoordinate: CLLocationCoordinate2D? {
        guard let location = mapView.userLocation?.location, location.horizontalAccuracy >= 0 else {
            return nil
        }
        return CLLocationCoordinate2DIsValid(location.coordinate) ? location.coordinate : nil
    }

    private var selectedRouteMode: RouteMode {
        switch routeMode.selectedSegmentIndex {
        case 1: return .onlineOnly
        case 2: return .offlineOnly
        default: return .smart
        }
    }

    private func setStartNavigationEnabled(_ enabled: Bool) {
        startNavigationButton.isEnabled = enabled
        startNavigationButton.backgroundColor = enabled ? .systemGreen : .systemGray3
    }

    private func presentNavigation(routes: [Route], options: NavigationRouteOptions) {
        let simulationMode: SimulationMode? = simulationSwitch.isOn ? .always : nil
        // Use the SDK factory instead of creating a router directly. It preserves the route
        // source selected by NBNavigation and configures online/offline rerouting consistently.
        let service = NBNavigation.makeNavigationService(
            routes: routes,
            routeIndex: 0,
            simulating: simulationMode
        )
        let navigationOptions = NavigationOptions(navigationService: service)
        let controller = NavigationViewController(
            for: routes,
            routeIndex: 0,
            navigationOptions: navigationOptions,
            routeOptions: options
        )
        controller.routeLineTracksTraversal = true
        controller.delegate = self
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }

    private func parseCoordinate(_ text: String?) -> CLLocationCoordinate2D? {
        let parts = (text ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]) else {
            return nil
        }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }

    private enum DemoRouteError: LocalizedError {
        case emptyRoutes

        var errorDescription: String? { "The SDK returned no routes." }
    }
}

extension RouteDemoViewController: @preconcurrency NGLMapViewDelegate {
    func mapView(_ mapView: NGLMapView, didFinishLoading style: NGLStyle) {
        // Style changes discard runtime sources/layers. Re-register offline tiles and restore
        // both the installed-region polygons and any route that was already displayed.
        NBNavigation.registerOfflineMapStyle(mapView: mapView, styleURL: mapView.styleURL)
        downloadedRegionOverlay?.refresh()

        guard !currentRoutes.isEmpty, let primaryRoute = currentRoutes.first else { return }
        self.mapView.showRoutes(currentRoutes)
        self.mapView.showWaypoints(primaryRoute)
    }
}

extension RouteDemoViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === originField {
            destinationField.becomeFirstResponder()
        } else {
            requestRouteFromFields()
        }
        return true
    }
}

extension RouteDemoViewController: @preconcurrency NavigationViewControllerDelegate {
    func navigationViewControllerDidDismiss(
        _ navigationViewController: NavigationViewController,
        byCanceling canceled: Bool
    ) {
        navigationViewController.endNavigation()
        navigationViewController.dismiss(animated: true)
    }
}
