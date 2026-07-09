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
    /// Home Assistant exits with this code (`RESTART_EXIT_CODE` in
    /// homeassistant/const.py) when it wants to be restarted: the UI "Restart"
    /// button, the `homeassistant.restart` service, restart-requiring config
    /// reloads, integrations like Spook, etc. It is an intentional restart, not
    /// a crash.
    private static let restartExitCode: Int32 = 100
    /// After this many consecutive failed auto-restarts, escalate with a
    /// distinct "auto-restart still failing" notification (once per episode).
    private let restartEscalateThreshold = 5
    private var escalatedThisEpisode = false
    /// True while the late-network watcher (armLateNetworkRestart) is active, to
    /// prevent a second watcher from being armed concurrently.
    private var lateNetworkWatchRunning = false
    /// Latched once we have performed the single automatic "network came up
    /// late" restart, so it never fires more than once per app session.
    private var lateNetworkRestartDone = false

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
        // A freshly requested start clears any prior intentional-stop latch; we
        // re-check it after the (possibly long) network wait below.
        intentionalStop = false
        do {
            status = .installing("Prüfe Laufzeitumgebung…")
            let networkConfirmed = await waitForNetwork()
            if intentionalStop {
                status = .stopped
                log.appendSystem("Start abgebrochen (während Netzwerk-Wartezeit gestoppt)")
                return
            }
            try await env.ensureReady { [weak self] message in
                guard let self, case .installing = self.status else { return }
                self.status = .installing(message)
            }
            detectedVersion = BundledRuntime.installedHAVersion
            try FileManager.default.createDirectory(at: settings.configURL, withIntermediateDirectories: true)
            try BundledRuntime.validate()
            try launch(arguments: BundledRuntime.arguments(for: settings))
            // Started without confirmed network (the wait timed out): keep
            // watching and restart once when the network finally comes up, so
            // integrations that exhausted their setup-retries recover cleanly.
            if !networkConfirmed { armLateNetworkRestart() }
        } catch {
            status = .crashed(error.localizedDescription)
            lastError = error.localizedDescription
            log.appendSystem("Start failed: \(error.localizedDescription)")
        }
    }

    /// Cold-boot guard: at login the app can launch before the Mac has network,
    /// which makes cloud integrations (easee, octopus, …) exhaust their setup
    /// retries and stay dead. Wait until the network is genuinely usable
    /// (interface up + DNS/TCP probe), polling every 2s, bounded by a timeout so
    /// an offline Mac still starts — Home Assistant's own retry then takes over.
    ///
    /// Returns `true` if the network was confirmed usable, `false` if we gave up
    /// (timeout) or were stopped mid-wait. A `false` after a real timeout arms
    /// `armLateNetworkRestart()`. The cap is generous (a Thunderbolt/USB Ethernet
    /// adapter can take ~2 min to come up after a cold boot — observed on this
    /// Mac mini, where the old 90s cap fired early and HA started network-less).
    private func waitForNetwork() async -> Bool {
        let timeout: TimeInterval = 300
        if await NetworkReadiness.isReady() { return true } // already online: no delay
        log.appendSystem("Warte auf Netzwerk, bevor Home Assistant startet…")
        if case .installing = status { status = .installing("Warte auf Netzwerk…") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if intentionalStop { return false } // user stopped during the wait
            if await NetworkReadiness.isReady() {
                log.appendSystem("Netzwerk erreichbar — starte Home Assistant")
                return true
            }
        }
        log.appendSystem("Netzwerk nach \(Int(timeout))s nicht bestätigt — starte Home Assistant trotzdem")
        return false
    }

    /// Backstop for a cold boot where the network comes up *later* than the
    /// `waitForNetwork()` cap (e.g. a very slow adapter or a delayed WAN): HA is
    /// already running, but cloud/LAN integrations that ran out of setup-retries
    /// in the network-less window stay dead. Keep probing in the background and,
    /// the moment the network is genuinely usable, restart Home Assistant
    /// **exactly once** so those integrations initialise cleanly. Bounded to a
    /// single restart and a 15-minute window so a truly offline Mac never
    /// restart-loops (HA's own retry handles it from there).
    private func armLateNetworkRestart() {
        guard !lateNetworkWatchRunning, !lateNetworkRestartDone else { return }
        lateNetworkWatchRunning = true
        log.appendSystem("Ohne bestätigtes Netzwerk gestartet — überwache Netz für einen einmaligen Neustart")
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(15 * 60)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                // Stop watching if HA is no longer up or the user intervened.
                guard self.process != nil, !self.intentionalStop,
                      self.status == .running || self.status == .starting else {
                    self.lateNetworkWatchRunning = false
                    return
                }
                if await NetworkReadiness.isReady() {
                    guard self.process != nil, !self.intentionalStop else {
                        self.lateNetworkWatchRunning = false
                        return
                    }
                    self.lateNetworkRestartDone = true
                    self.lateNetworkWatchRunning = false
                    self.log.appendSystem("Netzwerk jetzt verfügbar — einmaliger Neustart, damit Integrationen sauber laden")
                    self.restart()
                    return
                }
            }
            self?.lateNetworkWatchRunning = false
            self?.log.appendSystem("Netz-Überwachung beendet (15 min ohne bestätigtes Netzwerk) — kein Neustart")
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
            let reason = finished.terminationReason // .exited | .uncaughtSignal
            DispatchQueue.main.async {
                self?.handleTermination(code: code, reason: reason)
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

    private func handleTermination(code: Int32, reason: Process.TerminationReason) {
        // Capture before we reset state below: a GUI restart hits a healthy,
        // running instance, whereas a startup crash-loop never reached running.
        let wasRunning = (status == .running)

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

        let bySignal = (reason == .uncaughtSignal)

        // Intentional restart requested by Home Assistant. Two manifestations:
        //  - a clean exit with RESTART_EXIT_CODE (100), or
        //  - SIGABRT (signal 6) while a healthy instance shuts down: HA returns
        //    100, but a C-extension aborts during interpreter teardown on macOS
        //    (bleak/CoreBluetooth, grpc, …), which masks the exit code. Only
        //    trust SIGABRT when HA had reached `running`, so a startup crash
        //    loop is never mistaken for a restart.
        if (!bySignal && code == Self.restartExitCode)
            || (bySignal && code == SIGABRT && wasRunning) {
            let how = bySignal
                ? "shut down via \(Self.signalName(code)) (teardown abort)"
                : "requested a restart (exit code \(code))"
            log.appendSystem("Home Assistant \(how) — restarting")
            cleanRestart()
            return
        }

        // Clean shutdown initiated by Home Assistant itself (homeassistant.stop
        // service / "Stop" in the UI). Stay stopped, no auto-restart.
        if !bySignal && code == 0 {
            log.appendSystem("Home Assistant shut down cleanly (exit code 0) — staying stopped")
            status = .stopped
            notifier.clear(HAConditions.serverDown)
            restartAttempt = 0
            escalatedThisEpisode = false
            return
        }

        // Anything else is a genuine crash.
        let reasonText = bySignal
            ? "killed by \(Self.signalName(code))"
            : "exited with code \(code)"
        status = .crashed(reasonText)
        lastError = reasonText
        log.appendSystem("Server \(reasonText)")
        // Debounced: one "abgestürzt" mail per down-episode, regardless of how
        // many auto-restart attempts follow.
        notifier.report(HAConditions.serverDown, healthy: false, detail: reasonText)

        guard settings.autoRestart else { return }
        scheduleRestart()
    }

    /// Relaunch after an intentional Home Assistant restart: no crash status,
    /// no fault mail, no exponential backoff.
    private func cleanRestart() {
        notifier.clear(HAConditions.serverDown)
        restartAttempt = 0
        escalatedThisEpisode = false
        start()
    }

    /// Human-readable name for a termination signal (for log/mail text).
    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGKILL: return "SIGKILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGTERM: return "SIGTERM"
        case SIGINT:  return "SIGINT"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGHUP:  return "SIGHUP"
        default:      return "signal \(sig)"
        }
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
