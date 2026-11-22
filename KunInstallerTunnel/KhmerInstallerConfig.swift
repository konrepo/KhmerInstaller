import Foundation

enum KhmerInstallerConfig {
    static let appGroupID: String = {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "KhmerInstallerAppGroup"
        ) as? String,
        !value.isEmpty,
        !value.contains("$(")
        else {
            fatalError(
                "KhmerInstallerAppGroup is missing or invalid in Info.plist."
            )
        }

        return value
    }()
}
