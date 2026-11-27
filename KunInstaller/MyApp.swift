import SwiftUI

@main struct MyApp: App {
    init() {
        IPAWorkspace.cleanupAbandonedWorkspaces()
        TVOSIPAHandoff.cleanupAbandonedDownloads()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}
