import Foundation

/// Sends a plain-SMTP e-mail through the local MailRelay (no auth, no TLS),
/// matching how the evcc menu app does it. Rather than reimplement SMTP in
/// Swift, this drives Python's battle-tested `smtplib` via the interpreter that
/// is already bundled in the app — so there is no extra dependency and no
/// dependency on the Home Assistant virtualenv existing yet.
enum Mailer {

    /// Send a message. Best-effort: returns false on any failure (e.g. the
    /// relay is not running) instead of throwing.
    @MainActor
    static func send(subject: String, body: String, settings: AppSettings) async -> Bool {
        let recipient = settings.mailRecipient.trimmingCharacters(in: .whitespaces)
        guard !recipient.isEmpty else { return false }
        let sender = settings.mailSender.trimmingCharacters(in: .whitespaces).isEmpty
            ? recipient : settings.mailSender
        return await send(host: settings.smtpHost, port: settings.smtpPort,
                          sender: sender, recipient: recipient,
                          subject: subject, body: body)
    }

    static func send(host: String, port: Int, sender: String, recipient: String,
                     subject: String, body: String) async -> Bool {
        // Values are passed via environment, not argv, to avoid any quoting
        // issues with multi-line bodies or unusual characters.
        let script = """
        import os, smtplib
        from email.message import EmailMessage
        m = EmailMessage()
        m["From"] = os.environ["MR_FROM"]
        m["To"] = os.environ["MR_TO"]
        m["Subject"] = os.environ["MR_SUBJECT"]
        m.set_content(os.environ["MR_BODY"])
        with smtplib.SMTP(os.environ["MR_HOST"], int(os.environ["MR_PORT"]), timeout=15) as s:
            s.send_message(m)
        """

        let proc = Process()
        proc.executableURL = BundledRuntime.bundledPythonURL
        proc.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["MR_FROM"] = sender
        env["MR_TO"] = recipient
        env["MR_SUBJECT"] = subject
        env["MR_BODY"] = body
        env["MR_HOST"] = host
        env["MR_PORT"] = String(port)
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            proc.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus == 0)
            }
            do { try proc.run() } catch { cont.resume(returning: false) }
        }
    }
}
