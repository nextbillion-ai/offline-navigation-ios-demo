import Nbmap
import NbmapCoreNavigation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Configuration must precede both map-view creation and offline initialization.
        SDKConfiguration.configure()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = RootTabBarController()
        window.makeKeyAndVisible()
        self.window = window

        // Start initialization early to reduce latency on the first offline screen.
        // Screens intentionally call initializeOffline() again before their own work:
        // SDK 4.0.0 coalesces concurrent calls and a later call retries a failed startup.
        // Do not call shutdownOffline() when an individual screen disappears; the engine
        // is process-wide and downloads are allowed to continue in the background.
        Task {
            do {
                try await NBNavigation.initializeOffline()
            } catch {
                print("Offline initialization failed: \(error.localizedDescription)")
            }
        }
        return true
    }
}
