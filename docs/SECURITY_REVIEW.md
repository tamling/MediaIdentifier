# MediaIdentifier — SAST Security Review

> Statische Sicherheitsanalyse des Swift-Codes (Core + App). Schwerpunkt auf den
> neuen Angriffsflächen: Status-Webserver (eingehend), ffprobe/ffmpeg-Subprozesse,
> Jellyfin/TMDb-Netzwerk-Clients, Dateisystem-Operationen. Registry-basierte
> Tools (Semgrep) sind im gesperrten Egress nicht nutzbar und unterstützen Swift
> nur experimentell — daher manueller, code-gestützter Review.
> Stand: 2026-06-21.

## Gesamtbewertung: **gut**
Solide Grundlagen: Secrets im Keychain (nie in UserDefaults/Logs/URLs), Subprozesse
ohne Shell (Argument-Arrays → keine Command-Injection), wirksamer Pfad-Traversal-Schutz,
read-only Webserver ohne Befehlsannahme, keine gefährlichen Force-Unwraps in
sicherheitsrelevanten Pfaden, keine hartkodierten Zugangsdaten.

## Findings & Status

| ID | Schweregrad | Bereich | Befund | Status |
|----|------------|---------|--------|--------|
| 1 | Mittel | Status-Webserver | Band an alle Interfaces (LAN) ohne Auth | **behoben (Option)** |
| 2 | Mittel | Status-Webserver | `Access-Control-Allow-Origin: *` | **behoben (entfernt)** |
| 3 | Niedrig | Status-Webserver | Request-Puffer 8 KB, stilles Verwerfen | akzeptiert (nur 404) |
| 4 | Niedrig | Info-Disclosure | Pfade in Status-Feldern | **mitigiert** (nur Dateiname, keine Pfade/Tokens) |
| 5 | Niedrig | Konvertierung | `targetHeight`/`quality`/Bitrate ohne Bounds | **behoben (geklemmt)** |
| 6 | Info | ffmpeg-Pfad | Ausführbarkeit vor Start | bereits geprüft (`isAvailable`) |
| 7 | Info | Jellyfin | `http://` für Remote-Hosts | **behoben (ATS: nur lokal http)** |
| 8 | — | Subprozesse | Command-Injection | sicher (Argument-Arrays) |
| 9 | — | Secrets | Keychain, ephemere Session | sicher |
| 10 | — | Pfad-Traversal | `sanitizeRelativePath` entfernt `..`/Slash | sicher |

## Umgesetzte Korrekturen

1. **Webserver-Bindung wählbar (Finding 1).** Neue Option „Nur lokal erreichbar
   (127.0.0.1)". Aktiv gebunden an Loopback statt an alle Interfaces, wenn
   gesetzt. Standard bleibt LAN, weil Uptime Kuma oft auf einem anderen Host
   (NAS) läuft — der Endpunkt liefert ausschließlich Status, keine Geheimnisse.
2. **CORS-Wildcard entfernt (Finding 2).** Kein `Access-Control-Allow-Origin: *`
   mehr; zusätzlich `X-Content-Type-Options: nosniff`. Kuma fragt serverseitig
   ab, das Dashboard ist same-origin — Wildcard war unnötig und riskant.
3. **Keine sensiblen Daten im Web (Finding 4).** Es werden nur Dateinamen
   (`lastPathComponent`), Zähler und Status ausgegeben; alle dynamischen Werte
   sind HTML-escaped; Tokens/vollständige Pfade erscheinen nie.
4. **Eingabe-Begrenzung Konvertierung (Finding 5).** `targetHeight` auf 120–8192
   geklemmt (sonst ignoriert), `quality` auf 0–51, Audio-Bitrate auf 8–1024.
5. **ATS / lokales HTTP (Finding 7).** `NSAllowsLocalNetworking` in der
   Info.plist erlaubt Klartext-HTTP nur zu lokalen/LAN-Hosts (für Jellyfin);
   öffentliche Endpunkte (TMDb) bleiben HTTPS-pflichtig. Remote-`http://` wird
   damit von ATS blockiert (fail-closed) — Klartext-Zugangsdaten ins Internet
   sind nicht möglich.

## Bestätigt sicher (keine Änderung nötig)
- **Command-Injection:** ffprobe/ffmpeg/gunzip werden mit absoluten Pfaden und
  Argument-Arrays (kein `sh -c`) aufgerufen; Datei-Pfade kommen aus `URL`.
- **Secrets:** TMDb- und Jellyfin-Schlüssel liegen im Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); v3-Key nur über ephemere
  `URLSession`; Jellyfin-Key nur im Header, nie in der URL.
- **Pfad-Traversal:** `JellyfinNamer.sanitizeRelativePath` zerlegt nach `/` und
  entfernt `.`/`..` sowie unzulässige Zeichen → Ausbruch aus dem Zielordner nicht
  möglich.
- **Löschen:** Konflikt-„Ersetzen" verschiebt in den Papierkorb (reversibel),
  kein hartes Löschen auf macOS.
- **Force-Unwrap/Pointer:** nur ein `try!` für eine kompilierte Konstanten-Regex;
  keine unsicheren Pointer.

## Offene, akzeptierte Punkte
- **Finding 3 (8-KB-Request):** Übergroße/fehlerhafte Requests führen nur zu einer
  404-Antwort; keine Auswirkung über die read-only-Statusausgabe hinaus.
- **TOCTOU bei Datei-Existenzprüfung:** durch transaktionales `moveItem` + Journal
  + Fehlerbehandlung abgedeckt; rein lokale, nutzerinitiierte Operation.
