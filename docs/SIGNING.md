# Code-Signing & Notarisierung

Der Release-Workflow (`.github/workflows/release.yml`) signiert die App
automatisch mit deiner **Developer ID** und **notarisiert** sie, sobald die
folgenden GitHub-Secrets gesetzt sind. Ohne diese Secrets fällt er auf eine
**Ad-hoc-Signatur** zurück (läuft lokal nach `xattr -dr com.apple.quarantine`).

## Voraussetzungen
- Kostenpflichtiger **Apple Developer Account** (99 $/Jahr).
- Ein **„Developer ID Application"**-Zertifikat (in Xcode oder über das Apple
  Developer Portal erstellt).
- Ein **app-spezifisches Passwort** für die Notarisierung
  (appleid.apple.com → Anmeldung & Sicherheit → App-spezifische Passwörter).

## Benötigte GitHub-Secrets
Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Inhalt |
|--------|--------|
| `DEVELOPER_ID_P12_BASE64` | Dein „Developer ID Application"-Zertifikat als **.p12**, base64-kodiert |
| `DEVELOPER_ID_P12_PASSWORD` | Das Passwort, das du beim .p12-Export gesetzt hast |
| `DEVELOPER_ID_NAME` | Exakter Identitätsname, z. B. `Developer ID Application: Dein Name (TEAMID)` |
| `NOTARY_APPLE_ID` | Deine Apple-ID-E-Mail |
| `NOTARY_TEAM_ID` | Deine 10-stellige Team-ID |
| `NOTARY_PASSWORD` | Das app-spezifische Passwort |

### Zertifikat exportieren & kodieren
1. **Schlüsselbundverwaltung** → dein „Developer ID Application"-Zertifikat
   (mit privatem Schlüssel) auswählen → **Exportieren** → `.p12` (Passwort setzen).
2. In base64 umwandeln und in die Zwischenablage legen:
   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```
   Den Inhalt als `DEVELOPER_ID_P12_BASE64` einfügen.

### Identitätsname & Team-ID herausfinden
```bash
security find-identity -v -p codesigning   # zeigt "Developer ID Application: …"
```
Die Team-ID steht in Klammern im Identitätsnamen und im Apple Developer Portal.

## Ablauf im Workflow (wenn Secrets gesetzt)
1. Zertifikat in einen temporären Keychain importieren.
2. `codesign --options runtime --timestamp` mit der Developer ID (Hardened
   Runtime ist im Projekt aktiv).
3. `notarytool submit … --wait` (lädt das ZIP hoch, wartet auf Apple).
4. `stapler staple` heftet das Notarisierungs-Ticket an die App und es wird neu
   gezippt → öffnet sich auf jedem Mac ohne Gatekeeper-Warnung.

## Lokal signieren (ohne Pipeline)
Siehe Antwort im Chat bzw.:
```bash
# Ad-hoc (nur Eigengebrauch)
codesign --force --deep --sign - MediaIdentifier.app

# Developer ID + Notarisierung
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: Dein Name (TEAMID)" MediaIdentifier.app
xcrun notarytool submit MediaIdentifier.app.zip \
  --apple-id "deine@apple.id" --team-id TEAMID --password "APP-PW" --wait
xcrun stapler staple MediaIdentifier.app
```

## Sicherheit
Secrets sind in GitHub Actions verschlüsselt und werden im Log maskiert. Der
temporäre Keychain wird am Ende des Laufs gelöscht. Lege das `.p12` **niemals**
unverschlüsselt ins Repository.
