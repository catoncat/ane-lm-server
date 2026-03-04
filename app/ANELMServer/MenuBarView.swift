// SPDX-License-Identifier: MIT
// MenuBarView.swift — The popover UI shown from the menu bar icon

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var downloader: ModelDownloader

    @State private var copied = false
    @State private var showDeleteConfirm = false

    private var phase: AppPhase {
        if downloader.isDownloading { return .downloading }
        if !downloader.modelExists { return .needsModel }
        return .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible
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
        .frame(width: 300)
        .onAppear {
            if downloader.modelExists && !server.isRunning {
                server.start(modelPath: downloader.modelPath)
            }
        }
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
            Label(server.isRunning ? "Running" : "Stopped",
                  systemImage: server.isRunning ? "circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(server.isRunning ? .green : .secondary)
        }
    }

    // MARK: - Setup (no model yet)

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download Qwen3.5-0.8B to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Mirror picker FIRST — user decides before downloading
            Picker("Source", selection: $downloader.mirror) {
                ForEach(MirrorSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)

            Button {
                downloader.downloadModel()
            } label: {
                Label("Download Model", systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    // MARK: - Downloading

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: downloader.progress)
                .progressViewStyle(.linear)

            HStack {
                Text(downloader.currentFile)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(downloader.fileIndex)/\(downloader.fileCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if downloader.totalBytes > 0 {
                HStack {
                    Text("\(ModelDownloader.formatBytes(downloader.downloadedBytes)) / \(ModelDownloader.formatBytes(downloader.totalBytes))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        downloader.cancel()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Server ready

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Error display
            if let err = server.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // API endpoint — the main thing users need
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

            // Start / Stop
            HStack {
                Button {
                    if server.isRunning {
                        server.stop()
                    } else {
                        server.start(modelPath: downloader.modelPath)
                    }
                } label: {
                    Label(server.isRunning ? "Stop Server" : "Start Server",
                          systemImage: server.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(server.isRunning ? .red : .green)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            if downloader.modelExists && !downloader.isDownloading {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(server.isRunning)
                .help(server.isRunning ? "Stop server first" : "Delete model")
                .alert("Delete downloaded model?", isPresented: $showDeleteConfirm) {
                    Button("Delete", role: .destructive) {
                        downloader.deleteModel()
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

// MARK: - Phase

private enum AppPhase {
    case needsModel
    case downloading
    case ready
}
