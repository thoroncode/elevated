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
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ViewController()
        window.makeKeyAndVisible()
        self.window = window
        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
        windowScene.requestGeometryUpdate(prefs)
    }

    public func sceneDidEnterBackground(_ scene: UIScene) {
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
