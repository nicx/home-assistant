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
