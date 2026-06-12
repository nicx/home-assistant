import Foundation
import UserNotifications

/// A single monitored condition with its problem/recovery subjects.
struct NotifierCondition {
    let id: String
    let problemSubject: String
    let recoverySubject: String
}

enum HAConditions {
    static let serverDown = NotifierCondition(
        id: "server_down",
        problemSubject: "Home Assistant abgestürzt",
        recoverySubject: "Home Assistant wieder aktiv")
    static let backup = NotifierCondition(
        id: "backup",
        problemSubject: "Home Assistant-Backup fehlgeschlagen",
        recoverySubject: "Home Assistant-Backup wieder erfolgreich")
}

/// Debounced fault notifier, modelled on evcc's `notifier_state`. It mails (via
/// the local MailRelay) and posts a desktop notification only on a real state
/// transition — so a persistent fault or a crash-loop produces a single mail,
/// not one per occurrence — plus a "recovered" mail when the condition clears.
///
/// Problem mails are gated by `AppSettings.notifyOnProblem`; the update mails
/// are handled separately by `UpdateMonitor`.
@MainActor
final class Notifier: ObservableObject {
    private let settings: AppSettings
    private let log: LogStore
    private var inProblem: [String: Bool] = [:]

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
    }

    /// Report a condition's current health. Emits only on a transition.
    func report(_ condition: NotifierCondition, healthy: Bool, detail: String = "") {
        if healthy {
            guard inProblem[condition.id] == true else { return }
            inProblem[condition.id] = false
            emit(subject: condition.recoverySubject, body: condition.recoverySubject)
        } else {
            guard inProblem[condition.id] != true else { return }
            inProblem[condition.id] = true
            let body = detail.isEmpty ? condition.problemSubject : "\(condition.problemSubject)\n\n\(detail)"
            emit(subject: condition.problemSubject, body: body)
        }
    }

    /// Silently reset a condition to healthy WITHOUT sending a recovery mail —
    /// used when the user intentionally stops the server.
    func clear(_ condition: NotifierCondition) {
        inProblem[condition.id] = false
    }

    /// A one-off notification not tied to the healthy/problem latch
    /// (e.g. "auto-restart still failing after N attempts").
    func oneShot(subject: String, body: String) {
        emit(subject: subject, body: body)
    }

    private func emit(subject: String, body: String) {
        postDesktopNotification(subject: subject, body: body)
        guard settings.notifyOnProblem,
              !settings.mailRecipient.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let s = settings
        Task { @MainActor in
            // Subjects already begin with "Home Assistant"; no extra prefix.
            let ok = await Mailer.send(subject: subject, body: body, settings: s)
            log.appendSystem(ok
                ? "Problem mail sent: \(subject)"
                : "Problem mail failed (\(s.smtpHost):\(s.smtpPort)): \(subject)")
        }
    }

    private func postDesktopNotification(subject: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = subject
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
