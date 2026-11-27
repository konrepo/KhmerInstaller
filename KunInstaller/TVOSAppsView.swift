import Foundation
import SwiftUI

struct TVOSAppsView: View {

    @EnvironmentObject private var ipaHandoff: TVOSIPAHandoff

    @State private var catalog: TVOSAppCatalog?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @StateObject private var downloader = TVOSAppDownloader()
    @State private var downloadingVariantKey: String?
    @State private var downloadMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    ScrollViewReader { proxy in
                        List {
                            if let downloadMessage {
                                Section {
                                    Text(downloadMessage)
                                        .font(.caption)
                                }
                            }

                            ForEach(catalog.apps) { app in
                                TVOSAppRow(
                                    app: app,
                                    isDownloading: downloader.isDownloading,
                                    downloadingVariantKey: downloadingVariantKey,
                                    progress: downloader.progress,
                                    onDownload: { variant in
                                        Task {
                                            await downloadIPA(
                                                variant,
                                                appID: app.id
                                            )
                                        }
                                    },
                                    onCancel: {
                                        downloader.cancel()
                                    }
                                )
                                .id(app.id)
                            }
                        }
                        .onChange(of: downloadingVariantKey) { _, key in
                            guard let key else { return }

                            let appID = String(
                                key.split(separator: ":").first ?? ""
                            )

                            proxy.scrollTo(appID, anchor: .center)
                        }
                    }
                } else if isLoading {
                    ProgressView("Loading tvOS Apps...")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Unable to Load Apps",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else {
                    ContentUnavailableView(
                        "No Apps Available",
                        systemImage: "appletv"
                    )
                }
            }
            .navigationTitle("tvOS Apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadCatalog() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await loadCatalog()
            }
        }
    }

    @MainActor
    private func downloadIPA(
        _ variant: TVOSAppVariant,
        appID: String
    ) async {
        guard !downloader.isDownloading else { return }

        downloadingVariantKey = appID + ":" + variant.id
        downloadMessage = nil

        do {
            let url = try await downloader.download(variant: variant)

            guard ipaHandoff.prepare(url) else {
                // Only remove the file returned by this download.
                // Never touch signed IPA storage.
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "KhmerInstaller-AppLibrary",
                        isDirectory: true
                    )
                    .standardizedFileURL

                let normalized = url.standardizedFileURL

                if normalized.deletingLastPathComponent() == directory,
                   normalized.pathExtension.lowercased() == "ipa",
                   UUID(
                       uuidString: normalized
                           .deletingPathExtension()
                           .lastPathComponent
                   ) != nil {
                    try? FileManager.default.removeItem(at: normalized)
                }

                throw TVOSDownloadError.invalidIPA
            }

            downloadMessage = "IPA downloaded. Opening Installer..."
        } catch is CancellationError {
            downloadMessage = "Download canceled."
        } catch {
            downloadMessage = error.localizedDescription
        }

        downloadingVariantKey = nil
    }

    @MainActor
    private func loadCatalog() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            catalog = try await TVOSCatalogService.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
