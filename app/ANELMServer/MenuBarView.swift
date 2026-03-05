// SPDX-License-Identifier: MIT
// MenuBarView.swift — The popover UI shown from the menu bar icon

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var downloader: ModelDownloader

    @State private var copied = false
    @State private var showDeleteConfirm = false

    private var selectedModel: ModelPreset { downloader.selectedModel }
    private var selectedState: ModelDownloadState { downloader.state(for: selectedModel) }
    private var phase: AppPhase {
        if server.isRunning { return .ready }
        if selectedState.isDownloading { return .downloading }
        if !downloader.modelExists(for: selectedModel) { return .needsModel }
        return .ready
    }

    private var selectedModelAvailable: Bool {
        downloader.modelExists(for: selectedModel)
    }

    private var canSwitchToSelected: Bool {
        server.isRunning
            && server.runningModelID != selectedModel.id
            && selectedModelAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.vertical, 8)

            switch phase {
            case .needsModel:
                setupSection
            case .downloading:
                downloadSection
            case .ready:
                serverSection
            }

            Divider().padding(.vertical, 8)
            footerSection
        }
        .padding()
        .frame(width: 340)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text("ANE-LM Server")
                .font(.headline)
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch phase {
        case .needsModel:
            Label("Setup", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .downloading:
            Label("Downloading", systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.blue)
        case .ready:
            Label(
                server.isRunning ? "Running" : "Stopped",
                systemImage: server.isRunning ? "circle.fill" : "circle"
            )
            .font(.caption)
            .foregroundStyle(server.isRunning ? .green : .secondary)
        }
    }

    // MARK: - Shared model controls

    private var modelControlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Active Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(selectedModel.label)
                    .font(.caption.monospaced())
            }

            Picker("Model", selection: $downloader.selectedModel) {
                ForEach(ModelPreset.allCases) { model in
                    Text(model.label).tag(model)
                }
            }
            .pickerStyle(.segmented)

            Picker("Source", selection: $downloader.mirror) {
                ForEach(MirrorSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(ModelPreset.allCases) { model in
                    modelRow(model)
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: ModelPreset) -> some View {
        let state = downloader.state(for: model)
        let exists = downloader.modelExists(for: model)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.label)
                    .font(.caption)
                Spacer()

                if state.isDownloading {
                    Button("Cancel") {
                        downloader.cancel(model)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                } else if exists {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Button("Download") {
                        downloader.downloadModel(model)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            if state.isDownloading {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(state.currentFile)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(state.fileIndex)/\(max(state.fileCount, 1))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let err = state.error {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Setup (selected model not ready)

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download one or both models. Downloads can run in parallel.")
                .font(.caption)
                .foregroundStyle(.secondary)

            modelControlSection
        }
    }

    // MARK: - Downloading

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Downloading model files...")
                .font(.caption)
                .foregroundStyle(.secondary)

            modelControlSection
        }
    }

    // MARK: - Server ready

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            modelControlSection

            if let running = server.runningModelLabel, server.isRunning {
                Text("Running model: \(running)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let err = server.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if server.isRunning {
                HStack {
                    Text(server.apiBaseURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(server.apiBaseURL, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy API URL")
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if canSwitchToSelected {
                    Button {
                        server.restart(
                            modelPath: downloader.modelPath(for: selectedModel),
                            modelID: selectedModel.id,
                            modelLabel: selectedModel.label
                        )
                    } label: {
                        Label("Switch to \(selectedModel.label)", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    Button {
                        if server.isRunning {
                            server.stop()
                        } else {
                            server.start(
                                modelPath: downloader.modelPath(for: selectedModel),
                                modelID: selectedModel.id,
                                modelLabel: selectedModel.label
                            )
                        }
                    } label: {
                        Label(
                            server.isRunning ? "Stop Server" : "Start Server",
                            systemImage: server.isRunning ? "stop.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(server.isRunning ? .red : .green)
                    .disabled(!server.isRunning && !selectedModelAvailable)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            let selectedDownloading = downloader.state(for: selectedModel).isDownloading
            if selectedModelAvailable {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(server.isRunning || selectedDownloading)
                .help(server.isRunning ? "Stop server first" : "Delete selected model")
                .alert("Delete \(selectedModel.label)?", isPresented: $showDeleteConfirm) {
                    Button("Delete", role: .destructive) {
                        downloader.deleteModel(selectedModel)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You will need to download it again.")
                }
            }

            Spacer()

            Button("Quit") {
                server.stop()
                NSApp.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}

private enum AppPhase {
    case needsModel
    case downloading
    case ready
}
