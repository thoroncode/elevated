// SceneDelegate.swift
// ElevatedIOS — UIWindowSceneDelegate, owns the window in scene-based lifecycle.

#if canImport(UIKit)
import UIKit

public class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let vc = ViewController()
        if connectionOptions.shortcutItem?.type == "com.elevated.explore" {
            vc.launchIntoExploreMode = true
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
        windowScene.requestGeometryUpdate(prefs)
    }

    public func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if shortcutItem.type == "com.elevated.explore" {
            // Toggle: if already exploring, go back to normal; otherwise enter explore
            if let vc = viewController {
                if vc.isExploreMode {
                    vc.exitExploreMode()
                } else {
                    vc.enterExploreMode()
                }
            }
        }
        completionHandler(true)
    }

    public func sceneWillResignActive(_ scene: UIScene) {
        // Start fading audio while we still have CPU time
        viewController?.fadeOutPlayback()
    }

    public func sceneDidEnterBackground(_ scene: UIScene) {
        // Hard stop — app is suspended
        viewController?.pausePlayback()
    }

    public func sceneWillEnterForeground(_ scene: UIScene) {
        viewController?.resumePlayback()
    }

    private var viewController: ViewController? {
        window?.rootViewController as? ViewController
    }
}
#endif
