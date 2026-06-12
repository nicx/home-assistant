import Foundation

/// User-facing configuration, persisted in `UserDefaults`.
///
/// Every property writes through to `UserDefaults` on `didSet` so that the
/// `ServerController` and `BackupManager` always read the current values, and
/// SwiftUI views can bind directly via `@Published`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: Server

    /// TCP port the Home Assistant frontend listens on. Home Assistant reads its
    /// port from `configuration.yaml` (`http: server_port:`), not a CLI flag, so
    /// this value is used to build the dashboard URL. Default is 8123.
    @Published var port: Int { didSet { defaults.set(port, forKey: Keys.port) } }
    /// Home Assistant configuration directory (passed as `-c`). Holds
    /// `configuration.yaml`, the database, secrets and all integration data.
    @Published var configPath: String { didSet { defaults.set(configPath, forKey: Keys.configPath) } }
    /// Pass `-v` to Home Assistant for more verbose logging.
    @Published var verbose: Bool { didSet { defaults.set(verbose, forKey: Keys.verbose) } }
    @Published var autoRestart: Bool { didSet { defaults.set(autoRestart, forKey: Keys.autoRestart) } }

    // MARK: Backup

    @Published var backupDirectory: String { didSet { defaults.set(backupDirectory, forKey: Keys.backupDirectory) } }
    @Published var backupEnabled: Bool { didSet { defaults.set(backupEnabled, forKey: Keys.backupEnabled) } }
    /// Hour of day (0-23) for the daily backup.
    @Published var backupHour: Int { didSet { defaults.set(backupHour, forKey: Keys.backupHour) } }
    /// Minute of hour (0-59) for the daily backup.
    @Published var backupMinute: Int { didSet { defaults.set(backupMinute, forKey: Keys.backupMinute) } }
    /// How many of the most recent backup archives to keep.
    @Published var backupRetention: Int { didSet { defaults.set(backupRetention, forKey: Keys.backupRetention) } }
    /// Stop the server during the snapshot for a consistent backup, then restart it.
    @Published var stopDuringBackup: Bool { didSet { defaults.set(stopDuringBackup, forKey: Keys.stopDuringBackup) } }

    // MARK: Update notifications (via local MailRelay)

    /// Send an e-mail when a newer Home Assistant version is available on PyPI.
    @Published var notifyOnUpdate: Bool { didSet { defaults.set(notifyOnUpdate, forKey: Keys.notifyOnUpdate) } }
    /// Send an e-mail on faults: crash, exhausted auto-restart, backup failure.
    @Published var notifyOnProblem: Bool { didSet { defaults.set(notifyOnProblem, forKey: Keys.notifyOnProblem) } }
    /// Recipient of the update e-mail. Empty disables mailing.
    @Published var mailRecipient: String { didSet { defaults.set(mailRecipient, forKey: Keys.mailRecipient) } }
    /// From-header; empty ⇒ use the recipient.
    @Published var mailSender: String { didSet { defaults.set(mailSender, forKey: Keys.mailSender) } }
    /// Local mail relay host (MailRelay default 127.0.0.1).
    @Published var smtpHost: String { didSet { defaults.set(smtpHost, forKey: Keys.smtpHost) } }
    /// Local mail relay port (MailRelay default 2525).
    @Published var smtpPort: Int { didSet { defaults.set(smtpPort, forKey: Keys.smtpPort) } }

    private init() {
        port = (defaults.object(forKey: Keys.port) as? Int) ?? 8123
        configPath = (defaults.string(forKey: Keys.configPath)) ?? AppSettings.defaultConfigPath
        verbose = (defaults.object(forKey: Keys.verbose) as? Bool) ?? false
        autoRestart = (defaults.object(forKey: Keys.autoRestart) as? Bool) ?? true

        backupDirectory = (defaults.string(forKey: Keys.backupDirectory)) ?? AppSettings.defaultBackupDirectory
        backupEnabled = (defaults.object(forKey: Keys.backupEnabled) as? Bool) ?? true
        backupHour = (defaults.object(forKey: Keys.backupHour) as? Int) ?? 3
        backupMinute = (defaults.object(forKey: Keys.backupMinute) as? Int) ?? 0
        backupRetention = (defaults.object(forKey: Keys.backupRetention) as? Int) ?? 7
        stopDuringBackup = (defaults.object(forKey: Keys.stopDuringBackup) as? Bool) ?? false

        notifyOnUpdate = (defaults.object(forKey: Keys.notifyOnUpdate) as? Bool) ?? false
        notifyOnProblem = (defaults.object(forKey: Keys.notifyOnProblem) as? Bool) ?? false
        mailRecipient = (defaults.string(forKey: Keys.mailRecipient)) ?? ""
        mailSender = (defaults.string(forKey: Keys.mailSender)) ?? ""
        smtpHost = (defaults.string(forKey: Keys.smtpHost)) ?? "127.0.0.1"
        smtpPort = (defaults.object(forKey: Keys.smtpPort) as? Int) ?? 2525
    }

    /// Compare Home Assistant CalVer strings (e.g. "2026.6.2"). Returns true if
    /// `candidate` is strictly newer than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    var configURL: URL { URL(fileURLWithPath: configPath, isDirectory: true) }
    var backupURL: URL { URL(fileURLWithPath: backupDirectory, isDirectory: true) }
    var dashboardURL: URL { URL(string: "http://localhost:\(port)")! }

    /// Base directory for all Home Assistant data. Intentionally under
    /// `~/Library/HomeAssistant` (NOT `Application Support`) because the path
    /// must contain no spaces: Home Assistant installs integration dependencies
    /// at runtime via `uv`, which mis-parses an interpreter/venv path that
    /// contains a space (e.g. ".../Application Support/...").
    static func defaultSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("HomeAssistant", isDirectory: true)
    }

    /// Single source of truth for the default locations, also used by the reset
    /// action so the UI and `init` never drift apart.
    static var defaultConfigPath: String {
        defaultSupportDirectory().appendingPathComponent("config").path
    }
    static var defaultBackupDirectory: String {
        defaultSupportDirectory().appendingPathComponent("backups").path
    }

    var configPathIsDefault: Bool { configPath == AppSettings.defaultConfigPath }

    func resetConfigPathToDefault() {
        configPath = AppSettings.defaultConfigPath
    }

    private enum Keys {
        static let port = "server.port"
        static let configPath = "server.configPath"
        static let verbose = "server.verbose"
        static let autoRestart = "server.autoRestart"
        static let backupDirectory = "backup.directory"
        static let backupEnabled = "backup.enabled"
        static let backupHour = "backup.hour"
        static let backupMinute = "backup.minute"
        static let backupRetention = "backup.retention"
        static let stopDuringBackup = "backup.stopDuring"
        static let notifyOnUpdate = "update.notifyByMail"
        static let notifyOnProblem = "notify.onProblem"
        static let mailRecipient = "update.mailRecipient"
        static let mailSender = "update.mailSender"
        static let smtpHost = "update.smtpHost"
        static let smtpPort = "update.smtpPort"
    }
}
