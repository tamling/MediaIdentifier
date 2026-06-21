# MediaIdentifier — Usability- & Klick-Test, FR-Heatmap und GUI-Überarbeitungsvorschlag

> Analytischer Review auf Basis des aktuellen Codes (alle Views + AppState).
> Stand: 2026-06-21. Kein Live-Test auf Gerät (Build läuft über CI), daher
> Klickpfade aus dem Interaktionsmodell abgeleitet.

---

## 1. Usability- / Klick-Test

### Methodik
Für die vier Kern-Aufgaben wurde der minimale Klickpfad (Maus/Tastatur) aus dem
tatsächlichen View-/State-Code gezählt. „Klick" = eine bewusste Nutzeraktion
(inkl. Drag, Tastenkürzel). Drag-&-Drop zählt als 1 Aktion.

### Aufgabe A — Importieren → Umbenennen
| Schritt | Aktionen | Bemerkung |
|---|---|---|
| Dateien per Drag-&-Drop ablegen | 1 | Overlay + Auto-Scan |
| (optional) „Alle auswählen" | 0–1 | meist schon alle ausgewählt |
| „N umbenennen" / ⌘↩ | 1 | Primäraktion |
| Konflikte lösen (falls vorhanden) | 0–N | Sheet, „Für alle übernehmen" mildert |
| **Summe (Happy Path)** | **2** | Drag + Start |

### Aufgabe B — Umbenennen → Konvertieren
| Schritt | Aktionen |
|---|---|
| „Konvertieren" (Toolbar erscheint nach Done) oder pro Zeile ▶︎ | 1 |
| (optional) Codec/RF anpassen | 0–3 |
| „N konvertieren" / ⌘↩ | 1 |
| **Summe (Happy Path)** | **2** |

### Aufgabe C — Online-Metadaten + Ausgabeordner einrichten
| Schritt | Aktionen |
|---|---|
| ⌘, (Einstellungen) | 1 |
| TMDb-Toggle an | 1 |
| Key einfügen | 1 |
| „Verbindung testen" | 1 |
| Ausgabeordner-Toggle + „Ordner wählen…" + Finder | 3 |
| „Fertig" | 1 |
| **Summe** | **8** |

### Aufgabe D — Watch-Ordner aktivieren
| Schritt | Aktionen |
|---|---|
| Sidebar „Watch-Ordner" | 1 |
| „Ordner wählen…" + Finder | 2 |
| „Ordner überwachen" an | 1 |
| (optional) „Automatisch umbenennen" | 0–1 |
| **Summe** | **4** |

### Bewertung
- **Kernflüsse A/B sind exzellent** (2 Klicks). Das ist der wichtigste Pfad und
  funktioniert sehr direkt — Drag-&-Drop überall, sinnvolle Primäraktion mit ⌘↩.
- **Einrichtungsflüsse (C) sind klick-lastig**, weil alles in einem einzigen,
  langen Settings-Modal liegt (inzwischen 9 Gruppen). Scrollen nötig.

### Reibungspunkte (Severity: 🔴 hoch / 🟡 mittel / 🟢 niedrig)
1. 🔴 **Pfad-Bearbeitung nicht auffindbar (FR9).** Der Dateipfad in der Zeile
   *sieht* wie Text aus, ist aber ein Button, der den Finder öffnet — direktes
   Inline-Editing des Zielnamens fehlt sichtbar. FR9 („manuell bearbeiten") ist
   damit faktisch versteckt.
2. 🟡 **Settings-Monolith.** 9 Gruppen in einem 440 px-Modal ohne Tabs/Sektionen.
   Erstnutzer finden TMDb-Key, Ausgabeordner und Jellyfin nur durch Scrollen.
3. 🟡 **Konvertier-Warteschlange wächst.** Erledigte Dateien bleiben sichtbar;
   kein Auto-Clear/Filter „nur offene".
4. 🟡 **FFmpeg-Abhängigkeit.** Erstkontakt zeigt nur „nicht gefunden"; der
   `brew install`-Hinweis steht in der Übersicht, nicht direkt am Drop-Punkt.
5. 🟢 **Keine Suche/Filter in großen Listen** (viele Episoden → Scrollen).
6. 🟢 **Wenige Tastenkürzel** (nur ⌘, und ⌘Z) — „Liste leeren", Sortierung,
   Sektionswechsel nur per Maus.
7. 🟢 **Statusänderung erfordert Re-Import** (Metadatenquelle in Settings ändern →
   Modal schließen → erneut importieren, damit Enrichment greift).

---

## 2. FR-Heatmap (UI-Sichtbarkeit je Anforderung)

Intensität = wie präsent/auffindbar die Anforderung im UI ist.
🟩 prominent · 🟨 vorhanden, aber sekundär · 🟧 schwach/versteckt · ⬛ keine UI (Hintergrund).

| FR | Thema | UI-Sichtbarkeit | Hauptort | Lücke / Hinweis |
|---|---|---|---|---|
| FR1 | Drag-&-Drop Import | 🟩 | Queue, Convert, EmptyDrop | — |
| FR2 | Release-Parsing | 🟨 | FileRow (Chips) | implizit, gut |
| FR3 | Metadatenquellen | 🟨 | Settings, Übersicht | viele Toggles, tief im Modal |
| FR4 | Offizieller Titel | 🟧 | Settings („Nachschlagen") | kein klares „vorher/nachher" |
| FR5 | Jahr | 🟨 | FileRow-Chip | — |
| FR6 | Staffel/Episode | 🟩 | FileRow + Gruppen-Header | sehr gut |
| FR7 | Jellyfin-Benennung | 🟩 | FileRow + Statusleiste | — |
| FR8 | Vorschau | 🟩 | QueueView | Kernstück |
| FR9 | Annehmen/Ablehnen/**Bearbeiten** | 🟧 | FileRow Checkbox + Pfad | **Editing versteckt** 🔴 |
| FR10 | Stapelverarbeitung | 🟩 | Queue (Zähler, Select-All) | — |
| FR11 | Konflikte | 🟩 | ConflictResolution-Sheet | — |
| FR12 | Protokoll | 🟩 | LogView | — |
| FR13 | Rückgängig | 🟨 | Toolbar + ⌘Z | nur wenn sichtbar |
| FR14 | Untertitel | 🟨 | FileRow-Chip | — |
| FR15 | Extra-Dateien (NFO/Cover) | ⬛ | — | **keinerlei UI-Feedback** 🟡 |
| FR16 | FFmpeg-Konvertierung | 🟩 | ConvertView | — |
| FR17 | Hardware (VideoToolbox) | 🟨 | Convert-Toggle | — |
| FR18 | Lokal (keine Cloud) | 🟩 | Titelleisten-Badge + Übersicht | sehr gut |
| FR19 | GUI gesamt | 🟩 | alle Views | — |
| FR20 | Erweiterbarkeit (Watch/**Jellyfin**) | 🟨 | WatchView, Settings, Übersicht | Jellyfin jetzt ergänzt |

**Heatmap-Erkenntnisse**
- **Heißeste, gut sichtbare Zone:** Import → Vorschau → Umbenennen (FR1/6/7/8/10/11).
- **Kalte Flecken mit echtem Funktionswert:**
  - **FR9-Editing** (🟧, soll 🟩): das einzige als „hoch" eingestufte Defizit.
  - **FR15 Extra-Dateien** (⬛): passiert korrekt, aber unsichtbar — Nutzer weiß
    nicht, dass NFO/Cover mitgenommen werden → Vertrauen fehlt.
  - **FR4 offizieller Titel** (🟧): Enrichment-Ergebnis ist nicht als Diff sichtbar.

---

## 3. GUI-Überarbeitungsvorschlag

Priorisiert nach Wirkung/Aufwand. Stufe 1 = höchster Nutzen, kleinster Eingriff.

### Stufe 1 — schnelle, hochwirksame Fixes
1. **Inline-Rename sichtbar machen (FR9, 🔴).**
   - Stift-Icon in der FileRow neben dem Zielnamen; Klick → editierbares Feld
     (das vorhandene `updateProposedPath` ist schon da, inkl. Pfad-Sanitizing).
   - „Im Finder zeigen" bleibt am Ordner-Icon — die beiden Aktionen entkoppeln.
2. **Extra-/Begleitdateien anzeigen (FR15).**
   - Zusätzliche Chips „+NFO", „+Cover", „+Sample" bzw. „+3 Dateien" in der Zeile,
     analog zum Untertitel-Chip. Schafft Vertrauen, kein neuer Flow.
3. **Settings in Tabs gliedern.**
   - `TabView` mit 3 Reitern: **Benennung & Ausgabe** · **Erkennung** (KI/Embedded/
     DB/TMDb) · **Server & Automatik** (Jellyfin/Watch). Beseitigt das Scroll-Modal.

### Stufe 2 — Komfort
4. **Enrichment-Diff zeigen (FR4).** In der Zeile dezent „Erkannt: *The Matrix
   (1999)* via TMDb" unter dem Originalnamen → macht FR3/FR4 greifbar.
5. **Konvertier-Queue aufräumen.** Erledigte ausblenden/Toggle „nur offene"
   und „Erledigte entfernen"-Button.
6. **Such-/Filterfeld** im Listenkopf (filtert `sortedItems`).
7. **Mehr Tastenkürzel:** ⌘⌫ Liste leeren, ⌘F Suche, ⌘1–7 Sektionswechsel.

### Stufe 3 — größer
8. **FFmpeg-Onboarding:** Wenn fehlend, im Convert-Drop direkt Button
   „Installationsbefehl kopieren" + Pfad-Wähler für eine eigene ffmpeg-Binary.
9. **Persistente Aktivitäts-Leiste** (sektionsübergreifend): zeigt laufendes
   Umbenennen/Konvertieren/Watch/Jellyfin an einem festen Ort (oben rechts).
10. **Re-Enrichment ohne Re-Import:** „Erneut erkennen"-Button, wenn die
    Metadatenquelle geändert wurde.

### Vorgeschlagene Reihenfolge
> **1 → 2 → 3** zuerst (behebt den einzigen 🔴-Punkt und die zwei kalten
> Funktions-Flecken, plus Settings-Entwirrung). Danach Stufe 2 nach Bedarf.

---

## Anhang — Was in dieser Iteration bereits umgesetzt wurde
- **Jellyfin-Connector (FR20):** Server-URL + API-Schlüssel in den Einstellungen,
  „Verbindung testen", automatischer Bibliotheks-Rescan nach erfolgreichem
  Umbenennen (Export in die lokale Bibliothek), Statuszeile in der Übersicht. Es
  werden nur Scan-Befehle gesendet, keine Mediendateien (FR18).
- **Freier Ausgabeordner (FR18)** und **MKV-Tags via ffprobe (FR3)** (vorherige
  Iteration).
