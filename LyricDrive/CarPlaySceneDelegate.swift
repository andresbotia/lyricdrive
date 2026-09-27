//
//  CarPlaySceneDelegate.swift
//  LyricDrive
//

import CarPlay
import UIKit

/// Entry point for the CarPlay template scene (declared in Info.plist under
/// `CPTemplateApplicationSceneSessionRoleApplication`). Owns nothing long-lived: it borrows the
/// shared managers from `AppServices` and hands them to a per-connection presentation controller.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var presentationController: CarPlayPresentationController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        print("CarPlay: Interface controller connected")
        self.interfaceController = interfaceController

        let services = AppServices.shared
        services.isCarPlayConnected = true
        // The phone scene may have resigned active (and disconnected App Remote) just before
        // this callback arrived — there's no ordering guarantee between the two scenes — and
        // Spotify's local transport is often still asleep this early in a drive. Reconnect
        // silently with a few bounded retries; never OAuth, never an automatic app switch.
        services.spotifyManager.reconnectForCarPlay(trigger: .carPlayDidConnect)

        let presentationController = CarPlayPresentationController(
            spotifyManager: services.spotifyManager,
            lyricsManager: services.lyricsManager
        )
        self.presentationController = presentationController

        interfaceController.setRootTemplate(presentationController.rootTemplate, animated: false) { success, error in
            if let error {
                print("CarPlay: Failed to set root template — \(error)")
            } else if !success {
                print("CarPlay: Root template was not set")
            }
        }
        presentationController.start()
    }

    /// The driver came back to LyricDrive on the car screen — often right after starting music
    /// in Spotify's own CarPlay app, which wakes its transport. Try again (bounded, silent).
    func sceneDidBecomeActive(_ scene: UIScene) {
        AppServices.shared.spotifyManager.reconnectForCarPlay(trigger: .carPlaySceneDidBecomeActive)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        print("CarPlay: Interface controller disconnected")
        // Only CarPlay-side state is torn down. The shared Spotify/Lyrics managers stay alive and
        // connected for the phone scene; nothing here logs out or disconnects Spotify.
        presentationController?.stop()
        presentationController = nil
        self.interfaceController = nil

        let services = AppServices.shared
        services.isCarPlayConnected = false
        services.spotifyManager.cancelAutomaticReconnect()
        // Restore normal phone behavior: if the iPhone UI isn't in the foreground, apply the
        // resign-active disconnect that was skipped while CarPlay was connected.
        if !isPhoneSceneForegroundActive {
            services.spotifyManager.appWillResignActive()
        }
    }

    private var isPhoneSceneForegroundActive: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            scene.session.role == .windowApplication && scene.activationState == .foregroundActive
        }
    }
}
