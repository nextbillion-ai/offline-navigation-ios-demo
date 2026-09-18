import Foundation
import Nbmap
import NbmapCoreNavigation

/// The single configuration entry point for both map rendering and offline navigation.
///
/// Integrating apps should call `configure()` exactly once before creating a map view or
/// starting `NBNavigation.initializeOffline()`. Keeping these values in one place prevents
/// different screens from accidentally initializing the shared offline engine differently.
enum SDKConfiguration {
    private static let placeholderAPIKey = "YOUR_NEXTBILLION_API_KEY"

    static var apiKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "NBMapAccessKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var hasUsableAPIKey: Bool {
        !apiKey.isEmpty && apiKey != placeholderAPIKey
    }

    static func configure() {
        // Configure the map provider and access token before the first NGLMapView is created.
        NGLAccountManager.use(.tomTom)
        if hasUsableAPIKey {
            NGLAccountManager.accessToken = apiKey
        }

        // Runtime configuration is process-wide. Per-request routing modes can still be
        // supplied to fetchRoute(options:routingConfig:) without mutating this default.
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
        // Set this before initializeOffline(). Do not repeat offline-map base URL or engine
        // setup in individual screens; NBNavigation owns that shared configuration.
        NBNavigation.setNavigationRuntimeConfig(runtime)
    }
}
