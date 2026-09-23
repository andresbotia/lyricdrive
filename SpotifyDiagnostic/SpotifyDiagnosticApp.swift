//
//  SpotifyDiagnosticApp.swift
//  SpotifyDiagnostic
//
//  Created by Andres on 9/22/26.
//

import SwiftUI

@main
struct SpotifyDiagnosticApp: App {
    @StateObject private var diagnosticManager = DiagnosticManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(diagnosticManager)
                .onOpenURL { url in
                    diagnosticManager.handleOpenURL(url)
                }
        }
    }
}
