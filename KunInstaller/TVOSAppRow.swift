import SwiftUI

struct TVOSAppRow: View {

    let app: TVOSCatalogApp
    let isDownloading: Bool
    let downloadingVariantKey: String?
    let progress: Double
    let onDownload: (TVOSAppVariant) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {

            AsyncImage(url: app.iconURL) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                Image(systemName: "appletv")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 100, height: 60)
            .background(.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {

                Text(app.name)
                    .font(.headline)

                Text("Version " + app.version)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let developer = app.developer {
                    if let developerURL = developer.url {
                        Link(
                            developer.name,
                            destination: developerURL
                        )
                        .font(.caption)
                        .buttonStyle(.borderless)
                    } else {
                        Text(developer.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(app.description ?? "Developer not listed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(app.variants) { variant in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(variant.name)
                                .font(.caption)

                            Spacer()

                            if isDownloading &&
                                downloadingVariantKey == app.id + ":" + variant.id {
                                Button("Cancel", action: onCancel)
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                            } else {
                                Button {
                                    onDownload(variant)
                                } label: {
                                    Label(
                                        "Download",
                                        systemImage: "arrow.down.circle"
                                    )
                                    .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .disabled(isDownloading)
                            }
                        }

                        if isDownloading &&
                            downloadingVariantKey == app.id + ":" + variant.id {
                            ProgressView(value: progress)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
