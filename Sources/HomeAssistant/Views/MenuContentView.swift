import SwiftUI
import AppKit

/// The menu shown when the user clicks the menu-bar icon.
struct MenuContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var backup: BackupManager
    @EnvironmentObject var loginItem: LoginItemManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if let version = server.detectedVersion {
            Text("Version \(version)").font(.caption)
        }

        Divider()

        Button("Starten") { server.start() }
            .disabled(server.status.isActive)
        Button("Stoppen") { server.stop() }
            .disabled(!server.status.isActive)
        Button("Neu starten") { server.restart() }
            .disabled(!server.status.isActive)

        Divider()

        Button("Dashboard öffnen") { NSWorkspace.shared.open(settings.dashboardURL) }
            .disabled(server.status != .running)
        Button("Protokoll anzeigen…") { openWindow(id: "logs"); NSApp.activate(ignoringOtherApps: true) }

        Divider()

        Button(backup.isBusy ? "Sichere…" : "Jetzt sichern") {
            Task { await backup.runBackup(reason: "manual") }
        }
        .disabled(backup.isBusy)
        if let last = backup.lastBackupDate {
            Text("Letzte Sicherung: \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption)
        }

        Divider()

        Toggle("Beim Anmelden starten", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        ))

        SettingsLink {
            Text("Einstellungen…")
        }

        Divider()

        Button("Home Assistant beenden") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch server.status {
        case .stopped: return "Server gestoppt"
        case .installing(let message): return message
        case .starting: return "Server startet…"
        case .stopping: return "Server stoppt…"
        case .crashed(let reason): return "Server abgestürzt (\(reason))"
        case .running:
            let uptime = server.uptimeDescription.map { " · seit \($0)" } ?? ""
            return "Server läuft · :\(settings.port)\(uptime)"
        }
    }
}
