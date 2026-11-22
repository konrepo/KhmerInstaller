import SwiftUI

@main struct MyApp: App {
    init() {
        IPAWorkspace.cleanupAbandonedWorkspaces()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
