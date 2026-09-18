import NbmapCoreNavigation
import UIKit

@available(iOS 13.0, *)
/// Truck values use the same units and validation limits as Vehicle Dimensions
/// in the full navigation application.
struct TruckConfiguration: Codable, Equatable {
    static let defaultValue = TruckConfiguration(
        heightCentimeters: 0,
        widthCentimeters: 0,
        lengthCentimeters: 0,
        weightKilograms: 0
    )

    static let maximumHeightCentimeters = 1_000
    static let maximumWidthCentimeters = 5_000
    static let maximumLengthCentimeters = 5_000
    static let maximumWeightKilograms = 100_000

    let heightCentimeters: Int
    let widthCentimeters: Int
    let lengthCentimeters: Int
    let weightKilograms: Int

    func apply(to options: NavigationRouteOptions) {
        // The SDK expects truckSize in height, width, length order. Zero values
        // preserve the SDK/server default behavior used by an empty vehicle profile.
        options.truckSize = [heightCentimeters, widthCentimeters, lengthCentimeters]
        options.truckWeight = weightKilograms
    }

    var summary: String {
        "H \(heightCentimeters) · W \(widthCentimeters) · L \(lengthCentimeters) cm · \(weightKilograms) kg"
    }
}

@available(iOS 13.0, *)
/// Minimal persistence used by the sample so route discovery and navigation share
/// one Truck profile. A host app can replace this with its existing settings layer.
enum TruckConfigurationStore {
    private static let storageKey = "OfflineNavigationDemo.TruckConfiguration"

    static func load(defaults: UserDefaults = .standard) -> TruckConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              let configuration = try? JSONDecoder().decode(TruckConfiguration.self, from: data),
              isValid(configuration)
        else { return .defaultValue }
        return configuration
    }

    static func save(_ configuration: TruckConfiguration, defaults: UserDefaults = .standard) {
        guard isValid(configuration),
              let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func isValid(_ configuration: TruckConfiguration) -> Bool {
        (0...TruckConfiguration.maximumHeightCentimeters).contains(configuration.heightCentimeters)
            && (0...TruckConfiguration.maximumWidthCentimeters).contains(configuration.widthCentimeters)
            && (0...TruckConfiguration.maximumLengthCentimeters).contains(configuration.lengthCentimeters)
            && (0...TruckConfiguration.maximumWeightKilograms).contains(configuration.weightKilograms)
    }
}

@available(iOS 13.0, *)
@MainActor
/// Programmatic counterpart of the reference application's Vehicle Dimensions form.
final class TruckSettingsViewController: UIViewController {
    var onSave: ((TruckConfiguration) -> Void)?

    private let initialConfiguration: TruckConfiguration
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let heightField = UITextField()
    private let widthField = UITextField()
    private let lengthField = UITextField()
    private let weightField = UITextField()

    init(configuration: TruckConfiguration) {
        initialConfiguration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Truck settings"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save,
            target: self,
            action: #selector(saveTapped)
        )
        configureLayout()
        populateFields()
        observeKeyboard()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 18

        let typeLabel = UILabel()
        typeLabel.text = "Vehicle type: Truck"
        typeLabel.font = .preferredFont(forTextStyle: .headline)

        let helpLabel = UILabel()
        helpLabel.text = "Dimensions follow the Vehicle Dimensions settings used by the reference app. Enter centimeters and kilograms; 0 leaves that value unspecified."
        helpLabel.font = .preferredFont(forTextStyle: .footnote)
        helpLabel.textColor = .secondaryLabel
        helpLabel.numberOfLines = 0

        let limitLabel = UILabel()
        limitLabel.text = "Limits: height 1,000 cm; width and length 5,000 cm; weight 100,000 kg."
        limitLabel.font = .preferredFont(forTextStyle: .caption1)
        limitLabel.textColor = .secondaryLabel
        limitLabel.numberOfLines = 0

        contentStack.addArrangedSubview(typeLabel)
        contentStack.addArrangedSubview(helpLabel)
        contentStack.addArrangedSubview(makeFieldGroup(title: "Vehicle Height", field: heightField, unit: "cm"))
        contentStack.addArrangedSubview(makeFieldGroup(title: "Vehicle Width", field: widthField, unit: "cm"))
        contentStack.addArrangedSubview(makeFieldGroup(title: "Vehicle Length", field: lengthField, unit: "cm"))
        contentStack.addArrangedSubview(makeFieldGroup(title: "Vehicle Weight", field: weightField, unit: "kg"))
        contentStack.addArrangedSubview(limitLabel)

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28)
        ])
    }

    private func makeFieldGroup(title: String, field: UITextField, unit: String) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)

        field.borderStyle = .roundedRect
        field.backgroundColor = .secondarySystemGroupedBackground
        field.keyboardType = .numberPad
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = title
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let unitLabel = UILabel()
        unitLabel.text = unit
        unitLabel.textColor = .secondaryLabel
        unitLabel.textAlignment = .left
        unitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        unitLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let fieldRow = UIStackView(arrangedSubviews: [field, unitLabel])
        fieldRow.axis = .horizontal
        fieldRow.alignment = .center
        fieldRow.spacing = 10

        let group = UIStackView(arrangedSubviews: [titleLabel, fieldRow])
        group.axis = .vertical
        group.spacing = 7
        return group
    }

    private func populateFields() {
        heightField.text = String(initialConfiguration.heightCentimeters)
        widthField.text = String(initialConfiguration.widthCentimeters)
        lengthField.text = String(initialConfiguration.lengthCentimeters)
        weightField.text = String(initialConfiguration.weightKilograms)
    }

    private func observeKeyboard() {
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

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let keyboardFrame = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY)
        scrollView.contentInset.bottom = overlap
        scrollView.verticalScrollIndicatorInsets.bottom = overlap
    }

    @objc private func saveTapped() {
        view.endEditing(true)
        guard let height = validatedValue(
            from: heightField,
            title: "Vehicle Height",
            maximum: TruckConfiguration.maximumHeightCentimeters
        ), let width = validatedValue(
            from: widthField,
            title: "Vehicle Width",
            maximum: TruckConfiguration.maximumWidthCentimeters
        ), let length = validatedValue(
            from: lengthField,
            title: "Vehicle Length",
            maximum: TruckConfiguration.maximumLengthCentimeters
        ), let weight = validatedValue(
            from: weightField,
            title: "Vehicle Weight",
            maximum: TruckConfiguration.maximumWeightKilograms
        ) else { return }

        let configuration = TruckConfiguration(
            heightCentimeters: height,
            widthCentimeters: width,
            lengthCentimeters: length,
            weightKilograms: weight
        )
        TruckConfigurationStore.save(configuration)
        onSave?(configuration)
        navigationController?.popViewController(animated: true)
    }

    private func validatedValue(
        from field: UITextField,
        title: String,
        maximum: Int
    ) -> Int? {
        let text = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let value = Int(text), (0...maximum).contains(value) else {
            showMessage(
                title: "Invalid \(title)",
                message: "Enter a whole number from 0 to \(maximum)."
            )
            field.becomeFirstResponder()
            return nil
        }
        return value
    }
}
