import AppIntents
import BackgroundTasks
import SwiftUI
#if os(iOS)
import UIKit
#endif

private let backgroundRefreshIdentifier = "com.joselourido.WHOOPHealthSync.sync"
private let backgroundRefreshInterval: TimeInterval = 15 * 60

@main
struct WHOOPHealthSyncApp: App {
    init() {
        WHOOPHealthSyncShortcuts.updateAppShortcutParameters()
        #if os(iOS)
        Self.registerBackgroundRefresh()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }

    #if os(iOS)
    private static func registerBackgroundRefresh() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let syncTask = Task { @MainActor in
                guard UIApplication.shared.isProtectedDataAvailable,
                      case .authenticated = LiveSyncRuntime.shared.authService.currentStatus() else {
                    await Self.scheduleBackgroundRefresh()
                    refreshTask.setTaskCompleted(success: true)
                    return
                }

                do {
                    try await LiveSyncRuntime.shared.synchronize()
                } catch {
                    AppLog.sync.error("Background refresh failed: \(error.localizedDescription, privacy: .public)")
                }
                await Self.scheduleBackgroundRefresh()
                refreshTask.setTaskCompleted(success: !Task.isCancelled)
            }

            refreshTask.expirationHandler = {
                syncTask.cancel()
            }
        }

        guard registered else {
            AppLog.sync.error("Background refresh registration rejected")
            return
        }

        Task { await Self.scheduleBackgroundRefresh() }
    }

    private static func scheduleBackgroundRefresh() async {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(backgroundRefreshInterval)
        do {
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
        } catch {
            AppLog.sync.error("Failed to schedule background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
