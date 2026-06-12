import SwiftUI
import UserNotifications

/// Owns the long-lived managers and wires up lifecycle (notifications, server
/// auto-start, backup scheduling, clean shutdown).
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let log: LogStore
    let env: EnvironmentManager
    let server: ServerController
    let backup: BackupManager
    let loginItem: LoginItemManager
    let updates: UpdateMonitor
    let notifier: Notifier

    init() {
        let settings = AppSettings.shared
        let log = LogStore()
        let env = EnvironmentManager(log: log)
        let notifier = Notifier(settings: settings, log: log)
        let server = ServerController(settings: settings, log: log, env: env, notifier: notifier)
        self.settings = settings
        self.log = log
        self.env = env
        self.notifier = notifier
        self.server = server
        self.backup = BackupManager(settings: settings, server: server, log: log, notifier: notifier)
        self.loginItem = LoginItemManager()
        self.updates = UpdateMonitor(settings: settings, log: log)
    }

    func bootstrap() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        server.start()
        backup.startScheduling()
        updates.startScheduling()
    }

    func shutdown() {
        server.terminateNow()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon (also set via LSUIElement)
        env.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.shutdown()
    }
}

@main
struct HomeAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let env = delegate.env

        MenuBarExtra {
            MenuContentView()
                .environmentObject(env.settings)
                .environmentObject(env.server)
                .environmentObject(env.backup)
                .environmentObject(env.loginItem)
        } label: {
            MenuBarLabel(server: env.server)
        }

        Settings {
            SettingsView()
                .environmentObject(env.settings)
                .environmentObject(env.server)
                .environmentObject(env.backup)
                .environmentObject(env.loginItem)
                .environmentObject(env.env)
                .environmentObject(env.updates)
        }

        Window("Home Assistant Logs", id: "logs") {
            LogView()
                .environmentObject(env.log)
                .environmentObject(env.server)
                .environmentObject(env.settings)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Monochrome menu-bar icon that reflects the server status. SF Symbols render
/// as template images, so AppKit tints them for light/dark menu bars.
struct MenuBarLabel: View {
    @ObservedObject var server: ServerController

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel("Home Assistant")
    }

    private var symbolName: String {
        switch server.status {
        case .running: return "house.fill"
        case .installing: return "arrow.down.circle"
        case .starting, .stopping: return "house"
        case .stopped: return "house"
        case .crashed: return "exclamationmark.triangle.fill"
        }
    }
}
