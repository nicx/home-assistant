# Home Assistant (macOS Menüleisten-App)

Eine native macOS-**Menüleisten-App**, die **Home Assistant Core** direkt auf dem
Mac betreibt — **ohne Docker, ohne VM**. Home Assistant läuft in einer eigenen
Python-virtualenv; die App startet, überwacht und sichert sie.

Stack: Swift · SwiftUI `MenuBarExtra` · gebündeltes CPython 3.14
([python-build-standalone](https://github.com/astral-sh/python-build-standalone))
· `launchd`/`SMAppService` · `ditto`-Backups.

- **Monochromes Menüleisten-Symbol** (SF-Symbol-Template, passt sich Hell/Dunkel an und zeigt den Status).
- **Starten / Stoppen / Neu starten** mit Auto-Restart bei Absturz (Keepalive, exponentielles Backoff).
- **Dashboard öffnen** (`http://localhost:8123`) und ein Live-**Protokollfenster** (zeigt auch den Erstinstallations-Fortschritt).
- **Sicherungen**: zeitgestempelte `.zip`-Snapshots des Konfigurationsordners, einstellbarer Zielordner, Tagesplan, Aufbewahrung (letzte *N*), Wiederherstellung und optional „Server während der Sicherung stoppen".
- **Home Assistant aktualisieren** per Knopfdruck (pip-Upgrade, Versionsvergleich gegen PyPI).
- **E-Mail bei verfügbarem Update**: prüft beim Start und alle 6 Stunden PyPI und schickt — sobald eine neuere Version vorliegt — eine Mail über den lokalen MailRelay (`127.0.0.1:2525`, wie evcc). Pro Version höchstens eine Mail.
- **E-Mail bei Störungen** (optional, eigener Toggle): bei **Absturz** des HA-Prozesses, wenn der **Auto-Restart** dauerhaft scheitert (nach 5 Versuchen) und bei **fehlgeschlagener Sicherung** — jeweils entprellt (eine Mail pro Störungs-Episode) samt „wieder aktiv"/„wieder erfolgreich"-Mail. Ein **manueller Stopp löst nie** eine Mail aus.
- **Beim Anmelden starten** über `SMAppService`.

## Architektur in Kürze

Nur die **CPython-Laufzeit** wird in die `.app` gebündelt (klein). Home Assistant
selbst wird beim **ersten Start** per `pip install homeassistant` in eine
virtualenv unter `~/Library/HomeAssistant/venv` installiert — der Fortschritt
ist live im Protokollfenster sichtbar. Vorteile: kleine App, HA-Updates per pip
(ohne Neubau), und nur die Python-Laufzeit muss signiert werden. Beim Wechsel
der Python-Minor-Version (HA hebt sie regelmäßig an) legt die App die virtualenv
automatisch neu an.

> **Wichtig — keine Leerzeichen im Pfad:** Die Daten liegen bewusst unter
> `~/Library/HomeAssistant` statt `Application Support`. Home Assistant
> installiert Integrations-Abhängigkeiten zur Laufzeit mit `uv` nach; ein
> Interpreter-/venv-Pfad mit Leerzeichen (`Application Support`) wird dabei
> falsch geparst und die Kern-Initialisierung schlägt fehl.

## Voraussetzungen

- macOS 14 (Sonoma) oder neuer, Apple Silicon (arm64).
- Xcode 16+ / Swift 6 zum **Bauen**.
- Netzwerkzugang beim ersten Start (für den pip-Download von Home Assistant).
- **Xcode Command Line Tools** (`xcode-select --install`): In der Regel laden alle
  HA-Abhängigkeiten als fertige `arm64`-Wheels (kein Kompilieren nötig). Falls
  eine Abhängigkeit doch aus Quelltext gebaut werden muss, wird ein C-Compiler
  benötigt — Fehler erscheinen dann im Protokollfenster.

## Bauen & Starten

```bash
# 1. CPython-Laufzeit nach ./Runtime laden
./Scripts/bundle-runtime.sh

# 2. App bauen, .app zusammenbauen und (ad-hoc) signieren
./Scripts/make-app.sh

# 3. Starten — das Haus-Symbol erscheint in der Menüleiste
open dist/HomeAssistant.app
```

Beim **ersten Start** zeigt das Menü „Installiere Home Assistant …"; nach
wenigen Minuten läuft der Server und „Dashboard öffnen" führt zum HA-Onboarding
auf `http://localhost:8123`.

Für signierte Verteilung `CODESIGN_IDENTITY="Developer ID Application: …"` vor
Schritt 2 setzen und die `.app` anschließend notarisieren.

> **Hinweis zur Signierung:** Jede Mach-O-Datei der gebündelten CPython-Laufzeit
> wird einzeln mit den JIT-/Library-Validation-Entitlements signiert (siehe
> `make-app.sh`). Die per pip in die virtualenv installierten HA-Bibliotheken
> liegen **außerhalb** der `.app` und werden dank `disable-library-validation`
> zur Laufzeit geladen — es müssen keine hunderten Wheel-`.so` mitsigniert werden.

### Entwicklung ohne Bündeln

```bash
./Scripts/bundle-runtime.sh   # ./Runtime einmalig vorbereiten
swift run                     # nutzt ./Runtime als Dev-Fallback
```

Pfad bei Bedarf über `HASS_RUNTIME_DIR` überschreiben.

## Standard-Speicherorte

| Was | Pfad |
|---|---|
| Python-virtualenv (HA installiert) | `~/Library/HomeAssistant/venv` |
| HA-Konfiguration (`configuration.yaml`, DB, …) | `~/Library/HomeAssistant/config` |
| Sicherungen | `~/Library/HomeAssistant/backups` (einstellbar) |
| App-Protokoll | `~/Library/Logs/HomeAssistant/home-assistant.log` |

## Projektstruktur

```
Sources/HomeAssistant/
  HomeAssistantMenuBarApp.swift   App-Einstieg, AppDelegate, Scenes, Menüleisten-Symbol
  AppSettings.swift               UserDefaults-gestützte Konfiguration
  EnvironmentManager.swift        Erststart: virtualenv anlegen + pip install/upgrade
  ServerController.swift          HA-Prozess: Lebenszyklus + Keepalive + Log-Erfassung
  BundledRuntime.swift            Bundled Python + venv-Pfade + Startargumente
  BackupManager.swift             ditto-Snapshots, Aufbewahrung, Wiederherstellung, Tagesplan
  UpdateMonitor.swift             Periodischer PyPI-Check + Mail-Benachrichtigung (entprellt)
  Mailer.swift                    Mailversand über lokalen MailRelay (Python smtplib)
  LoginItemManager.swift          SMAppService „Beim Anmelden starten"
  LogStore.swift                  In-Memory-Ringpuffer + Protokolldatei
  Views/                          MenuContentView, SettingsView, LogView
Resources/                        Info.plist, HomeAssistant.entitlements
Scripts/                          bundle-runtime.sh, make-app.sh
```

`Runtime/` (gebündeltes CPython) und `dist/` (gebaute App) werden von den
Skripten erzeugt und sind git-ignoriert.

## Was läuft — und was nicht

**Es läuft** Home Assistant **Core**: die Engine, das Web-Dashboard, alle
Integrationen, die in-process arbeiten (z. B. ZHA, viele Cloud-/LAN-Integrationen).
USB-Zigbee/Z-Wave-Sticks sind nativ ansprechbar (kein VM-Passthrough nötig), der
Gerätepfad (`/dev/cu.*`) muss in HA angegeben werden.

**Es fehlt — bauartbedingt** (Core ohne Supervisor):

- **Kein Add-on-Store / Supervisor.** Add-ons wie **Matter Server**, **Z-Wave JS**,
  **Zigbee2MQTT** oder ein **MQTT-Broker** müssen als eigene Dienste laufen.
  (Den Matter Server betreibst du bereits separat — er lässt sich direkt
  anbinden.)
- Keine verwalteten OS-/Supervisor-Updates und kein Add-on-Backup-System (diese
  App sichert stattdessen den Konfigurationsordner).
- Bluetooth funktioniert über macOS CoreBluetooth, ist aber eingeschränkter als
  unter Linux/BlueZ und verlangt die Bluetooth-Berechtigung für die App.

Offiziell ist die **Core-Installation per venv von Home Assistant abgekündigt**
und macOS war dafür nie eine unterstützte Plattform — technisch funktioniert es
(getestet mit HA **2026.6.2** auf Python **3.14.6**), Support gibt es dafür aber
nur aus der Community.

## Lizenz

MIT © 2026 Timo Klinger.

Diese App bündelt zur Bauzeit die [CPython](https://www.python.org)-Laufzeit
([python-build-standalone](https://github.com/astral-sh/python-build-standalone))
und installiert zur Laufzeit [Home Assistant](https://www.home-assistant.io)
(Apache-2.0); diese Komponenten unterliegen ihren jeweiligen Lizenzen.
