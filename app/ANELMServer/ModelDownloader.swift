// SPDX-License-Identifier: MIT
// ModelDownloader.swift — Downloads HuggingFace models with progress

import Foundation
import Combine

enum MirrorSource: String, CaseIterable, Identifiable {
    case huggingface = "huggingface.co"
    case hfMirror = "hf-mirror.com"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .huggingface: return "HuggingFace"
        case .hfMirror: return "hf-mirror (CN)"
        }
    }
    func url(repo: String, file: String) -> URL {
        URL(string: "https://\(rawValue)/\(repo)/resolve/main/\(file)")!
    }
}

@MainActor
class ModelDownloader: NSObject, ObservableObject {
    @Published var progress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var isDownloading = false
    @Published var currentFile: String = ""
    @Published var error: String?
    @Published var mirror: MirrorSource = .huggingface

    // How many files total / completed
    @Published var fileIndex: Int = 0
    @Published var fileCount: Int = 0

    private var downloadTask: URLSessionDownloadTask?
    private var pendingFiles: [(url: URL, destName: String)] = []
    private var destDirectory: URL = modelsDirectory

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600 // 1 hour for large files
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // Model storage — nonisolated so URLSession delegates can access it
    nonisolated static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport
            .appendingPathComponent("ANELMServer/models/Qwen3.5-0.8B", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated var modelPath: URL { Self.modelsDirectory }

    var modelExists: Bool {
        let safetensors = modelPath
            .appendingPathComponent("model.safetensors-00001-of-00001.safetensors")
        let config = modelPath.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: safetensors.path)
            && FileManager.default.fileExists(atPath: config.path)
    }

    // Required files for ANE-LM inference
    private static let requiredFiles = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "chat_template.jinja",
        "model.safetensors-00001-of-00001.safetensors",
        "model.safetensors.index.json",
        "merges.txt",
        "vocab.json",
    ]

    func downloadModel(repo: String = "Qwen/Qwen3.5-0.8B") {
        guard !isDownloading else { return }
        isDownloading = true
        error = nil
        progress = 0

        // Build file list using selected mirror
        let source = mirror
        pendingFiles = Self.requiredFiles.map { filename in
            (url: source.url(repo: repo, file: filename), destName: filename)
        }

        fileCount = pendingFiles.count
        fileIndex = 0
        downloadNextFile()
    }

    private func downloadNextFile() {
        guard !pendingFiles.isEmpty else {
            // All done
            DispatchQueue.main.async {
                self.isDownloading = false
                self.progress = 1.0
                self.currentFile = "Complete"
            }
            return
        }

        let file = pendingFiles.removeFirst()
        let dest = destDirectory.appendingPathComponent(file.destName)

        // Skip if already downloaded
        if FileManager.default.fileExists(atPath: dest.path) {
            DispatchQueue.main.async {
                self.fileIndex += 1
                self.progress = Double(self.fileIndex) / Double(self.fileCount)
            }
            downloadNextFile()
            return
        }

        DispatchQueue.main.async {
            self.fileIndex += 1
            self.currentFile = file.destName
        }

        let task = session.downloadTask(with: file.url)
        downloadTask = task
        task.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        pendingFiles.removeAll()
        isDownloading = false
        currentFile = ""
    }

    func deleteModel() {
        let dir = Self.modelsDirectory
        try? FileManager.default.removeItem(at: dir)
        // Recreate empty directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            self.downloadedBytes = totalBytesWritten
            self.totalBytes = totalBytesExpectedToWrite
            // Per-file progress blended with overall progress
            let fileProg = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                : 0
            let base = Double(self.fileIndex - 1) / Double(max(self.fileCount, 1))
            let slice = 1.0 / Double(max(self.fileCount, 1))
            self.progress = base + slice * fileProg
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Figure out filename from the original URL
        let filename = downloadTask.originalRequest?.url?.lastPathComponent ?? "unknown"
        let dest = ModelDownloader.modelsDirectory.appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            Task { @MainActor in
                self.error = "Failed to save \(filename): \(error.localizedDescription)"
                self.isDownloading = false
            }
            return
        }

        Task { @MainActor in
            self.downloadNextFile()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in
            self.error = error.localizedDescription
            self.isDownloading = false
        }
    }
}
