import UIKit
import AVFoundation

@main
final class PadAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var home: HomeViewController?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Theme.load()
        Shelf.installAudioPaths()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        let shelf = HomeViewController()
        home = shelf
        let nav = UINavigationController(rootViewController: shelf)
        nav.setNavigationBarHidden(true, animated: false)
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = nav
        w.makeKeyAndVisible()
        padApplyTheme(to: w)
        window = w
        return true
    }

    /// A .swcel file sent here from Files, AirDrop or another app.
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let local = Shelf.adopt(url) else { return false }
        home?.openFromOutside(local)
        return true
    }
}
