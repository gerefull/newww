import SwiftUI

@main
struct NineGhostNovaApp: App {
    @StateObject private var bluetooth = NovaBluetoothController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bluetooth)
                .preferredColorScheme(.dark)
        }
    }
}

