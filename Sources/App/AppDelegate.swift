import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .systemBackground
        window?.rootViewController = makeRoot()
        window?.makeKeyAndVisible()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Task { @MainActor in await AppEnvironment.shared.studyStore.flushAll() }
    }

    func makeRoot() -> UIViewController {
        if AppEnvironment.shared.isLoggedIn {
            return UINavigationController(rootViewController: HomeViewController())
        }
        return UINavigationController(rootViewController: LoginViewController())
    }

    func showMain() {
        window?.rootViewController = UINavigationController(rootViewController: HomeViewController())
    }

    func showLogin() {
        window?.rootViewController = UINavigationController(rootViewController: LoginViewController())
    }
}
