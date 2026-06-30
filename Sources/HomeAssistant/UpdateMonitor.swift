import Foundation
import UserNotifications

/// Periodically checks PyPI for a newer Home Assistant release and, when one
/// appears, notifies the user — by e-mail through the local MailRelay (if
/// configured) and via a desktop notification. Notifies at most once per
/// version (debounced through `lastNotifiedVersion`).
@MainActor
final class UpdateMonitor: ObservableObject {

    @Published private(set) var latestVersion: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isChecking = false

    private let settings: AppSettings
    private let log: LogStore
    private var timer: Timer?

    /// How often to poll PyPI for a new release.
    private let interval: TimeInterval = 6 * 3600
    private let lastNotifiedKey = "update.lastNotifiedVersion"

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
    }

    private var lastNotifiedVersion: String? {
        get { UserDefaults.standard.string(forKey: lastNotifiedKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastNotifiedKey) }
    }

    /// True if the latest known PyPI version is newer than what is installed.
    var updateAvailable: Bool {
        guard let latest = latestVersion, let installed = BundledRuntime.installedHAVersion else { return false }
        return AppSettings.isNewer(latest, than: installed)
    }

    // MARK: - Scheduling

    func startScheduling() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // First check shortly after launch — but give a fresh first-run install
        // time to finish so `installedHAVersion` is populated.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            await checkNow()
        }
    }

    // MARK: - Check + notify

    @discardableResult
    func checkNow() async -> String? {
        isChecking = true
        lastError = nil
        defer { isChecking = false }
        guard let url = URL(string: "https://pypi.org/pypi/homeassistant/json") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = obj["info"] as? [String: Any],
                  let version = info["version"] as? String else {
                lastError = "Unerwartete Antwort von PyPI"
                return nil
            }
            latestVersion = version
            lastChecked = Date()
            await maybeNotify(latest: version)
            return version
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func maybeNotify(latest: String) async {
        guard let installed = BundledRuntime.installedHAVersion,
              AppSettings.isNewer(latest, than: installed) else { return }
        // Debounce: never notify twice for the same available version.
        guard latest != lastNotifiedVersion else { return }

        let subject = "Home Assistant \(latest) verfügbar"
        let changelogURL = "https://github.com/home-assistant/core/releases/tag/\(latest)"
        let body = """
        Eine neue Home Assistant-Version ist verfügbar.

        Installiert: \(installed)
        Verfügbar:   \(latest)

        Changelog: \(changelogURL)

        Aktualisieren über das Menüleisten-Symbol → Einstellungen → Allgemein → \
        „Home Assistant aktualisieren“.
        """

        // If mailing is requested, it must succeed before we mark the version as
        // handled — otherwise (e.g. MailRelay offline) we retry on the next poll.
        if settings.notifyOnUpdate && !settings.mailRecipient.trimmingCharacters(in: .whitespaces).isEmpty {
            let ok = await Mailer.send(subject: subject, body: body, settings: settings)
            if ok {
                log.appendSystem("Update notice mailed to \(settings.mailRecipient): \(latest)")
            } else {
                lastError = "E-Mail über \(settings.smtpHost):\(settings.smtpPort) fehlgeschlagen (läuft MailRelay?)"
                log.appendSystem("Update mail failed (\(settings.smtpHost):\(settings.smtpPort)); will retry")
                return // do not mark handled; retry next cycle
            }
        }

        postDesktopNotification(subject: subject, body: "Installiert \(installed) → verfügbar \(latest)")
        lastNotifiedVersion = latest
    }

    private func postDesktopNotification(subject: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = subject
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
