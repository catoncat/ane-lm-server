// SPDX-License-Identifier: MIT
// ServerManager.swift — Manages the ane-lm-server subprocess lifecycle

import Foundation
import Combine

@MainActor
class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var statusText = "Stopped"
    @Published var lastError: String?

    let port: Int = 8080
    let host: String = "127.0.0.1"

    var apiBaseURL: String { "http://\(host):\(port)/v1" }

    private var process: Process?
    private var healthTimer: Timer?

    var serverBinaryURL: URL {
        // Inside .app bundle: Contents/Resources/ane-lm-server
        let bundle = Bundle.main
        let resourcesDir = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/ane-lm-server")
        if FileManager.default.fileExists(atPath: resourcesDir.path) {
            return resourcesDir
        }
        // Also try forResource (works with Xcode bundles)
        if let bundled = bundle.url(forResource: "ane-lm-server", withExtension: nil) {
            return bundled
        }
        // Development fallback: look relative to executable
        let execDir = bundle.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: ".")
        return execDir
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ane-lm-server")
    }

    func start(modelPath: URL) {
        guard !isRunning else { return }
        lastError = nil

        let binary = serverBinaryURL
        guard FileManager.default.fileExists(atPath: binary.path) else {
            lastError = "Server binary not found"
            statusText = "Error: binary missing"
            return
        }

        // Ensure executable permission
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "--model", modelPath.path,
            "--host", host,
            "--port", "\(port)"
        ]

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.isRunning = false
                if p.terminationStatus != 0 && p.terminationStatus != 15 {
                    self?.statusText = "Crashed (exit \(p.terminationStatus))"
                } else {
                    self?.statusText = "Stopped"
                }
                self?.healthTimer?.invalidate()
            }
        }

        do {
            try proc.run()
            process = proc
            statusText = "Starting..."
            startHealthPolling()
        } catch {
            lastError = error.localizedDescription
            statusText = "Failed to start"
        }
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        process?.terminate()
        process = nil
        isRunning = false
        statusText = "Stopped"
    }

    private func startHealthPolling() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkHealth()
            }
        }
    }

    private func checkHealth() async {
        guard let url = URL(string: "http://\(host):\(port)/health") else { return }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                if !isRunning {
                    isRunning = true
                    statusText = "Running on :\(port)"
                }
            }
        } catch {
            // Server not ready yet, keep polling
        }
    }

    deinit {
        process?.terminate()
    }
}
