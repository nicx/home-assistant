import Foundation
import UserNotifications

/// Creates timestamped `.zip` snapshots of the Home Assistant configuration
/// directory, enforces a retention limit, can restore from a snapshot, and runs
/// a daily backup on an app-internal timer (with catch-up on launch).
@MainActor
final class BackupManager: ObservableObject {

    @Published private(set) var isBusy = false
    @Published private(set) var lastBackupDate: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var backups: [URL] = []

    private let settings: AppSettings
    private let server: ServerController
    private let log: LogStore
    private let notifier: Notifier
    private var timer: Timer?

    private let lastBackupKey = "backup.lastDate"

    init(settings: AppSettings, server: ServerController, log: LogStore, notifier: Notifier) {
        self.settings = settings
        self.server = server
        self.log = log
        self.notifier = notifier
        lastBackupDate = UserDefaults.standard.object(forKey: lastBackupKey) as? Date
        refreshList()
    }

    // MARK: - Scheduling

    /// (Re)arm the daily timer and run a catch-up backup if we have missed one.
    func startScheduling() {
        rescheduleTimer()
        if settings.backupEnabled {
            let due = lastBackupDate.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true
            if due {
                log.appendSystem("Catch-up backup (none in the last 24h)")
                Task { await self.runBackup(reason: "scheduled") }
            }
        }
    }

    func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard settings.backupEnabled else { return }
        let fireDate = nextFireDate()
        let t = Timer(fireAt: fireDate, interval: 0, target: self,
                      selector: #selector(timerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log.appendSystem("Next backup scheduled for \(fireDate)")
    }

    @objc private func timerFired() {
        Task {
            await runBackup(reason: "scheduled")
            rescheduleTimer() // arm for the next day
        }
    }

    private func nextFireDate() -> Date {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = settings.backupHour
        comps.minute = settings.backupMinute
        comps.second = 0
        let today = cal.date(from: comps) ?? now
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    // MARK: - Backup

    @discardableResult
    func runBackup(reason: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        let config = settings.configURL
        guard FileManager.default.fileExists(atPath: config.path) else {
            fail("Configuration directory does not exist: \(config.path)")
            return false
        }

        do {
            try FileManager.default.createDirectory(at: settings.backupURL, withIntermediateDirectories: true)
        } catch {
            fail("Cannot create backup directory: \(error.localizedDescription)")
            return false
        }

        // Optionally stop the server for a consistent snapshot.
        var shouldRestart = false
        if settings.stopDuringBackup {
            shouldRestart = server.stopForMaintenance()
            if shouldRestart { await waitUntilStopped(timeout: 15) }
        }

        let archive = settings.backupURL.appendingPathComponent(archiveName())
        // Write to a temporary file first and move it into place only on
        // success, so an interrupted backup never leaves a corrupt .zip with
        // the real name.
        let partial = archive.appendingPathExtension("partial")
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: settings.backupURL, includingPropertiesForKeys: nil) {
            for f in leftovers where f.pathExtension == "partial" { try? FileManager.default.removeItem(at: f) }
        }
        log.appendSystem("Backup (\(reason)) → \(archive.lastPathComponent)")

        let ok: Bool
        do {
            try? FileManager.default.removeItem(at: partial)
            try await ditto(["-c", "-k", "--norsrc", "--noextattr", "--keepParent", config.path, partial.path])
            try FileManager.default.moveItem(at: partial, to: archive)
            ok = true
        } catch {
            try? FileManager.default.removeItem(at: partial)
            fail("Backup failed: \(error.localizedDescription)")
            ok = false
        }

        if shouldRestart { server.start() }

        if ok {
            lastBackupDate = Date()
            UserDefaults.standard.set(lastBackupDate, forKey: lastBackupKey)
            pruneRetention()
            refreshList()
            notify(title: "Home Assistant backup complete", body: archive.lastPathComponent)
            // Sends a "wieder erfolgreich" mail only if a prior backup had failed.
            notifier.report(HAConditions.backup, healthy: true)
        }
        return ok
    }

    func restore(from archive: URL) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        let wasRunning = server.stopForMaintenance()
        if wasRunning { await waitUntilStopped(timeout: 15) }

        do {
            // Safety snapshot of the current state before overwriting.
            try? FileManager.default.createDirectory(at: settings.backupURL, withIntermediateDirectories: true)
            let safety = settings.backupURL.appendingPathComponent("pre-restore-\(archiveName())")
            if FileManager.default.fileExists(atPath: settings.configPath) {
                try await ditto(["-c", "-k", "--norsrc", "--noextattr", "--keepParent", settings.configPath, safety.path])
            }
            // Replace the config directory with the archive contents.
            let parent = settings.configURL.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: settings.configURL)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try await ditto(["-x", "-k", archive.path, parent.path])
            log.appendSystem("Restored from \(archive.lastPathComponent)")
            notify(title: "Home Assistant restore complete", body: archive.lastPathComponent)
        } catch {
            fail("Restore failed: \(error.localizedDescription)")
            if wasRunning { server.start() }
            return false
        }

        if wasRunning { server.start() }
        refreshList()
        return true
    }

    func refreshList() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: settings.backupURL,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        backups = items
            .filter { $0.pathExtension == "zip" && !$0.lastPathComponent.hasPrefix("pre-restore-") }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
    }

    private func pruneRetention() {
        refreshList()
        guard backups.count > settings.backupRetention else { return }
        for url in backups.dropFirst(settings.backupRetention) {
            try? FileManager.default.removeItem(at: url)
            log.appendSystem("Pruned old backup \(url.lastPathComponent)")
        }
    }

    // MARK: - Helpers

    private func archiveName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "homeassistant-\(f.string(from: Date())).zip"
    }

    private func waitUntilStopped(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while server.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Archive/extract via `ditto`. Callers pass `--norsrc --noextattr`, not
    /// `--sequesterRsrc`: the config tree carries no meaningful resource forks,
    /// and sequestering emits one `__MACOSX/._*` AppleDouble entry per file
    /// (7k of 13k entries in a real archive) for no benefit.
    private func ditto(_ args: [String]) async throws {
        try await runProcess(URL(fileURLWithPath: "/usr/bin/ditto"), args)
    }

    private func runProcess(_ executable: URL, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = executable
            proc.arguments = args
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: NSError(domain: "BackupManager", code: Int(p.terminationStatus),
                                                  userInfo: [NSLocalizedDescriptionKey: "\(executable.lastPathComponent) exited with code \(p.terminationStatus)"]))
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func fail(_ message: String) {
        lastError = message
        log.appendSystem(message)
        // Debounced problem notification (desktop + mail if enabled). One mail
        // per failure streak; a later successful backup sends the recovery mail.
        notifier.report(HAConditions.backup, healthy: false, detail: message)
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
