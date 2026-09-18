import UIKit

/// Navigation controller used by each root tab so secondary example screens can hide the
/// shared tab bar without repeating `hidesBottomBarWhenPushed` at every call site.
private final class TabNavigationController: UINavigationController {
    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        // The tab bar belongs to the three root pages. Hide it for every pushed
        // page (and any deeper page) and let UIKit restore it when returning.
        if !viewControllers.isEmpty {
            viewController.hidesBottomBarWhenPushed = true
        }
        super.pushViewController(viewController, animated: animated)
    }
}

/// Top-level sample navigation. A host application normally embeds the individual example
/// controllers in its own navigation structure instead of copying this container.
final class RootTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // Each tab owns one navigation stack. TabNavigationController keeps the tab bar
        // visible only on these three roots and automatically hides it on pushed examples.
        let regions = TabNavigationController(rootViewController: OfflineRegionsViewController())
        regions.tabBarItem = UITabBarItem(
            title: "Regions",
            image: UIImage(systemName: "square.and.arrow.down"),
            tag: 0
        )

        let route = TabNavigationController(rootViewController: RouteDemoViewController())
        route.tabBarItem = UITabBarItem(
            title: "Route",
            image: UIImage(systemName: "point.topleft.down.to.point.bottomright.curvepath"),
            tag: 1
        )

        let diagnostics = TabNavigationController(rootViewController: DiagnosticsViewController())
        diagnostics.tabBarItem = UITabBarItem(
            title: "Diagnostics",
            image: UIImage(systemName: "stethoscope"),
            tag: 2
        )

        viewControllers = [regions, route, diagnostics]
    }
}
