import Foundation

/// Resolves the bundled CPython runtime and the per-user virtualenv that
/// Home Assistant is installed into, and builds the argument list for launching
/// `python -m homeassistant`.
///
/// Layout produced by `Scripts/bundle-runtime.sh` (embedded in the `.app`):
/// ```
/// Runtime/python/bin/python3        # relocatable CPython 3.14 (arm64)
/// Runtime/python/lib/python3.14/    # standard library
/// ```
/// In a packaged `.app` this lives under `Contents/Resources/Runtime`; during
/// `swift run` we fall back to `<packageRoot>/Runtime`. Overridable with the
/// `HASS_RUNTIME_DIR` environment variable.
///
/// Home Assistant itself is NOT bundled — it is pip-installed at first launch
/// into a virtualenv under Application Support (see `EnvironmentManager`).
enum BundledRuntime {

    enum RuntimeError: LocalizedError {
        case pythonMissing(String)
        case homeAssistantMissing

        var errorDescription: String? {
            switch self {
            case .pythonMissing(let path):
                return "Bundled Python runtime not found at \(path). Run Scripts/bundle-runtime.sh."
            case .homeAssistantMissing:
                return "Home Assistant is not installed in the virtualenv yet."
            }
        }
    }

    // MARK: - Bundled interpreter (read-only, inside the .app)

    /// Root directory containing `python/`.
    static var runtimeRoot: URL {
        if let override = ProcessInfo.processInfo.environment["HASS_RUNTIME_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("Runtime", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("python").path) {
                return bundled
            }
        }
        // Dev fallback: <packageRoot>/Runtime, derived from this file's location.
        // BundledRuntime.swift -> HomeAssistant -> Sources -> <packageRoot>
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot.appendingPathComponent("Runtime", isDirectory: true)
    }

    /// The relocatable interpreter shipped inside the bundle.
    static var bundledPythonURL: URL {
        runtimeRoot.appendingPathComponent("python/bin/python3")
    }

    // MARK: - Per-user virtualenv (writable, outside the .app)

    /// `~/Library/HomeAssistant`. Deliberately NOT under `Application Support`:
    /// the path must be free of spaces because Home Assistant installs
    /// integration dependencies at runtime via `uv`, which mis-parses a venv
    /// interpreter path that contains a space.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("HomeAssistant", isDirectory: true)
    }

    /// The virtualenv Home Assistant is installed into.
    static var venvRoot: URL { supportDirectory.appendingPathComponent("venv", isDirectory: true) }

    /// The interpreter inside the virtualenv (used to launch Home Assistant).
    static var venvPythonURL: URL { venvRoot.appendingPathComponent("bin/python") }

    // MARK: - Version helpers

    /// The `python3.X` directory name under a CPython tree's `lib/`, e.g.
    /// "python3.14". Used to detect a Python-minor mismatch between the bundled
    /// runtime and an existing virtualenv (which requires recreating the venv).
    static func pythonMinorName(under root: URL) -> String? {
        let lib = root.appendingPathComponent("lib")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []
        return entries.first { $0.hasPrefix("python3.") }
    }

    static var bundledPythonMinor: String? {
        pythonMinorName(under: runtimeRoot.appendingPathComponent("python"))
    }

    static var venvPythonMinor: String? {
        pythonMinorName(under: venvRoot)
    }

    /// `…/venv/lib/python3.X/site-packages`, if the venv exists.
    static var venvSitePackagesURL: URL? {
        guard let minor = venvPythonMinor else { return nil }
        return venvRoot.appendingPathComponent("lib/\(minor)/site-packages", isDirectory: true)
    }

    /// Installed Home Assistant version, read from the `homeassistant-*.dist-info`
    /// directory name in site-packages (no interpreter launch needed).
    static var installedHAVersion: String? {
        guard let site = venvSitePackagesURL,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: site.path) else { return nil }
        guard let info = entries.first(where: {
            $0.hasPrefix("homeassistant-") && $0.hasSuffix(".dist-info")
        }) else { return nil }
        let version = info.dropFirst("homeassistant-".count).dropLast(".dist-info".count)
        return version.isEmpty ? nil : String(version)
    }

    static var isHomeAssistantInstalled: Bool { installedHAVersion != nil }

    /// Whether a pip package is installed in the venv, detected via its
    /// `<name>-<version>.dist-info` directory (no interpreter launch).
    static func isPackageInstalled(_ name: String) -> Bool {
        guard let site = venvSitePackagesURL,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: site.path) else { return false }
        let target = name.lowercased().replacingOccurrences(of: "-", with: "_")
        return entries.contains { entry in
            let lower = entry.lowercased()
            guard lower.hasSuffix(".dist-info") else { return false }
            let stem = lower.dropLast(".dist-info".count)         // e.g. "aioesphomeapi-45.3.1"
            let project = stem.split(separator: "-").first.map(String.init) ?? ""
            return project == target
        }
    }

    // MARK: - Launch

    /// True once both the bundled interpreter and a Home Assistant virtualenv
    /// are present. (The virtualenv is created on first launch.)
    static func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: bundledPythonURL.path) else {
            throw RuntimeError.pythonMissing(bundledPythonURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: venvPythonURL.path), isHomeAssistantInstalled else {
            throw RuntimeError.homeAssistantMissing
        }
    }

    /// Arguments passed to `venvPythonURL` to launch Home Assistant. The
    /// interpreter itself is set as the process `executableURL`, so this is just
    /// everything after it.
    @MainActor
    static func arguments(for settings: AppSettings) -> [String] {
        var args = ["-m", "homeassistant", "--config", settings.configPath, "--log-no-color"]
        if settings.verbose { args.append("-v") }
        return args
    }
}
