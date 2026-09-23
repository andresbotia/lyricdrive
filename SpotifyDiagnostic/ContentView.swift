//
//  ContentView.swift
//  SpotifyDiagnostic
//
//  Created by Andres on 9/22/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var diagnosticManager: DiagnosticManager

    var body: some View {
        VStack(spacing: 12) {
            Text("Spotify SDK Diagnostic")
                .font(.headline)

            HStack(spacing: 12) {
                Button("Test 1: SessionManager") {
                    diagnosticManager.startSessionManagerFlow()
                }
                .buttonStyle(.borderedProminent)

                Button("Test 2: authorizeAndPlayURI") {
                    diagnosticManager.startAuthorizeAndPlayURIFlow()
                }
                .buttonStyle(.bordered)

                Button("Clear") {
                    diagnosticManager.clearLog()
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(diagnosticManager.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            .border(Color.gray.opacity(0.3))
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(DiagnosticManager())
}
