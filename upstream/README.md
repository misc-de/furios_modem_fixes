# Upstream-Meldungen — Stand 2026-09-13

Sechs Meldungen, fertig zum Einfügen in den jeweiligen Issue-Tracker.

| Datei | Repo | Schwere |
|---|---|---|
| `ofono2mm-1-connect-hang.md` | furilabs/oFono2MM | hoch — Modem bleibt bis zum Neustart tot |
| `ofono2mm-2-duplicate-bearer.md` | furilabs/oFono2MM | mittel |
| `ofono2mm-3-ipv6-family.md` | furilabs/oFono2MM | niedrig |
| `ofono2mm-4-signal-quality.md` | furilabs/oFono2MM | mittel — Signalanzeige ist dauerhaft blind |
| `mmsd4ofono-1-activation-loop.md` | furilabs/mmsd4ofono | hoch — destabilisiert die Datenverbindung |
| `mobile-broadband-provider-info-1-eu-alert-4372.md` | GNOME/mobile-broadband-provider-info | hoch — ein Warnkanal der Stufe „extreme“ fehlt, in DE **und** NL |

Die ersten vier wurden gegen den **aktuellen** Upstream-Stand geprüft, nicht nur
gegen die installierte Version:

- oFono2MM `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc`
- mmsd4ofono `forky` @ `9b04724b4e68dbcd899b827250eb8e07f57bb796`

## Nicht gemeldet, weil upstream bereits behoben

**Die fehlende Bus-Policy für Cell Broadcast** (Fehler 13) ist upstream
erledigt: `data/org.freedesktop.ModemManager1.conf.polkit` hat auf `main` drei
Regeln für `Modem.CellBroadcast` (`List` für alle, `Delete` und `SetChannels`
hinter polkit). Im Tag `1.24.2` — der hier installierten Version — kommt
`CellBroadcast` in der Datei **gar nicht vor**. Also nichts zu melden, sondern
etwas, das ein ModemManager-Update von selbst mitbringt. Unser Drop-in in
`../dbus/` ist bewusst enger gefasst als die Upstream-Regeln, weil die auf eine
polkit-Prüfung bauen, die ofono2mm nicht macht; `modemctl status` erkennt den
Tag, an dem er überflüssig wird, und `revert` nimmt ihn dann weg.

Die fehlende Netzmaske in `Ip4Config` (→ NetworkManager konfigurierte die
Adresse als `/0`) ist upstream erledigt: `utils.py` hat inzwischen
`netmask_to_prefix()`, verwendet in `mm_modem.py` und `mm_bearer.py`. Der
lokale Patch in `../patches/` ist damit faktisch ein Backport auf die
installierte Version 1.8.0.

## Der Neue (13.9.)

`mobile-broadband-provider-info-1-eu-alert-4372.md` betrifft nicht ofono2mm,
sondern die Datenbank, aus der `cellbroadcastd` seine Kanalliste nimmt. Gefunden
beim Beheben von Fehler 13: nach dem Fix hörte das Telefon auf 25 statt 8
Kanälen — aber **4372 war weg**, obwohl es vorher da war.

Es ist kein Landesentscheid, sondern ein Ausrutscher, und der Beweis steht im
Eintrag selbst: **4385 ist gelistet, 4372 nicht.** 4385 trägt die
fremdsprachige Fassung genau der Warnung, die auf 4372 gesendet wird — die
Übersetzung einer Warnung zu abonnieren, die Warnung selbst aber nicht, wählt
niemand. Dazu passt, dass `us` und `il` denselben Bereich als
`start="4371" end="4372"` schreiben, `de` und `nl` dagegen als
`start="4371" end="4371"`. Ein Zeichen Unterschied.

Gegen upstream `main` geprüft (13.9. geholt): dort steht derselbe Fehler, es ist
also nichts, was ein Paket-Update von selbst mitbringt.

## Wichtig für dieses Gerät

Die installierte Version ist **älter** als Upstream. Ein `ofono2mm`-Update
bringt also den Netzmasken-Fix und einen Teil des Zähler-Fixes von selbst mit
— überschreibt dabei aber die lokalen Patches. Nach einem Update also:

```bash
sudo /home/furios/modem-fixes/reapply.sh
```

Das Skript erkennt, wenn ein Patch nicht mehr passt (weil Upstream die Stelle
geändert hat), und meldet das, statt etwas kaputtzumachen.

## Noch nicht gegen aktuellen Upstream geprüft

`ofono2mm-4-signal-quality.md` (Signalanzeige) wurde gegen die **installierte**
Version geschrieben. Vor dem Melden bitte prüfen, ob `mm_modem_signal.py`
upstream inzwischen anders aussieht. Der dritte Teil des Berichts betrifft
ohnehin nicht ofono2mm, sondern ofonos `plugins/cellinfo-netmon.c` — das
gehört, wenn getrennt gemeldet, nach FuriLabs/ofono.
