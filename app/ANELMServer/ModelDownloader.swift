// SPDX-License-Identifier: MIT
// ModelDownloader.swift — Multi-model downloader with parallel jobs

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

enum ModelPreset: String, CaseIterable, Identifiable {
    case qwen35_08b = "Qwen3.5-0.8B"
    case qwen3_06b = "Qwen3-0.6B"

    var id: String { rawValue }
    var label: String { rawValue }
    var repo: String { "Qwen/\(rawValue)" }
    var directoryName: String { rawValue }

    var requiredFiles: [String] {
        switch self {
        case .qwen35_08b:
            return [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "model.safetensors-00001-of-00001.safetensors",
            ]
        case .qwen3_06b:
            return [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "model.safetensors",
            ]
        }
    }

    var optionalFiles: [String] {
        switch self {
        case .qwen35_08b:
            return [
                "model.safetensors.index.json",
                "chat_template.jinja",
                "merges.txt",
                "vocab.json",
                "preprocessor_config.json",
                "video_preprocessor_config.json",
            ]
        case .qwen3_06b:
            return [
                "generation_config.json",
                "chat_template.jinja",
                "merges.txt",
                "vocab.json",
            ]
        }
    }
}

struct ModelDownloadState {
    var isDownloading = false
    var progress: Double = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var currentFile: String = ""
    var fileIndex: Int = 0
    var fileCount: Int = 0
    var error: String?

    static var idle: ModelDownloadState { ModelDownloadState() }
}

@MainActor
class ModelDownloader: ObservableObject {
    @Published var mirror: MirrorSource = .huggingface
    @Published var selectedModel: ModelPreset {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: Self.selectedModelKey)
        }
    }
    @Published private(set) var states: [ModelPreset: ModelDownloadState] = [:]

    private var downloadTasks: [ModelPreset: Task<Void, Never>] = [:]

    private static let selectedModelKey = "ANELMServer.selectedModel"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.selectedModelKey)
        selectedModel = ModelPreset(rawValue: raw ?? "") ?? .qwen35_08b

        for model in ModelPreset.allCases {
            states[model] = .idle
        }
    }

    nonisolated static var baseModelsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let dir = appSupport
            .appendingPathComponent("ANELMServer/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated func modelPath(for model: ModelPreset) -> URL {
        Self.baseModelsDirectory.appendingPathComponent(model.directoryName, isDirectory: true)
    }

    var modelPath: URL { modelPath(for: selectedModel) }

    func modelExists(for model: ModelPreset) -> Bool {
        let dir = modelPath(for: model)
        let config = dir.appendingPathComponent("config.json")
        let tokenizer = dir.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: config.path),
              FileManager.default.fileExists(atPath: tokenizer.path) else {
            return false
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return files.contains { $0.pathExtension == "safetensors" }
    }

    var modelExists: Bool { modelExists(for: selectedModel) }

    func preferredAutoStartModel() -> ModelPreset? {
        if modelExists(for: selectedModel) {
            return selectedModel
        }
        return ModelPreset.allCases.first(where: { modelExists(for: $0) })
    }

    func state(for model: ModelPreset) -> ModelDownloadState {
        states[model] ?? .idle
    }

    var isDownloading: Bool {
        states.values.contains { $0.isDownloading }
    }

    var progress: Double {
        state(for: selectedModel).progress
    }

    var downloadedBytes: Int64 {
        state(for: selectedModel).downloadedBytes
    }

    var totalBytes: Int64 {
        state(for: selectedModel).totalBytes
    }

    var currentFile: String {
        state(for: selectedModel).currentFile
    }

    var error: String? {
        state(for: selectedModel).error
    }

    var fileIndex: Int {
        state(for: selectedModel).fileIndex
    }

    var fileCount: Int {
        state(for: selectedModel).fileCount
    }

    var selectedModelPath: URL {
        modelPath(for: selectedModel)
    }

    func downloadModel(_ model: ModelPreset? = nil) {
        let target = model ?? selectedModel
        if state(for: target).isDownloading { return }

        ensureModelDirectory(for: target)
        let plan: [(file: String, required: Bool)] =
            target.requiredFiles.map { ($0, true) } +
            target.optionalFiles.map { ($0, false) }

        states[target] = ModelDownloadState(
            isDownloading: true,
            progress: 0,
            downloadedBytes: 0,
            totalBytes: 0,
            currentFile: "",
            fileIndex: 0,
            fileCount: plan.count,
            error: nil
        )

        downloadTasks[target] = Task { [weak self] in
            await self?.runDownload(model: target, plan: plan)
        }
    }

    func cancel(_ model: ModelPreset? = nil) {
        let target = model ?? selectedModel
        downloadTasks[target]?.cancel()
        downloadTasks[target] = nil

        var s = state(for: target)
        s.isDownloading = false
        s.currentFile = ""
        states[target] = s
    }

    func deleteModel(_ model: ModelPreset? = nil) {
        let target = model ?? selectedModel
        cancel(target)
        let dir = modelPath(for: target)
        try? FileManager.default.removeItem(at: dir)
        ensureModelDirectory(for: target)
        states[target] = .idle
    }

    private func ensureModelDirectory(for model: ModelPreset) {
        let dir = modelPath(for: model)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func runDownload(model: ModelPreset, plan: [(file: String, required: Bool)]) async {
        defer { downloadTasks[model] = nil }

        let source = mirror
        let destination = modelPath(for: model)

        for (index, item) in plan.enumerated() {
            if Task.isCancelled { return }

            var s = state(for: model)
            s.fileIndex = index + 1
            s.currentFile = item.file
            s.progress = Double(index) / Double(max(plan.count, 1))
            states[model] = s

            let dest = destination.appendingPathComponent(item.file)
            if FileManager.default.fileExists(atPath: dest.path) {
                continue
            }

            let fileURL = source.url(repo: model.repo, file: item.file)
            do {
                _ = try await downloadFile(fileURL, to: dest, required: item.required)
            } catch {
                var failed = state(for: model)
                failed.isDownloading = false
                failed.error = error.localizedDescription
                states[model] = failed
                return
            }
        }

        if Task.isCancelled { return }

        var done = state(for: model)
        done.isDownloading = false
        done.currentFile = "Complete"
        done.progress = 1.0
        done.error = modelExists(for: model) ? nil : "Incomplete model files. Try downloading again."
        states[model] = done
    }

    private enum DownloadError: LocalizedError {
        case httpStatus(file: String, code: Int)

        var errorDescription: String? {
            switch self {
            case let .httpStatus(file, code):
                return "Failed to download \(file) (HTTP \(code))"
            }
        }
    }

    private enum DownloadResult {
        case downloaded
        case skippedOptional
    }

    private func downloadFile(_ url: URL, to destination: URL, required: Bool) async throws -> DownloadResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 && !required {
                return .skippedOptional
            }
            guard (200..<300).contains(http.statusCode) else {
                throw DownloadError.httpStatus(file: url.lastPathComponent, code: http.statusCode)
            }
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            throw NSError(
                domain: "ModelDownloader",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to save \(destination.lastPathComponent): \(error.localizedDescription)"
                ]
            )
        }

        return .downloaded
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
