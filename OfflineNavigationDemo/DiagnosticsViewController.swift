import NbmapCoreNavigation
import UIKit

@available(iOS 13.0, *)
@MainActor
/// Small operational screen that initializes the shared engine and exposes the SDK's
/// health snapshot. It is useful when separating integration/configuration failures from
/// missing downloaded data during development and support investigations.
final class DiagnosticsViewController: UIViewController {
    private let textView = UITextView()
    private let refreshButton = UIButton(type: .system)
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Diagnostics"
        view.backgroundColor = .systemBackground

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.setTitle("Initialize and check health", for: .normal)
        refreshButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        refreshButton.backgroundColor = .systemBlue
        refreshButton.tintColor = .white
        refreshButton.layer.cornerRadius = 10
        refreshButton.addTarget(self, action: #selector(refresh), for: .touchUpInside)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(textView)
        view.addSubview(refreshButton)
        NSLayoutConstraint.activate([
            refreshButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            refreshButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            refreshButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            textView.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        refresh()
    }

    deinit {
        refreshTask?.cancel()
    }

    @objc private func refresh() {
        refreshTask?.cancel()
        let requestID = UUID()
        refreshID = requestID
        refreshButton.isEnabled = false
        let before = NBNavigation.getOfflineInitializationState().rawValue
        textView.text = "Initialization state: \(before)\nChecking…"

        refreshTask = Task { [weak self] in
            do {
                let start = Date()
                // Repeated initialization is intentional: this screen can retry startup
                // failures and otherwise reuses the SDK-owned initialized engine.
                try await NBNavigation.initializeOffline()
                let health = try await NBNavigation.checkOfflineHealth()
                let durationMs = Int(Date().timeIntervalSince(start) * 1_000)
                try Task.checkCancellation()
                guard let self, self.refreshID == requestID else { return }
                self.refreshTask = nil
                self.refreshButton.isEnabled = true
                self.textView.text = """
                Initialization state: \(NBNavigation.getOfflineInitializationState().rawValue)
                Initialized flag: \(NBNavigation.isOfflineInitialized)
                Elapsed: \(durationMs) ms

                Native state: \(health.state)
                SDK version: \(health.sdkVersion)
                Engine version: \(health.engineVersion)
                Native build: \(health.nativeBuildId)
                Schema: \(health.schemaVersion)
                Supported schema: \(health.supportedSchemaVersion)
                Dataset: \(health.datasetVersion)
                Data mode: \(health.dataMode)
                Tile source: \(health.tileSourceMode)
                Loaded routing tiles: \(health.loadedTileCount)
                SQLite rows: \(health.sqliteRowsLoaded)
                Data root: \(health.dataRoot)
                """
            } catch is CancellationError {
                // A newer health check owns the UI state.
            } catch {
                guard let self, self.refreshID == requestID else { return }
                self.refreshTask = nil
                self.refreshButton.isEnabled = true
                self.textView.text = """
                Initialization state: \(NBNavigation.getOfflineInitializationState().rawValue)
                Initialized flag: \(NBNavigation.isOfflineInitialized)

                Error: \(error.localizedDescription)
                """
            }
        }
    }
}
