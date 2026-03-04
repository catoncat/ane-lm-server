// SPDX-License-Identifier: MIT
// ANELMServerApp.swift — Menu bar app for ANE-LM Server

import SwiftUI

@main
struct ANELMServerApp: App {
    @StateObject private var server = ServerManager()
    @StateObject private var downloader = ModelDownloader()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(server)
                .environmentObject(downloader)
        } label: {
            Image(systemName: server.isRunning ? "brain.filled.head.profile" : "brain.head.profile")
        }
        .menuBarExtraStyle(.window)
    }
}
