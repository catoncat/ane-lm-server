// SPDX-License-Identifier: MIT
// MenuBarView.swift — The popover UI shown from the menu bar icon

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var downloader: ModelDownloader

    @State private var copied = false
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Header
            HStack {
                Text("ANE-LM Server")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(server.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }

            Divider()

            // Status
            HStack(spacing: 6) {
                Image(systemName: server.isRunning
                      ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(server.isRunning ? .green : .secondary)
                Text(server.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Error
            if let err = server.lastError ?? downloader.error {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // Download progress
            if downloader.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Downloading model...")
                            .font(.caption)
                        Spacer()
                        Text("\(downloader.fileIndex)/\(downloader.fileCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: downloader.progress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(downloader.currentFile)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if downloader.totalBytes > 0 {
                            Text("\(ModelDownloader.formatBytes(downloader.downloadedBytes)) / \(ModelDownloader.formatBytes(downloader.totalBytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            // API URL
            if server.isRunning {
                HStack {
                    Text(server.apiBaseURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(server.apiBaseURL, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            // Action buttons
            HStack {
                if !downloader.modelExists && !downloader.isDownloading {
                    Button("Download Model") {
                        downloader.downloadModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if downloader.isDownloading {
                    Button("Cancel") {
                        downloader.cancel()
                    }
                    .controlSize(.small)
                } else {
                    Button(server.isRunning ? "Stop" : "Start") {
                        if server.isRunning {
                            server.stop()
                        } else {
                            server.start(modelPath: downloader.modelPath)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(server.isRunning ? .red : .green)

                    Button("Delete Model") {
                        showDeleteConfirm = true
                    }
                    .controlSize(.small)
                    .disabled(server.isRunning)
                    .alert("Delete Model?", isPresented: $showDeleteConfirm) {
                        Button("Delete", role: .destructive) {
                            downloader.deleteModel()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will remove all downloaded model files.")
                    }
                }

                Spacer()

                Button("Quit") {
                    server.stop()
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }

            // Mirror picker (shown when model not downloaded or downloading)
            if !downloader.modelExists || downloader.isDownloading {
                Picker("Mirror", selection: $downloader.mirror) {
                    ForEach(MirrorSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(downloader.isDownloading)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            // Auto-start if model exists
            if downloader.modelExists && !server.isRunning {
                server.start(modelPath: downloader.modelPath)
            }
        }
    }
}
