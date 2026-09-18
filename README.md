# NextBillion.ai iOS Offline Navigation Demo

This UIKit reference app demonstrates how to integrate offline navigation with NextBillion.ai Navigation SDK for iOS 4.0.0. It covers region discovery, routing-data and map downloads, offline map rendering, hybrid route calculation, and navigation with the Default Navigation UI.

The sample includes:

- An expandable administrative-region hierarchy for managing offline data.
- Region recommendations around a coordinate or along a generated route.
- Download, pause, resume, cancel, and delete operations.
- Separate Route, Map, and Total size estimates plus live progress.
- Precise installed-region boundaries rendered on the map.
- `.smart`, `.onlineOnly`, and `.offlineOnly` route calculation.
- Truck routing by default, including vehicle dimensions and weight.
- Default Navigation UI integration.
- Offline engine, dataset, schema, and local-storage diagnostics.

## 1. Requirements and versions

| Item | Current setting |
| --- | --- |
| Minimum OS | iOS 13.0 |
| UI framework | UIKit |
| Swift language mode | Swift 5 |
| Navigation SDK | 4.0.0 |
| Nbmaps SDK | 2.2.0, resolved by Navigation SDK |
| Dependency manager | Swift Package Manager |
| Package URL | `https://github.com/nextbillion-ai/navigation-distribution` |
| Linked product | `NbmapNavigation` |

The project uses the exact Navigation SDK version `4.0.0` and commits `Package.resolved`. Keep this file in an executable sample so integrators resolve the SDK version that was actually verified.

## 2. Run the sample

1. Open `OfflineNavigationDemo_iOS.xcodeproj` in Xcode.
2. Wait for Swift Package Manager to resolve `navigation-distribution` 4.0.0.
3. Replace `YOUR_NEXTBILLION_API_KEY` in `OfflineNavigationDemo/Info.plist` with a valid NextBillion.ai API key.
4. Select the `OfflineNavigationDemo` scheme and an iOS 13 or newer device or simulator.
5. Build and run.
6. Open **Regions** and download a region. Then open **Route** and select **Offline** or **Smart** to verify offline routing.

Sample screens:

| Screen | Purpose |
| --- | --- |
| Regions | Region catalog, administrative hierarchy, sizes, progress, and download management |
| Regions → Radius | Recommend and download regions around a coordinate |
| Regions → Route | Generate a Truck route and recommend regions along it |
| Route | Map selection, coordinate input, route calculation, installed regions, and navigation |
| Diagnostics | Initialization state, SDK and engine versions, schema, dataset, and local-data diagnostics |

Recommended integration order:

| Step | Work |
| --- | --- |
| 1 | Add the 4.0.0 Swift Package and configure the API key and location permissions |
| 2 | Configure the map provider, routing strategy, and download network policy before creating a map |
| 3 | Initialize the process-wide offline engine during application launch |
| 4 | Synchronize and read the region catalog, using `regionId` as the stable identifier |
| 5 | Observe combined progress and handle partial Route or Map success |
| 6 | Register offline map support whenever a map style loads |
| 7 | Send every hybrid route request through `NBNavigation.fetchRoute` |
| 8 | Start navigation with `NBNavigation.makeNavigationService` |

## 3. Integrate the SDK into an existing app

### 3.1 Add the Swift Package

In Xcode, select **File → Add Package Dependencies** and enter:

```text
https://github.com/nextbillion-ai/navigation-distribution
```

Select **Exact Version: 4.0.0** and link the `NbmapNavigation` product to the application target. Import the modules required by each source file:

```swift
import Nbmap
import NbmapCoreNavigation
import NbmapNavigation
```

For a host project that uses `Package.swift`, the following is a complete minimal manifest. Replace the package and target names with names used by the host project:

```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "YourIntegrationPackage",
    platforms: [.iOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/nextbillion-ai/navigation-distribution",
            exact: "4.0.0"
        )
    ],
    targets: [
        .target(
            name: "YourAppTarget",
            dependencies: [
                .product(
                    name: "NbmapNavigation",
                    package: "navigation-distribution"
                )
            ]
        )
    ]
)
```

### 3.2 Configure the API key

The sample reads the API key from `NBMapAccessKey` in Info.plist:

```xml
<key>NBMapAccessKey</key>
<string>YOUR_NEXTBILLION_API_KEY</string>
```

Set the map provider and token before creating the first map view or making an online route request:

```swift
guard let apiKey = Bundle.main.object(
    forInfoDictionaryKey: "NBMapAccessKey"
) as? String,
      !apiKey.isEmpty,
      apiKey != "YOUR_NEXTBILLION_API_KEY" else {
    assertionFailure("Set NBMapAccessKey before using the SDK.")
    return
}

NGLAccountManager.use(.tomTom)
NGLAccountManager.accessToken = apiKey
```

Do not commit a production API key. A host app can reference a build setting from Info.plist:

```xml
<key>NBMapAccessKey</key>
<string>$(NB_MAP_ACCESS_KEY)</string>
```

Inject `NB_MAP_ACCESS_KEY` through an uncommitted `Secrets.xcconfig`, a CI secret, or the organization's configuration system. This repository ignores `Secrets.xcconfig` and `*.local.xcconfig`.

Reference: `OfflineNavigationDemo/SDKConfiguration.swift`.

### 3.3 Configure location permissions and background capabilities

Add at least a when-in-use location description:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Your location is used to calculate and follow routes.</string>
```

If the product supports continuous navigation and background voice guidance, add the following capabilities when required by the product design:

```xml
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Your location is used for active navigation.</string>
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>location</string>
</array>
```

Permission descriptions must state the host application's actual use. Do not request Always location permission when the app only needs foreground map selection or preview.

### 3.4 Configure the navigation runtime

Set the process-wide runtime before the first call to `initializeOffline()`:

```swift
let routing = RoutingConfig(
    mode: .smart,
    onlineTimeoutMs: 20_000,
    offlineTimeoutMs: 20_000,
    onlineRetryCount: 1
)

let runtime = NBNavigation.NavigationRuntimeConfig(
    routing: routing,
    offlineDownloadNetworkPolicy: .wifiOnly
)

NBNavigation.setNavigationRuntimeConfig(runtime)
```

Main configuration fields:

| Setting | Values or unit | Purpose |
| --- | --- | --- |
| `RoutingConfig.mode` | See RouteMode below | Global route strategy; a request can override it |
| `onlineTimeoutMs` | Milliseconds | Online route timeout |
| `offlineTimeoutMs` | Milliseconds | Offline route timeout |
| `onlineRetryCount` | Count | Number of online retries |
| `offlineDownloadNetworkPolicy` | `.wifiOnly` or `.anyNetwork` | Network policy for offline downloads |
| `OfflineMapConfig.mapsBaseUrl` | URL string | Offline map service URL; normally keep the SDK default |

To update only the download network policy:

```swift
NBNavigation.setOfflineDownloadNetworkPolicy(.anyNetwork)
```

Runtime configuration is process-wide. Do not initialize the shared engine from multiple screens with conflicting configurations.

### 3.5 Initialize the offline engine

Initialize early during application launch:

```swift
SDKConfiguration.configure()

Task {
    do {
        try await NBNavigation.initializeOffline()
    } catch {
        // Record the failure and allow an offline screen to retry later.
    }
}
```

Complete `initializeOffline()` once before the first API that depends on offline functionality. Callers only need to ensure that initialization has completed; they do not need to invoke `initializeOffline()` before every operation. SDK 4.0.0 safely reuses an in-progress or completed initialization, so a feature entry point may call it defensively to coordinate concurrent startup or retry an earlier failure.

```swift
try await NBNavigation.initializeOffline()
// Catalog synchronization, downloads, boundaries, and offline routes are now available.
```

Inspect the current state with:

```swift
let state = NBNavigation.getOfflineInitializationState()
let initialized = NBNavigation.isOfflineInitialized
```

Use `waitUntilOfflineInitialized()` only when another code path has already started initialization. It does not replace the first `initializeOffline()` call.

The default data directory is recommended. If the host app has a documented requirement for a custom directory, resolve Application Support from the current sandbox on every launch. Never persist an absolute path that contains a sandbox UUID.

```swift
let fileManager = FileManager.default
let applicationSupport = try fileManager.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
)
let dataRootURL = applicationSupport.appendingPathComponent(
    "NextBillionOffline",
    isDirectory: true
)
try fileManager.createDirectory(
    at: dataRootURL,
    withIntermediateDirectories: true,
    attributes: nil
)

let config = NBNavigation.defaultOfflineInitializeConfig(
    dataRoot: dataRootURL.path
)
try await NBNavigation.initializeOffline(config: config)
```

References: `OfflineNavigationDemo/AppDelegate.swift` and `OfflineNavigationDemo/DiagnosticsViewController.swift`.

## 4. Load the region catalog

Use this sequence on the region screen:

```swift
_ = try await NBNavigation.syncOfflineRegionList(syncMode: .auto)

// The default scope is United States, which is intentional in this sample.
let result = await NBNavigation.fetchRegionLists()
let rows = result.regionRows
```

### 4.1 Synchronization modes

| Mode | Use |
| --- | --- |
| `.auto` | Reuse a valid cache and synchronize when necessary; use for normal screen loading and refresh |
| `.force` | Force a catalog check and refresh; use for an explicit force-refresh action |

`fetchRegionLists()` reads the current catalog snapshot. It does not synchronize catalogs, so synchronize first when checking for updates.

### 4.2 Country scope

- `fetchRegionLists()` uses the SDK default and returns `United States` only.
- `fetchRegionLists(countries: ["United States", "India"])` returns the named countries.
- `fetchRegionLists(countries: nil)` returns every country.

This sample intentionally uses the no-argument method. If the host app supports other countries, use the same explicit country list when synchronizing and on the Regions, Radius or Route discovery, and installed-region screens. Country names must match the full English names in the catalog.

### 4.3 Merged results

`OfflineRegionListResult` merges three independent sources by stable `regionId`:

| Field | Content |
| --- | --- |
| `routeRegionList` | Downloadable offline routing catalog |
| `mapRegionList` | Downloadable offline map catalog |
| `mapInstalledRegionList` | Locally installed map packages |
| `regionRows` | UI rows merged by `regionId` |
| `routeError` | Routing catalog error |
| `mapError` | Map catalog error |
| `mapInstalledError` | Installed-map read error |

One source can fail while the others succeed. Do not discard the whole page because one error is present, and do not assume every `OfflineRegionListRow` contains all three component objects.

```swift
for row in result.regionRows {
    let route = row.routeRegion                 // May be nil.
    let map = row.mapRegion                     // May be nil.
    let installedMap = row.mapInstalledRegion   // May be nil.
}
```

The sample builds an expandable `country → adminL1 → adminL2 → adminL3` hierarchy instead of grouping regions alphabetically.

Reference: `loadRegions`, `rebuildHierarchy`, and `appendHierarchy` in `OfflineNavigationDemo/OfflineRegionsViewController.swift`.

### 4.4 Route, Map, and Total sizes

```swift
let routeBytes = row.routeSizeBytes
let mapBytes = row.mapSizeBytes

let totalBytes: Int64? = {
    guard let routeBytes, let mapBytes else { return nil }
    let (total, overflow) = routeBytes.addingReportingOverflow(mapBytes)
    return overflow ? nil : total
}()
```

Catalog sizes are estimates. A `nil` value means the corresponding catalog did not provide the data; it does not mean zero. Display Total only when both Route and Map sizes are available. Use the progress APIs for live downloaded bytes and percentages.

## 5. Download and manage regions

### 5.1 Download routing data and maps together

The sample uses the combined API:

```swift
_ = try await NBNavigation.downloadRegion(
    regionId: row.regionId,
    requestTimestampMs: Int64(Date().timeIntervalSince1970 * 1_000),
    onProgress: { _ in }
)
```

`downloadRegion` requires matching routing and map catalog entries for the same `regionId`. The two datasets are handled by independent download tasks; the combined call is not a database transaction. Always reload the merged state after completion because one dataset can succeed while the other fails.

Combined management APIs:

| Operation | API |
| --- | --- |
| Download | `downloadRegion(regionId:requestTimestampMs:onProgress:)` |
| Pause | `pauseRegionDownload(regionId:)` |
| Resume | `resumeRegionDownload(regionId:requestTimestampMs:onProgress:)` |
| Cancel | `cancelRegionDownload(regionId:)` |
| Delete | `deleteRegionAllData(regionId:)` |

If the product allows users to manage only one dataset, use the dataset-specific APIs:

| Dataset | Download | Pause | Resume | Cancel | Delete |
| --- | --- | --- | --- | --- | --- |
| Routing | `downloadOfflineRoutingRegion` | `pauseRoutingRegionDownload` | `resumeRoutingRegionDownload` | `cancelRoutingRegionDownload` | `deleteRoutingRegionData` |
| Map | `downloadOfflineMapRegion` | `pauseOfflineMapRegionDownload` | `resumeOfflineMapRegionDownload` | `cancelOfflineMapRegionDownload` | `deleteOfflineMapRegionData` |

The map-only APIs use a string `regionId`; the routing and combined APIs use `Int64`. Always use the stable catalog `regionId` to associate data. Do not use a display name as a primary key.

### 5.2 Download-screen lifecycle

When the download management screen appears:

```swift
NBNavigation.beginDownloadPageWithOwner(self)
```

When it disappears:

```swift
progressSubscription?.cancel()
progressSubscription = nil
NBNavigation.endDownloadPage()
```

`endDownloadPage()` and subscription cancellation stop UI observation for that screen. They do not cancel an SDK download. Call `cancelRegionDownload` or the corresponding dataset-specific API to cancel the actual transfer.

Do not call `shutdownOffline()` from a normal screen's `viewWillDisappear` or `viewDidDisappear`. The engine belongs to the process, and downloads or other screens may still need it.

### 5.3 Observe live progress

```swift
private var progressSubscription: NBNavigation.OfflineProgressSubscription?

progressSubscription = NBNavigation.observeOfflineRegionProgress(
    intervalMs: 1_000
) { progress in
    Task { @MainActor in
        for item in progress {
            print(item.regionId)
            print(item.routeNetwork?.percent as Any)
            print(item.mapTile?.percent as Any)
            print(item.overallPercent)
            print(item.overallState)
        }
    }
}
```

Retain the returned subscription and call `cancel()` when the screen stops observing. Do not use the catalog's `tilesDone` value as the only source for a live progress UI.

Combined progress remaining near 50% does not necessarily mean the task is stuck. Routing data may already be complete while map packages are still downloading or being verified. Inspect `routeNetwork`, `mapTile`, `overallState`, error details, and transferred bytes to identify the active or failed component.

Reference: `subscribeToProgress` and `perform` in `OfflineNavigationDemo/OfflineRegionsViewController.swift`.

## 6. Recommend regions by radius or route

`getCountiesInRadius` and `getCountiesAlongRoute` return an `OfflineRegionCatalog` whose `leaves` are routing-region records (`OfflineRegionLeaf`). They identify the routing regions required by the query, but they do not include the map catalog, installed map packages, or a combined Route and Map installation state.

### 6.1 Radius query

Provide a WGS84 latitude and longitude and a radius in meters:

```swift
_ = try await NBNavigation.syncOfflineRegionList(syncMode: .auto)

let catalog = try await NBNavigation.getCountiesInRadius(
    latitude: coordinate.latitude,
    longitude: coordinate.longitude,
    radiusMeters: 25_000
)

let regions = catalog.leaves
```

### 6.2 Route query

Generate a route first, then query the regions crossed by that route:

```swift
let waypoints = [
    Waypoint(coordinate: origin, name: "Origin"),
    Waypoint(coordinate: destination, name: "Destination")
]

let options = NavigationRouteOptions(waypoints: waypoints, profile: .truck)
let routeResult = try await NBNavigation.fetchRoute(
    options: options,
    routingConfig: RoutingConfig(mode: .onlineOnly)
)

guard let route = routeResult.routes.first else { return }
let catalog = try await NBNavigation.getCountiesAlongRoute(route: route)
let regions = catalog.leaves
```

Use the same route profile and vehicle parameters for discovery and final navigation. Otherwise, a Truck route may differ from the route used to select downloadable coverage.

### 6.3 Join recommendations with Map and installation data

Use `regionId` to join the routing-only recommendations with `fetchRegionLists()`. Synchronize once before the query, fetch the merged snapshot once after receiving the recommendations, and build a lookup dictionary instead of calling the catalog API separately for every region.

```swift
// recommendedRegions comes from getCountiesInRadius or getCountiesAlongRoute.
let recommendedRegions: [OfflineRegionLeaf] = catalog.leaves

// Use the same country scope as the rest of the application.
let listResult = await NBNavigation.fetchRegionLists()
let rowsByRegionID = listResult.regionRows.reduce(
    into: [Int64: NBNavigation.OfflineRegionListRow]()
) { rows, row in
    rows[row.regionId] = row
}

for recommendation in recommendedRegions {
    guard let row = rowsByRegionID[recommendation.regionId] else {
        // The routing query returned a region that is not present in the current
        // merged snapshot. Keep the routing result, but do not assume Map data exists.
        continue
    }

    let routeCatalogAvailable = row.routeRegion != nil
    let mapCatalogAvailable = row.mapRegion != nil

    let routeSize = row.routeSizeBytes ?? recommendation.totalSizeBytes
    let mapSize = row.mapSizeBytes

    let routeInstalled = row.routeRegion?.isDownloaded
        ?? recommendation.isDownloaded
    let mapInstalled = row.mapInstalledRegion != nil
    let mapComplete = row.mapInstalledRegion?.allPackagesOk == true
    let routeAndMapReady = routeInstalled && mapComplete

    let routeUpdateAvailable = row.routeRegion?.updateAvailable
        ?? recommendation.updateAvailable
    let mapUpdateAvailable = row.mapRegion?.updateAvailable == true

    // Enable the combined download only when both catalog components exist.
    let canDownloadRouteAndMap = routeCatalogAvailable && mapCatalogAvailable

    print(routeSize, mapSize as Any)
    print(routeInstalled, mapInstalled, routeAndMapReady)
    print(routeUpdateAvailable, mapUpdateAvailable, canDownloadRouteAndMap)
}
```

The merged row provides the following information for a recommended `regionId`:

| Data | Source | Meaning |
| --- | --- | --- |
| Routing catalog metadata | `row.routeRegion` | Routing version, size, tile counts, download status, partial state, update state, and bounding box |
| Map catalog metadata | `row.mapRegion` | Map version, estimated size, tile count, administrative fields, and update state |
| Installed Map metadata | `row.mapInstalledRegion` | Installed package count, installed bytes, installed version, data source, and package health |
| Routing size | `row.routeSizeBytes` | Estimated routing download size |
| Map size | `row.mapSizeBytes` | Estimated map download size |
| Component errors | `listResult.routeError`, `mapError`, `mapInstalledError` | Explains why one component may be missing while the others are available |

Catalog availability and installation state are different concepts:

| Check | Interpretation |
| --- | --- |
| `row.routeRegion != nil` | The routing dataset can be described or downloaded; it does not mean it is installed |
| `row.mapRegion != nil` | The map dataset can be described or downloaded; it does not mean it is installed |
| `row.routeRegion?.isDownloaded == true` | Routing data is installed |
| `row.mapInstalledRegion != nil` | At least one installed map-package record exists |
| `row.mapInstalledRegion?.allPackagesOk == true` | The installed map dataset is complete and healthy |
| Routing installed and `allPackagesOk == true` | Both datasets are ready for offline routing and map rendering |

When both catalog components are available, download or update them together with the stable `regionId`:

```swift
func downloadRouteAndMap(
    for row: NBNavigation.OfflineRegionListRow
) async throws {
    guard row.routeRegion != nil, row.mapRegion != nil else {
        // Offer a dataset-specific action, or explain which component is unavailable.
        return
    }

    _ = try await NBNavigation.downloadRegion(
        regionId: row.regionId,
        requestTimestampMs: Int64(Date().timeIntervalSince1970 * 1_000),
        onProgress: { _ in }
    )
}
```

After a download, update, cancel, or delete operation, call `fetchRegionLists()` again and replace the cached merged row. Combined operations are not transactional, so do not infer final state only from the method returning successfully. Use `observeOfflineRegionProgress` while the transfer is active, then use the refreshed `routeRegion` and `mapInstalledRegion` values as the final stored-state source of truth.

If `routeRegion` or `mapRegion` is missing, keep the available recommendation visible and inspect the component error fields. Use `downloadOfflineRoutingRegion` or `downloadOfflineMapRegion` only when the product intentionally supports a dataset-specific operation; do not pass a routing-only recommendation directly to `downloadRegion` without first verifying the matching Map catalog entry.

References: `startQuery`, `applyRegionMetadata`, and `downloadSelectedTapped` in `OfflineNavigationDemo/OfflineDiscoveryViewController.swift`.

## 7. Configure offline maps and display installed regions

### 7.1 Register the current map style

Register the style whenever the map screen becomes visible:

```swift
override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NBNavigation.onOfflineMapViewWillAppear()
    NBNavigation.registerOfflineMapStyle(
        mapView: mapView,
        styleURL: mapView.styleURL
    )
}
```

Register again after the style finishes loading, then restore runtime sources and layers:

```swift
func mapView(_ mapView: NGLMapView, didFinishLoading style: NGLStyle) {
    NBNavigation.registerOfflineMapStyle(
        mapView: mapView,
        styleURL: mapView.styleURL
    )
    // Re-add any application-defined sources and layers here.
}
```

A style reload removes runtime sources and layers. Registering only once in `viewDidLoad` is not sufficient.

### 7.2 Display installed-region boundaries

```swift
let boundaries = try await NBNavigation.getOfflineRegionBoundary(
    fetchDetailIfMissing: true
)
```

The returned GeoJSON provides the precise geometry for rendering region outlines. The catalog's `boundaryBbox` is suitable for coarse camera positioning, not as a replacement for the administrative boundary.

The sample normalizes Feature, FeatureCollection, and Geometry responses into one FeatureCollection and adds fill and line layers. During refresh, remove layers that reference the source before removing the source itself.

Reference: `OfflineNavigationDemo/DownloadedRegionMapOverlay.swift`.

### 7.3 Focus an installed region

```swift
let focused = try NBNavigation.focusOfflineMapRegion(
    mapView: mapView,
    regionId: String(row.regionId)
)
```

If the SDK cannot focus the region directly, the sample falls back to the routing catalog's `boundaryBbox` for camera positioning.

### 7.4 Cache-only preview

Use cache-only preview when the product needs to verify that a map is rendered entirely from local data:

```swift
let status = try await NBNavigation.offlineMapPreviewStatus()
guard status.previewBundleReady else {
    // Show a diagnostic message or install the required map packages.
    return
}

NBNavigation.enableCacheOnlyPreview(mapView: mapView)
// Perform the cache-only verification, then restore normal behavior.
NBNavigation.disableCacheOnlyPreview(mapView: mapView)
```

Do not leave cache-only preview enabled on a normal online map screen.

## 8. Hybrid routing and navigation

### 8.1 RouteMode

| Mode | Behavior |
| --- | --- |
| `.onlineOnly` | Use online routing only |
| `.offlineOnly` | Use installed offline routing data only |
| `.onlinePreferred` | Try online first, then offline |
| `.offlinePreferred` | Try offline first, then online |
| `.smart` | Let the SDK choose based on availability |

Set the global default with `NavigationRuntimeConfig.routing`. A request can pass a `routingConfig` override without mutating that global value.

### 8.2 Truck parameters

```swift
let options = NavigationRouteOptions(
    waypoints: waypoints,
    profile: .truck
)

// Order: height, width, length. Unit: centimeters.
options.truckSize = [heightCentimeters, widthCentimeters, lengthCentimeters]
// Unit: kilograms.
options.truckWeight = weightKilograms
```

Validation ranges used by the sample:

| Parameter | Range |
| --- | --- |
| Height | 0–1,000 cm |
| Width | 0–5,000 cm |
| Length | 0–5,000 cm |
| Weight | 0–100,000 kg |

The sample stores these values in `UserDefaults`. A production app can connect the same options to its vehicle configuration system.

Reference: `OfflineNavigationDemo/TruckSettingsViewController.swift`.

### 8.3 Fetch a route and inspect its source

```swift
if routingConfig.mode != .onlineOnly {
    try await NBNavigation.initializeOffline()
}

let result = try await NBNavigation.fetchRoute(
    options: options,
    routingConfig: routingConfig
)

let routes = result.routes
let source = result.source // Online or offline.
```

Cancel the previous Task when starting a new request. Also use a request or generation ID so a result that cannot be canceled promptly cannot replace newer UI state.

### 8.4 Start the Default Navigation UI

```swift
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

present(controller, animated: true)
```

Create the service through `NBNavigation.makeNavigationService` so it preserves the route source selected by the SDK and uses consistent online and offline rerouting configuration.

Reference: `OfflineNavigationDemo/RouteDemoViewController.swift`.

## 9. Health checks and shutdown

Retrieve the diagnostic snapshot with:

```swift
try await NBNavigation.initializeOffline()
let health = try await NBNavigation.checkOfflineHealth()

print(health.sdkVersion)
print(health.engineVersion)
print(health.schemaVersion)
print(health.supportedSchemaVersion)
print(health.datasetVersion)
print(health.loadedTileCount)
print(health.dataRoot)
```

Expose health information on an internal diagnostics screen or include it in redacted support logs. Production logs must not include API keys, precise user locations, or other sensitive data.

`shutdownOffline()` ends the entire offline subsystem lifecycle and should be used only when the application intentionally stops that subsystem:

```swift
await NBNavigation.shutdownOffline()
```

Call `initializeOffline()` again before using any offline API after shutdown.

Reference: `OfflineNavigationDemo/DiagnosticsViewController.swift`.

## 10. API call-site index

| Category | API | Sample call site |
| --- | --- | --- |
| Global configuration | `setNavigationRuntimeConfig` | [`SDKConfiguration.configure()`](OfflineNavigationDemo/SDKConfiguration.swift#L22) |
| Initialization | `initializeOffline` | [`AppDelegate`](OfflineNavigationDemo/AppDelegate.swift#L9), with optional defensive calls at offline feature entry points |
| Initialization state | `getOfflineInitializationState`, `isOfflineInitialized` | [`DiagnosticsViewController.refresh()`](OfflineNavigationDemo/DiagnosticsViewController.swift#L52) |
| Catalog synchronization | `syncOfflineRegionList` | [`loadRegions()`](OfflineNavigationDemo/OfflineRegionsViewController.swift#L154), [`startQuery()`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift#L377) |
| Merged catalog | `fetchRegionLists` | [`OfflineRegionsViewController`](OfflineNavigationDemo/OfflineRegionsViewController.swift#L178), [`OfflineDiscoveryViewController`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift#L403), [`RouteDemoViewController`](OfflineNavigationDemo/RouteDemoViewController.swift#L437) |
| Radius recommendation | `getCountiesInRadius` | [`findRegionsInRadius()`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift#L315); returns routing regions that must be joined with `fetchRegionLists` |
| Route recommendation | `getCountiesAlongRoute` | [`findRegionsAlongRoute()`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift#L334); returns routing regions that must be joined with `fetchRegionLists` |
| Combined download | `downloadRegion` | [`OfflineRegionsViewController.perform()`](OfflineNavigationDemo/OfflineRegionsViewController.swift#L366), [`downloadSelectedTapped()`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift#L486) |
| Download management | `pauseRegionDownload`, `resumeRegionDownload`, `cancelRegionDownload`, `deleteRegionAllData` | [`OfflineRegionsViewController.perform()`](OfflineNavigationDemo/OfflineRegionsViewController.swift#L366) |
| Progress | `observeOfflineRegionProgress` | [`OfflineRegionsViewController`](OfflineNavigationDemo/OfflineRegionsViewController.swift#L131), [`OfflineDiscoveryViewController`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift#L258) |
| Download-page lifecycle | `beginDownloadPageWithOwner`, `endDownloadPage` | [`OfflineRegionsViewController`](OfflineNavigationDemo/OfflineRegionsViewController.swift#L79), [`OfflineDiscoveryViewController`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift#L83) |
| Map style | `registerOfflineMapStyle`, `onOfflineMapViewWillAppear` | [`OfflineDiscoveryViewController`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift#L83), [`RouteDemoViewController`](OfflineNavigationDemo/RouteDemoViewController.swift#L53) |
| Region boundaries | `getOfflineRegionBoundary` | [`DownloadedRegionMapOverlay.refresh()`](OfflineNavigationDemo/DownloadedRegionMapOverlay.swift#L32) |
| Region focus | `focusOfflineMapRegion` | [`RouteDemoViewController.focusInstalledRegion()`](OfflineNavigationDemo/RouteDemoViewController.swift#L509) |
| Route request | `fetchRoute` | [`OfflineDiscoveryViewController`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift#L334), [`RouteDemoViewController`](OfflineNavigationDemo/RouteDemoViewController.swift#L297) |
| Navigation service | `makeNavigationService` | [`RouteDemoViewController.presentNavigation()`](OfflineNavigationDemo/RouteDemoViewController.swift#L608) |
| Health check | `checkOfflineHealth` | [`DiagnosticsViewController.refresh()`](OfflineNavigationDemo/DiagnosticsViewController.swift#L52) |

## 11. Troubleshooting

### The map is blank

Check the following in order:

1. `NBMapAccessKey` is not empty and is not still the placeholder.
2. `NGLAccountManager.use` and the access token are configured before the first map view is created.
3. `registerOfflineMapStyle` runs again in `mapView(_:didFinishLoading:)`.
4. The target region has map data installed, not only routing data.
5. `mapError` and `mapInstalledError` are empty.

### Only United States regions appear

This is the expected behavior of the no-argument `fetchRegionLists()` call and the intended scope of this sample. To support additional countries, pass their full English names explicitly and use the same scope for synchronization and display.

### A region remains at 50 percent for a long time

Inspect the `routeNetwork` and `mapTile` subtasks. Routing can be complete while map data is downloading, extracting, or being verified, so combined progress may remain near the midpoint. Treat the download as failed only when the subtask stops changing and exposes an error or failed state.

### A region row shows only one size

Routing and map catalogs are independent. Inspect `routeError`, `mapError`, `routeRegion`, and `mapRegion`. Display missing data as `N/A`; do not present the available component as the total size.

### A download continues after leaving the screen

This is intentional. Leaving the screen stops UI progress observation only. Call `cancelRegionDownload` to cancel the actual download.

### An action sheet moves or crashes on iPad

Configure `popoverPresentationController.sourceView` and `sourceRect`. The sample centralizes this setup in `UIViewController.preparePopover`.

## 12. Memory, concurrency, and lifecycle guidance

- Use `[weak self]` in long-lived tasks and callbacks to avoid retaining a view controller.
- Cancel queries, health checks, boundary loads, and progress subscriptions when their owner is released.
- When starting a new request, cancel the old Task and use a request ID to reject a late result.
- Downloads may outlive a screen, but their coordinating Task must not retain that screen.
- Perform UI updates on `MainActor`.
- Keep only a weak map view reference in an overlay helper and rebuild the overlay after a style reload.
- Do not use `shutdownOffline()` as a screen-level cleanup operation.

## 13. Production checklist

- [ ] Inject the API key securely and confirm the repository contains no real credentials.
- [ ] Pin a verified SDK version and commit the application's `Package.resolved`.
- [ ] Apply runtime configuration before the first initialization and map creation.
- [ ] Choose `.wifiOnly` or `.anyNetwork` deliberately.
- [ ] Use either the default United States scope or one consistent explicit country list.
- [ ] Handle `routeError`, `mapError`, and `mapInstalledError` independently.
- [ ] Provide clear UI for partial Route or Map success, failure, and retry.
- [ ] Test pause, resume, cancel, delete, process termination, and restart.
- [ ] Disable networking and verify both `.offlineOnly` routing and map rendering.
- [ ] Verify offline map registration and overlays after a style change.
- [ ] Test data-directory and schema migration during an application upgrade.
- [ ] Keep the Bundle ID and default data-directory strategy stable.
- [ ] Localize user-facing strings and redact production logs.
- [ ] Verify location permissions, background navigation, and audio behavior on a real device.

The `location` and `audio` entries in `UIBackgroundModes` support the navigation experience. They do not guarantee that arbitrary network downloads continue while the application is suspended. Design and test a separate background-transfer solution if the product has that requirement.

## 14. Project structure

| File | Purpose |
| --- | --- |
| [`SDKConfiguration.swift`](OfflineNavigationDemo/SDKConfiguration.swift) | API key, map provider, route strategy, and network policy |
| [`AppDelegate.swift`](OfflineNavigationDemo/AppDelegate.swift) | Process launch and early offline-engine initialization |
| [`OfflineRegionsViewController.swift`](OfflineNavigationDemo/OfflineRegionsViewController.swift) | Administrative catalog, sizes, state, and download management |
| [`OfflineDiscoveryViewController.swift`](OfflineNavigationDemo/OfflineDiscoveryViewController.swift) | Radius and Route recommendations plus batch downloads |
| [`DownloadedRegionMapOverlay.swift`](OfflineNavigationDemo/DownloadedRegionMapOverlay.swift) | Installed-region GeoJSON normalization and map rendering |
| [`RouteDemoViewController.swift`](OfflineNavigationDemo/RouteDemoViewController.swift) | Map selection, Truck routing, installed regions, and navigation |
| [`TruckSettingsViewController.swift`](OfflineNavigationDemo/TruckSettingsViewController.swift) | Truck dimensions, weight, validation, and persistence |
| [`DiagnosticsViewController.swift`](OfflineNavigationDemo/DiagnosticsViewController.swift) | Initialization and health checks |
| [`RootTabBarController.swift`](OfflineNavigationDemo/RootTabBarController.swift) | Sample entry points and secondary-screen tab-bar behavior |

## 15. Local XCFramework template

`LocalPackages/NextBillionNavigationLocal` is an optional package template for unreleased local XCFrameworks. The checked-in Xcode project uses the remote 4.0.0 package and does not use this template by default.

Build these four XCFrameworks before testing a local SDK:

- `NbmapNavigation.xcframework`
- `NbmapCoreNavigation.xcframework`
- `Nbmap.xcframework`
- `Turf.xcframework`

Then run:

```bash
./Scripts/prepare_local_spm.sh /absolute/path/to/navigation-ios
```

The script creates machine-specific symbolic links in `LocalPackages/NextBillionNavigationLocal/Artifacts`. The repository ignores those links. Replace the remote package dependency with the local package in Xcode for the test, and restore the released remote SDK before committing the reference project.

## 16. Additional documentation
- Navigation SDK is version 4.0.0.
- `fetchRegionLists()` uses the default United States scope.
- The default route profile is Truck.
