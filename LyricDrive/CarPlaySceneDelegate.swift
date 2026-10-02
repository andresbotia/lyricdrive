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
        // While Apple Music is active, Spotify's saved session stays dormant.
        if services.nowPlaying.activeService == .spotify {
            services.spotifyManager.reconnectForCarPlay(trigger: .carPlayDidConnect)
        }
        // Apple Music: resync with the Music app, which may have changed songs while LyricDrive
        // was suspended.
        services.nowPlaying.carPlayDidBecomeActive()

        let presentationController = CarPlayPresentationController(
            spotifyManager: services.spotifyManager,
            appleMusicManager: services.appleMusicManager,
            nowPlaying: services.nowPlaying,
            lyricsManager: services.lyricsManager,
            displayScale: interfaceController.carTraitCollection.displayScale
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
    /// in Spotify's or Apple Music's own CarPlay app. Spotify: try again (bounded, silent), since
    /// that usually wakes its transport. Apple Music: resync with the Music app.
    func sceneDidBecomeActive(_ scene: UIScene) {
        let services = AppServices.shared
        switch services.nowPlaying.activeService {
        case .spotify:
            services.spotifyManager.reconnectForCarPlay(trigger: .carPlaySceneDidBecomeActive)
        case .appleMusic:
            services.nowPlaying.carPlayDidBecomeActive()
        }
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
            services.nowPlaying.appWillResignActive()
        }
    }

    private var isPhoneSceneForegroundActive: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            scene.session.role == .windowApplication && scene.activationState == .foregroundActive
        }
    }
}
