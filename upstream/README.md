# Upstream-Meldungen — Stand 2026-09-12

Fünf Meldungen, fertig zum Einfügen in den jeweiligen Issue-Tracker.

| Datei | Repo | Schwere |
|---|---|---|
| `ofono2mm-1-connect-hang.md` | furilabs/oFono2MM | hoch — Modem bleibt bis zum Neustart tot |
| `ofono2mm-2-duplicate-bearer.md` | furilabs/oFono2MM | mittel |
| `ofono2mm-3-ipv6-family.md` | furilabs/oFono2MM | niedrig |
| `ofono2mm-4-signal-quality.md` | furilabs/oFono2MM | mittel — Signalanzeige ist dauerhaft blind |
| `mmsd4ofono-1-activation-loop.md` | furilabs/mmsd4ofono | hoch — destabilisiert die Datenverbindung |

Die ersten vier wurden gegen den **aktuellen** Upstream-Stand geprüft, nicht nur
gegen die installierte Version:

- oFono2MM `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc`
- mmsd4ofono `forky` @ `9b04724b4e68dbcd899b827250eb8e07f57bb796`

## Nicht gemeldet, weil upstream bereits behoben

Die fehlende Netzmaske in `Ip4Config` (→ NetworkManager konfigurierte die
Adresse als `/0`) ist upstream erledigt: `utils.py` hat inzwischen
`netmask_to_prefix()`, verwendet in `mm_modem.py` und `mm_bearer.py`. Der
lokale Patch in `../patches/` ist damit faktisch ein Backport auf die
installierte Version 1.8.0.

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
