import Foundation

/// Prepares the per-user Python virtualenv that Home Assistant runs in.
///
/// On first launch (or after the bundled CPython minor version changes) it
/// creates a virtualenv from the bundled interpreter and pip-installs
/// Home Assistant into `~/Library/Application Support/HomeAssistant/venv`. All
/// pip/venv output is streamed into the shared `LogStore` so the log window
/// shows live progress. This is what makes the app "one click": the user never
/// touches a terminal.
@MainActor
final class EnvironmentManager: ObservableObject {

    /// True while a venv/pip operation is running (install or update).
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    private let log: LogStore

    /// Packages that Home Assistant *core* components import at load time but do
    /// NOT declare as installable requirements, so they are never auto-installed
    /// in a fresh virtualenv (on HA OS they happen to be pre-baked).
    ///
    /// `aioesphomeapi`: the `usb` core component imports
    /// `serialx.platforms.serial_esphome`, which hard-imports `aioesphomeapi`.
    /// When it is missing, `usb` fails to import → `bluetooth` (depends on usb)
    /// fails → `default_config` and every BLE integration (Shelly, ESPHome,
    /// SwitchBot, Xiaomi/BTHome/Govee BLE, HomeKit Controller …) cascade-fail.
    /// `esphome` is the only integration that would install it, but it never
    /// gets set up because of that same cascade — a bootstrap deadlock. Seeding
    /// it here breaks the deadlock once and for all.
    ///
    /// `imageio-ffmpeg`: ships a static, native ffmpeg binary. Home Assistant
    /// needs ffmpeg to grab snapshots/streams from RTSP-only cameras; bundling
    /// it through the venv (then symlinked onto PATH, see `linkBundledFFmpeg`)
    /// keeps the "no terminal, no system install" promise — no `brew install`.
    private let bootstrapDependencies = ["aioesphomeapi", "imageio-ffmpeg"]

    init(log: LogStore) {
        self.log = log
    }

    enum EnvError: LocalizedError {
        case pythonMissing(String)
        case venvFailed(Int32)
        case installFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .pythonMissing(let path):
                return "Bundled Python not found at \(path)."
            case .venvFailed(let code):
                return "Creating the Python environment failed (exit \(code))."
            case .installFailed(let code):
                return "Installing Home Assistant failed (exit \(code)). "
                    + "If a dependency had to compile from source, install the Xcode "
                    + "Command Line Tools (run: xcode-select --install) and try again."
            }
        }
    }

    // MARK: - Public

    /// Ensure the virtualenv exists and Home Assistant is installed. Safe to
    /// call on every start — it is a fast no-op once everything is in place.
    /// `progress` receives short status strings for the menu-bar/status display.
    func ensureReady(progress: @MainActor (String) -> Void) async throws {
        lastError = nil
        guard FileManager.default.isExecutableFile(atPath: BundledRuntime.bundledPythonURL.path) else {
            throw EnvError.pythonMissing(BundledRuntime.bundledPythonURL.path)
        }
        try? FileManager.default.createDirectory(at: BundledRuntime.supportDirectory, withIntermediateDirectories: true)

        let venvPython = BundledRuntime.venvPythonURL
        // Recreate the venv if it is missing, or if the bundled Python minor
        // changed (HA pins one Python minor; a venv built on the old minor is
        // unusable — see ADR-0020). Updating across a minor needs a fresh venv.
        let minorChanged = BundledRuntime.venvPythonMinor != nil
            && BundledRuntime.venvPythonMinor != BundledRuntime.bundledPythonMinor
        let needNewVenv = !FileManager.default.isExecutableFile(atPath: venvPython.path) || minorChanged

        if needNewVenv {
            isWorking = true
            defer { isWorking = false }
            if minorChanged {
                log.appendSystem("Python version changed — recreating virtualenv")
            }
            progress("Erstelle Python-Umgebung…")
            try? FileManager.default.removeItem(at: BundledRuntime.venvRoot)
            log.appendSystem("Creating virtualenv at \(BundledRuntime.venvRoot.path)")
            let code = try await runStreaming(BundledRuntime.bundledPythonURL,
                                              ["-m", "venv", "--copies", BundledRuntime.venvRoot.path])
            guard code == 0 else { throw EnvError.venvFailed(code) }

            progress("Aktualisiere pip…")
            _ = try await runStreaming(venvPython, ["-m", "pip", "install", "--upgrade", "pip", "wheel"])
        }

        if !BundledRuntime.isHomeAssistantInstalled {
            isWorking = true
            defer { isWorking = false }
            progress("Installiere Home Assistant … (kann einige Minuten dauern)")
            log.appendSystem("Installing Home Assistant via pip — this can take a few minutes…")
            let code = try await runStreaming(venvPython, ["-m", "pip", "install", "homeassistant"])
            guard code == 0 else { throw EnvError.installFailed(code) }
            log.appendSystem("Home Assistant \(BundledRuntime.installedHAVersion ?? "?") installed")
        }

        // Seed bootstrap dependencies that HA core components import but never
        // install themselves (see `bootstrapDependencies`). Checked on every
        // start so existing/migrated environments self-heal.
        let missing = bootstrapDependencies.filter { !BundledRuntime.isPackageInstalled($0) }
        if !missing.isEmpty {
            isWorking = true
            defer { isWorking = false }
            progress("Installiere Zusatzpakete (\(missing.joined(separator: ", ")))…")
            log.appendSystem("Installing bootstrap dependencies: \(missing.joined(separator: ", "))")
            let code = try await runStreaming(venvPython, ["-m", "pip", "install"] + missing)
            guard code == 0 else { throw EnvError.installFailed(code) }
        }

        // Expose the bundled ffmpeg under a stable name on PATH (idempotent;
        // re-points after a version bump or venv rebuild).
        linkBundledFFmpeg()
    }

    /// Symlink the `imageio-ffmpeg` binary to `…/venv/bin/ffmpeg`. That dir is
    /// first on the launched Home Assistant process's PATH, so HA resolves
    /// `ffmpeg` automatically — no `ffmpeg:` config, no system install.
    private func linkBundledFFmpeg() {
        guard let exe = BundledRuntime.imageioFFmpegURL else { return }
        let link = BundledRuntime.ffmpegLinkURL
        let fm = FileManager.default
        // Already correct? leave it.
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path), dest == exe.path { return }
        try? fm.removeItem(at: link)
        do {
            try fm.createSymbolicLink(at: link, withDestinationURL: exe)
            log.appendSystem("Linked bundled ffmpeg → \(exe.lastPathComponent)")
        } catch {
            log.appendSystem("Could not link bundled ffmpeg: \(error.localizedDescription)")
        }
    }

    /// Upgrade Home Assistant to the latest version on PyPI. The caller is
    /// expected to stop the server first and restart it afterwards.
    @discardableResult
    func updateHomeAssistant() async -> Bool {
        lastError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            // Make sure the venv is valid (and on the right Python minor) first.
            try await ensureReady(progress: { _ in })
            log.appendSystem("Upgrading Home Assistant via pip…")
            let code = try await runStreaming(BundledRuntime.venvPythonURL,
                                              ["-m", "pip", "install", "--upgrade", "homeassistant"])
            guard code == 0 else { throw EnvError.installFailed(code) }
            log.appendSystem("Home Assistant is now \(BundledRuntime.installedHAVersion ?? "?")")
            return true
        } catch {
            lastError = error.localizedDescription
            log.appendSystem("Update failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Process streaming

    /// Run a process, streaming combined stdout/stderr into the log, and return
    /// its exit code. Mirrors the pipe/continuation pattern used elsewhere.
    private func runStreaming(_ executable: URL, _ args: [String]) async throws -> Int32 {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.log.append(text) }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            proc.terminationHandler = { [weak self] p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.availableData
                if !rest.isEmpty, let text = String(data: rest, encoding: .utf8) {
                    Task { @MainActor [weak self] in self?.log.append(text) }
                }
                cont.resume(returning: p.terminationStatus)
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }
}
