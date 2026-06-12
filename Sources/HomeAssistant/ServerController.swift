import Foundation

/// Supervises the Home Assistant Python process: prepares the virtualenv on
/// first start, then start/stop/restart with crash detection and
/// exponential-backoff keepalive, log capture and version reporting.
@MainActor
final class ServerController: ObservableObject {

    enum Status: Equatable {
        case stopped
        /// Preparing the environment (creating venv / pip-installing HA).
        case installing(String)
        case starting
        case running
        case stopping
        case crashed(String)

        var isActive: Bool {
            switch self {
            case .running, .starting, .installing: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var startedAt: Date?
    @Published private(set) var detectedVersion: String?
    @Published private(set) var lastError: String?

    private let settings: AppSettings
    private let log: LogStore
    private let env: EnvironmentManager
    private let notifier: Notifier

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Set while preparing the environment before spawning the process, so a
    /// second `start()` can't run the install/launch twice concurrently.
    private var isPreparing = false
    /// Set while we are deliberately stopping, so the termination handler does
    /// not treat the exit as a crash and restart it.
    private var intentionalStop = false
    /// Set when a restart was requested; the relaunch happens once the current
    /// process has fully terminated (see `handleTermination`).
    private var startAfterStop = false
    private var restartAttempt = 0
    private var pendingRestart: DispatchWorkItem?
    private let backoffSeconds: [Double] = [1, 2, 5, 10, 30, 60]
    /// After this many consecutive failed auto-restarts, escalate with a
    /// distinct "auto-restart still failing" notification (once per episode).
    private let restartEscalateThreshold = 5
    private var escalatedThisEpisode = false

    init(settings: AppSettings, log: LogStore, env: EnvironmentManager, notifier: Notifier) {
        self.settings = settings
        self.log = log
        self.env = env
        self.notifier = notifier
        self.detectedVersion = BundledRuntime.installedHAVersion
    }

    // MARK: - Public control

    /// True while a child process handle is alive (running or shutting down).
    var isRunning: Bool { process != nil }

    func start() {
        guard process == nil, !isPreparing else {
            log.appendSystem("Start ignored: already running or preparing")
            return
        }
        pendingRestart?.cancel()
        pendingRestart = nil
        Task { await startAsync() }
    }

    private func startAsync() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            status = .installing("Prüfe Laufzeitumgebung…")
            try await env.ensureReady { [weak self] message in
                guard let self, case .installing = self.status else { return }
                self.status = .installing(message)
            }
            detectedVersion = BundledRuntime.installedHAVersion
            try FileManager.default.createDirectory(at: settings.configURL, withIntermediateDirectories: true)
            try BundledRuntime.validate()
            try launch(arguments: BundledRuntime.arguments(for: settings))
        } catch {
            status = .crashed(error.localizedDescription)
            lastError = error.localizedDescription
            log.appendSystem("Start failed: \(error.localizedDescription)")
        }
    }

    /// Stop the server intentionally (no keepalive restart).
    func stop() {
        intentionalStop = true
        pendingRestart?.cancel()
        pendingRestart = nil
        terminateProcess()
    }

    func restart() {
        log.appendSystem("Restart requested")
        if process != nil {
            startAfterStop = true
            stop()
        } else {
            start()
        }
    }

    /// Synchronously terminate the child before the app exits, so no orphaned
    /// Home Assistant process survives to hold the config/database locks.
    func terminateNow() {
        intentionalStop = true
        startAfterStop = false
        pendingRestart?.cancel()
        pendingRestart = nil
        guard let proc = process, proc.isRunning else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { kill(pid, SIGKILL) }
    }

    /// Used by the backup flow: stop for maintenance and report whether the
    /// server was actually running so the caller can decide to restart it.
    func stopForMaintenance() -> Bool {
        let wasActive = status.isActive
        if wasActive { stop() }
        return wasActive
    }

    var uptimeDescription: String? {
        guard status == .running, let startedAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    // MARK: - Process lifecycle

    private func launch(arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = BundledRuntime.venvPythonURL
        proc.arguments = arguments
        proc.currentDirectoryURL = settings.configURL

        var environment = ProcessInfo.processInfo.environment
        let venvBin = BundledRuntime.venvPythonURL.deletingLastPathComponent().path
        environment["PATH"] = venvBin + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["PYTHONUNBUFFERED"] = "1"
        proc.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        installReader(outPipe)
        installReader(errPipe)

        proc.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async {
                self?.handleTermination(code: code)
            }
        }

        intentionalStop = false
        status = .starting
        startedAt = nil
        lastError = nil
        log.appendSystem("Starting Home Assistant (config: \(settings.configPath))")

        try proc.run()
        process = proc
        stdoutPipe = outPipe
        stderrPipe = errPipe

        // Home Assistant takes a while to fully boot, but a successful spawn is
        // enough to treat it as running; an immediate crash is handled by the
        // keepalive. The frontend on :8123 comes up a little later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.status == .starting else { return }
            self.status = .running
            self.startedAt = Date()
            self.restartAttempt = 0
            self.escalatedThisEpisode = false
            // Clears a prior crash episode and sends a "wieder aktiv" mail only
            // if we had previously reported the server as down.
            self.notifier.report(HAConditions.serverDown, healthy: true)
        }
    }

    private func installReader(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.log.append(text)
            }
        }
    }

    private func terminateProcess() {
        guard let proc = process, proc.isRunning else { return }
        if status == .running || status == .starting { status = .stopping }
        proc.terminate() // SIGTERM
        let pid = proc.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func handleTermination(code: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        startedAt = nil

        if intentionalStop {
            status = .stopped
            log.appendSystem("Server stopped")
            // A deliberate stop is not a fault: reset silently so no crash or
            // recovery mail is sent.
            notifier.clear(HAConditions.serverDown)
            escalatedThisEpisode = false
            if startAfterStop {
                startAfterStop = false
                start()
            }
            return
        }

        let reason = "exited with code \(code)"
        status = .crashed(reason)
        lastError = reason
        log.appendSystem("Server \(reason)")
        // Debounced: one "abgestürzt" mail per down-episode, regardless of how
        // many auto-restart attempts follow.
        notifier.report(HAConditions.serverDown, healthy: false, detail: reason)

        guard settings.autoRestart else { return }
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = backoffSeconds[min(restartAttempt, backoffSeconds.count - 1)]
        restartAttempt += 1
        log.appendSystem("Auto-restart in \(Int(delay))s (attempt \(restartAttempt))")
        if restartAttempt >= restartEscalateThreshold && !escalatedThisEpisode {
            escalatedThisEpisode = true
            notifier.oneShot(
                subject: "Home Assistant: Auto-Restart gescheitert",
                body: "Home Assistant ließ sich nach \(restartAttempt) Versuchen nicht stabil starten und wird weiter versucht.")
        }
        let work = DispatchWorkItem { [weak self] in self?.start() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
