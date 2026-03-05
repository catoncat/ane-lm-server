// SPDX-License-Identifier: MIT
// ServerManager.swift — Manages the ane-lm-server subprocess lifecycle

import Foundation
import Combine

@MainActor
class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var statusText = "Stopped"
    @Published var lastError: String?
    @Published var runningModelID: String?
    @Published var runningModelLabel: String?

    let port: Int = 8080
    let host: String = "127.0.0.1"

    var apiBaseURL: String { "http://\(host):\(port)/v1" }

    /// True from proc.run() until health check succeeds or process dies.
    /// Prevents duplicate spawns during the startup window.
    private var isStarting = false
    private var process: Process?
    private var healthTimer: Timer?
    private var stderrPipe: Pipe?

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

    func start(modelPath: URL, modelID: String? = nil, modelLabel: String? = nil) {
        guard !isRunning && !isStarting else { return }
        lastError = nil
        isStarting = true

        let binary = serverBinaryURL
        guard FileManager.default.fileExists(atPath: binary.path) else {
            isStarting = false
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
        errPipe.fileHandleForReading.readabilityHandler = { file in
            // Drain stderr continuously to avoid pipe backpressure blocking the server process.
            _ = file.availableData
        }
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        stderrPipe = errPipe

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isStarting = false
                if p.terminationStatus != 0 && p.terminationStatus != 15 {
                    self?.statusText = "Crashed (exit \(p.terminationStatus))"
                } else {
                    self?.statusText = "Stopped"
                }
                self?.runningModelID = nil
                self?.runningModelLabel = nil
                self?.healthTimer?.invalidate()
                self?.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self?.stderrPipe = nil
            }
        }

        do {
            try proc.run()
            process = proc
            runningModelID = modelID
            runningModelLabel = modelLabel
            statusText = "Starting..."
            startHealthPolling()
        } catch {
            isStarting = false
            runningModelID = nil
            runningModelLabel = nil
            lastError = error.localizedDescription
            statusText = "Failed to start"
        }
    }

    func restart(modelPath: URL, modelID: String? = nil, modelLabel: String? = nil) {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.start(modelPath: modelPath, modelID: modelID, modelLabel: modelLabel)
        }
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        process?.terminate()
        process = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        isRunning = false
        isStarting = false
        runningModelID = nil
        runningModelLabel = nil
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
                    isStarting = false
                    statusText = "Running on :\(port)"
                }
            }
        } catch {
            // Server not ready yet, keep polling
        }
    }

    deinit {
        process?.terminate()
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
    }
}
