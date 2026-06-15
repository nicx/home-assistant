# Handoff / Projektstatus

Kurzkontext für eine neue Arbeits-Session (auch auf einem anderen Rechner). Das
eigentliche „Wie/Warum" steckt in den Commit-Messages und der
[README](README.md); dieses Dokument bündelt Stand und offene Punkte.

## Was das ist

Native macOS-**Menüleisten-App** (Swift/SwiftUI), die **Home Assistant Core**
auf Apple Silicon betreibt — ohne Docker, ohne VM. Eine relocatable CPython-3.14-
Laufzeit ist gebündelt; Home Assistant wird beim ersten Start per `pip` in eine
venv unter `~/Library/HomeAssistant/venv` installiert. Details: README.

## Aktueller Stand (Commits)

- `Initial commit` — App-Grundgerüst, Build-Skripte, Menüleiste, Start/Stop/
  Restart, Backups, Login-Item, Update-Button, README.
- `fix: seed aioesphomeapi …` — bricht einen Bootstrap-Deadlock: HAs Kern-
  komponente `usb` importiert über `serialx` hart `aioesphomeapi`, das sonst
  nie installiert wird → `bluetooth`/BLE-Integrationen scheitern. Wird jetzt in
  `EnvironmentManager.bootstrapDependencies` mitinstalliert (self-healing).
- `fix: handle HA restart (exit 100) and clean shutdown (exit 0) intent` —
  Exit 100 (HA-Neustart) = sauberer Neustart; Exit 0 (HA-Stop) = bleibt aus.
- `fix: treat HA restart teardown abort (SIGABRT) as a clean restart` — beim
  GUI-Neustart abortet HA während des Interpreter-Teardowns (macOS C-Extensions)
  → Tod per **SIGABRT (Signal 6)**, Exit-Code 100 maskiert. `ServerController`
  wertet jetzt `terminationReason` aus: SIGABRT bei *laufender* Instanz =
  gewollter Neustart (keine Crash-Mail/Backoff); echte Abstürze heißen korrekt
  „killed by <SIGNAL>".

## Build & Start (neuer Rechner)

Voraussetzungen: Apple Silicon, Xcode/Command Line Tools, Homebrew.

```bash
git clone https://github.com/nicx/home-assistant
cd home-assistant
./Scripts/bundle-runtime.sh   # lädt CPython 3.14 → ./Runtime
./Scripts/make-app.sh         # baut & signiert ./dist/HomeAssistant.app
open dist/HomeAssistant.app
```

`Runtime/`, `dist/`, `.build/` sind gitignored und werden von den Skripten neu
erzeugt. Die Laufzeitdaten (venv, Config, Backups) liegen unter
`~/Library/HomeAssistant/` und sind bewusst **nicht** im Repo.

## Verifikation (lokal, ohne HA-API-Token)

- App starten, auf `http://localhost:8123` warten.
- Neustart-Pfad: `kill -ABRT <hass-pid>` nach dem Hochlaufen → App-Log zeigt
  „shut down via SIGABRT (teardown abort) — restarting", **keine** Crash-Mail.
- Crash-Pfad: `kill -SEGV <hass-pid>` → „Server killed by SIGSEGV" + Keepalive.
- App-Log: `~/Library/Logs/HomeAssistant/home-assistant.log`;
  HA-eigenes Log: `~/Library/HomeAssistant/config/home-assistant.log`.

## Offene Punkte / mögliche nächste Schritte

- **E-Mail-Empfänger nicht gesetzt** → aktuell werden gar keine Mails versendet.
  In *Einstellungen → Allgemein → E-Mail-Benachrichtigung* Empfänger eintragen
  und Toggles („bei Update" / „bei Störungen") setzen. Versand läuft über einen
  lokalen MailRelay (Standard `127.0.0.1:2525`, wie beim evcc-Projekt).
- **Optional `brew install ffmpeg`** (Kamera/Medien) und turbojpeg
  (Kamera-Snapshots) — sonst nur Warnungen im HA-Log, nicht kritisch.
- **Kein App-Icon**: `Resources/AppIcon.icns` fehlt; `make-app.sh` bindet es
  automatisch ein, sobald vorhanden.

## Bewusste Einschränkungen

- Ein **„Stop" aus der HA-GUI**, das ebenfalls per SIGABRT-Teardown endet, ist
  nicht von „Restart" unterscheidbar → wird neu gestartet. Der App-eigene
  „Stoppen"-Knopf (SIGTERM) ist davon nicht betroffen.
- Core ohne Supervisor → **kein Add-on-Store**; Matter-Server/Z-Wave-JS/
  Zigbee2MQTT/MQTT-Broker laufen als eigene Dienste. Core-venv-Installation ist
  von HA offiziell abgekündigt; macOS war nie offiziell unterstützt (funktioniert,
  getestet mit HA 2026.6.x auf Python 3.14).

## Lektionen (für die nächste Session)

- **Nicht in die Live-UserDefaults der App schreiben, um zu testen**
  (`com.homeassistant.menubar`). Zum Mail-Test einen lokalen Wegwerf-SMTP-Sink
  verwenden und das App-Log beobachten, statt echte Empfänger/Ports zu setzen
  (ein Test hatte versehentlich einen konfigurierten Empfänger überschrieben).
- Diagnosen am **echten Traceback/Log** verifizieren, nicht an Vermutungen — der
  `aioesphomeapi`-Bug und der SIGABRT-vs-Exit-Code-Punkt waren erst dort eindeutig.
