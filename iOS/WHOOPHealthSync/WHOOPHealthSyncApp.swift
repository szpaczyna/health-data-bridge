import AppIntents
import SwiftUI

@main
struct WHOOPHealthSyncApp: App {
    init() {
        WHOOPHealthSyncShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
