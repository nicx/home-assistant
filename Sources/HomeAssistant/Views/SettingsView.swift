import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ServerSettingsTab()
                .tabItem { Label("Server", systemImage: "server.rack") }
            BackupSettingsTab()
                .tabItem { Label("Sicherung", systemImage: "externaldrive.badge.timemachine") }
            GeneralSettingsTab()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
        }
        .frame(width: 500)
        .padding()
    }
}

// MARK: - Server

private struct ServerSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController

    var body: some View {
        Form {
            Section {
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                Toggle("Ausführliches Protokoll (-v)", isOn: $settings.verbose)
                Toggle("Bei Absturz automatisch neu starten", isOn: $settings.autoRestart)
            } footer: {
                Text("Der Port wird von Home Assistant aus der `configuration.yaml` (`http: server_port:`) gelesen. Dieses Feld bestimmt nur die Adresse, die „Dashboard öffnen“ verwendet — Standard ist 8123.")
            }

            Section {
                LabeledContent("Konfigurationsordner") {
                    VStack(alignment: .trailing, spacing: 4) {
                        PathChooser(path: $settings.configPath, chooseDirectory: true)
                        if !settings.configPathIsDefault {
                            Button("Auf Standard zurücksetzen") { settings.resetConfigPathToDefault() }
                                .controlSize(.small)
                        }
                    }
                }

                if settings.configPath == settings.backupDirectory {
                    Label("Konfigurations- und Sicherungsordner sollten sich unterscheiden.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Speicherort")
            } footer: {
                Text("Enthält `configuration.yaml`, die Datenbank, Secrets und alle Integrationsdaten. Wird beim ersten Start automatisch angelegt.")
            }

            Section {
                HStack {
                    Text("Änderungen werden beim nächsten Start wirksam.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Übernehmen & neu starten") { server.restart() }
                        .disabled(!server.status.isActive)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Backup

private struct BackupSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var backup: BackupManager

    var body: some View {
        Form {
            Toggle("Tägliche Sicherung aktiviert", isOn: $settings.backupEnabled)
                .onChange(of: settings.backupEnabled) { backup.rescheduleTimer() }

            LabeledContent("Sicherungsordner") {
                PathChooser(path: $settings.backupDirectory, chooseDirectory: true)
            }

            DatePicker("Täglich um", selection: backupTime, displayedComponents: .hourAndMinute)

            Stepper("Letzte \(settings.backupRetention) Sicherungen behalten",
                    value: $settings.backupRetention, in: 1...90)

            Toggle("Server während der Sicherung stoppen (konsistenter Snapshot)", isOn: $settings.stopDuringBackup)

            Divider()

            HStack {
                Button(backup.isBusy ? "Sichere…" : "Jetzt sichern") {
                    Task { await backup.runBackup(reason: "manual") }
                }
                .disabled(backup.isBusy)
                Spacer()
                if let err = backup.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }

            Section("Vorhandene Sicherungen") {
                if backup.backups.isEmpty {
                    Text("Noch keine Sicherungen").foregroundStyle(.secondary)
                } else {
                    ForEach(backup.backups, id: \.self) { url in
                        HStack {
                            Text(url.lastPathComponent).font(.callout)
                            Spacer()
                            Button("Im Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button("Wiederherstellen…") { confirmRestore(url) }
                                .disabled(backup.isBusy)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { backup.refreshList() }
    }

    private var backupTime: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = settings.backupHour
                c.minute = settings.backupMinute
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                settings.backupHour = c.hour ?? 0
                settings.backupMinute = c.minute ?? 0
                backup.rescheduleTimer()
            }
        )
    }

    private func confirmRestore(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Aus \(url.lastPathComponent) wiederherstellen?"
        alert.informativeText = "Dies stoppt den Server und ersetzt den aktuellen Konfigurationsordner. Der aktuelle Stand wird zuvor als Pre-Restore-Sicherung gespeichert."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Wiederherstellen")
        alert.addButton(withTitle: "Abbrechen")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await backup.restore(from: url) }
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var loginItem: LoginItemManager
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var env: EnvironmentManager
    @EnvironmentObject var updates: UpdateMonitor
    @State private var testMailResult: String?
    @State private var sendingTest = false

    var body: some View {
        Form {
            Toggle("Beim Anmelden starten", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            if let err = loginItem.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Section {
                LabeledContent("Home Assistant", value: BundledRuntime.installedHAVersion ?? "nicht installiert")
                LabeledContent("Python", value: BundledRuntime.bundledPythonMinor ?? "—")
                LabeledContent("Diese App", value: Self.appVersion)
            } header: {
                Text("Versionen")
            }

            Section("Aktualisierung") {
                HStack {
                    Button(updates.isChecking ? "Prüfe…" : "Nach Update suchen (PyPI)") {
                        Task { await updates.checkNow() }
                    }
                    .disabled(updates.isChecking)
                    Spacer()
                    if let latest = updates.latestVersion {
                        Text(updates.updateAvailable ? "Neueste: \(latest) — Update verfügbar" : "Neueste: \(latest) — aktuell")
                            .font(.caption)
                            .foregroundStyle(updates.updateAvailable ? Color.orange : Color.secondary)
                    }
                }
                if let err = updates.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Button(env.isWorking ? "Aktualisiere…" : "Home Assistant aktualisieren") {
                        Task {
                            let wasRunning = server.stopForMaintenance()
                            await env.updateHomeAssistant()
                            if wasRunning { server.start() }
                        }
                    }
                    .disabled(env.isWorking)
                    Spacer()
                    if let err = env.lastError {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
                Text("Aktualisiert das `homeassistant`-Paket per pip auf die neueste Version. Der Server wird dazu kurz gestoppt und danach neu gestartet.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Bei verfügbarem Update eine E-Mail senden", isOn: $settings.notifyOnUpdate)
                Toggle("Bei Störungen eine E-Mail senden (Absturz, Auto-Restart, Backup)", isOn: $settings.notifyOnProblem)
                TextField("Empfänger", text: $settings.mailRecipient, prompt: Text("name@example.com"))
                TextField("Absender (optional)", text: $settings.mailSender, prompt: Text("leer ⇒ Empfänger"))
                HStack {
                    TextField("Relay-Host", text: $settings.smtpHost)
                    TextField("Port", value: $settings.smtpPort, format: .number.grouping(.never))
                        .frame(width: 70)
                }
                HStack {
                    Button(sendingTest ? "Sende…" : "Test-E-Mail senden") {
                        Task {
                            sendingTest = true; testMailResult = nil
                            let ok = await Mailer.send(
                                subject: "Home Assistant: Test-E-Mail",
                                body: "Dies ist eine Test-E-Mail der Home Assistant Menüleisten-App.",
                                settings: settings)
                            testMailResult = ok ? "gesendet ✓" : "fehlgeschlagen (läuft MailRelay?)"
                            sendingTest = false
                        }
                    }
                    .disabled(sendingTest || settings.mailRecipient.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    if let r = testMailResult {
                        Text(r).font(.caption).foregroundStyle(r.hasSuffix("✓") ? Color.secondary : Color.red)
                    }
                }
            } header: {
                Text("E-Mail-Benachrichtigung")
            } footer: {
                Text("Verschickt über den lokalen MailRelay (Standard 127.0.0.1:2525), wie bei evcc. Die Versionsprüfung läuft beim Start und alle 6 Stunden; pro Version wird höchstens eine Mail gesendet.")
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
}

// MARK: - Reusable path chooser

private struct PathChooser: View {
    @Binding var path: String
    var chooseDirectory: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(path).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary).font(.callout)
            Spacer()
            Button("Wählen…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = chooseDirectory
        panel.canChooseFiles = !chooseDirectory
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}
