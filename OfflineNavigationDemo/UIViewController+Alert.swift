import UIKit

extension UIViewController {
    /// Presents a simple error/status alert only when another controller is not already
    /// presented. This prevents competing asynchronous SDK callbacks from stacking alerts.
    func showMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Anchors an action sheet to a stable source rectangle on iPad. Without this setup,
    /// presenting the same controller as a popover can crash or appear at an unstable point.
    func preparePopover(_ controller: UIAlertController, sourceView: UIView?) {
        guard let popover = controller.popoverPresentationController else { return }
        guard let anchor = sourceView ?? view else { return }
        popover.sourceView = view
        popover.sourceRect = anchor.convert(anchor.bounds, to: view)
    }
}
