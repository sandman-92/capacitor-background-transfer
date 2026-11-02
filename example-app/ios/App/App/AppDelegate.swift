import UIKit
import Capacitor
import BackgroundTransferPlugin

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    /// The system relaunches the app in the background when a background transfer ends while it
    /// was closed; the plugin records the outcome and calls the handler once it has.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if BackgroundTransferPlugin.handleEvents(forBackgroundURLSession: identifier, completionHandler: completionHandler) { return }
        completionHandler()
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }
}

/// iOS 27 won't launch an app without the UIScene lifecycle; Main.storyboard (the Capacitor
/// bridge) is loaded through UISceneStoryboardFile in Info.plist.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}
