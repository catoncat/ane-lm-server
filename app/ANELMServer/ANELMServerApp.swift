// SPDX-License-Identifier: MIT
// ANELMServerApp.swift — Menu bar app for ANE-LM Server

import SwiftUI

@main
struct ANELMServerApp: App {
    @StateObject private var server = ServerManager()
    @StateObject private var downloader = ModelDownloader()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(server)
                .environmentObject(downloader)
        } label: {
            // Use label body evaluation as a trigger for auto-start.
            // MenuBarExtra label is evaluated eagerly at app launch (unlike content).
            Image(systemName: server.isRunning ? "brain.filled.head.profile" : "brain.head.profile")
                .onAppear {
                    autoStartIfReady()
                }
        }
        .menuBarExtraStyle(.window)
    }

    private func autoStartIfReady() {
        if downloader.modelExists && !server.isRunning {
            server.start(modelPath: downloader.modelPath)
        }
    }
}
