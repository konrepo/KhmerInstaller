import Foundation

struct TVOSAppCatalog: Decodable {

    let schemaVersion: Int
    let platform: String
    let apps: [TVOSCatalogApp]
}

struct TVOSCatalogApp: Decodable, Identifiable {

    let id: String
    let name: String
    // Supports both older catalogs and developer-based catalogs.
    let developer: TVOSAppDeveloper?
    let description: String?
    let version: String
    let category: String
    let source: String
    let sourceURL: URL?
    let iconURL: URL?
    let variants: [TVOSAppVariant]
}

struct TVOSAppDeveloper: Decodable {
    let name: String
    let url: URL?
}

struct TVOSAppVariant: Decodable, Identifiable {

    let id: String
    let name: String
    let fileName: String
    let ipaURL: URL
}

enum TVOSCatalogError: LocalizedError {

    case invalidCatalog
    case invalidDownloadURL

    var errorDescription: String? {
        switch self {
        case .invalidCatalog:
            return "The tvOS app catalog is invalid."
        case .invalidDownloadURL:
            return "The app download URL is invalid."
        }
    }
}

enum TVOSCatalogService {

    static let catalogURL = URL(
        string:
            "https://raw.githubusercontent.com/"
            + "konrepo/KhmerInstaller/main/AppLibrary/apps.json"
    )!

    static func load() async throws -> TVOSAppCatalog {

        var request = URLRequest(
            url: catalogURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )

        request.setValue(
            "no-cache",
            forHTTPHeaderField: "Cache-Control"
        )

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 1_000_000 else {
            throw TVOSCatalogError.invalidCatalog
        }

        let catalog = try JSONDecoder().decode(
            TVOSAppCatalog.self,
            from: data
        )

        guard catalog.schemaVersion == 1,
              catalog.platform == "tvOS",
              !catalog.apps.isEmpty else {
            throw TVOSCatalogError.invalidCatalog
        }

        for app in catalog.apps {

            guard !app.id.isEmpty,
                  !app.name.isEmpty,
                  !app.variants.isEmpty else {
                throw TVOSCatalogError.invalidCatalog
            }

            if let iconURL = app.iconURL {
                guard iconURL.scheme?.lowercased() == "https" else {
                    throw TVOSCatalogError.invalidDownloadURL
                }
            }

            if let developerURL = app.developer?.url {
                guard developerURL.scheme?.lowercased() == "https" else {
                    throw TVOSCatalogError.invalidDownloadURL
                }
            }

            for variant in app.variants {
                guard
                    variant.ipaURL.scheme?.lowercased() == "https",
                    variant.fileName.lowercased().hasSuffix(".ipa"),
                    !variant.id.isEmpty
                else {
                    throw TVOSCatalogError.invalidDownloadURL
                }
            }
        }

        return catalog
    }
}
