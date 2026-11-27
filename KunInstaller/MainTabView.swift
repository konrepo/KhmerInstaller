import SwiftUI

struct MainTabView: View {

    @StateObject private var ipaHandoff = TVOSIPAHandoff()

    var body: some View {
        ContentView()
            .environmentObject(ipaHandoff)
    }
}
