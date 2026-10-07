# wattlog

**Real battery drain and charge wattage for Windows laptops.**

wattlog samples whole-system power draw (W), battery level and cumulative watt-hours
every few seconds while you work, then generates a **self-contained HTML report** with
charts, a ready-to-paste table and the machine spec it captured automatically.
Zero install: two files, no admin rights, no internet connection, MIT licensed.

```
Discharge · 80% → 65% · 57 min · avg 7.9 W
```

English | [日本語](README.ja-JP.md)

## What it measures — and what it honestly does not

| | |
|---|---|
| **Measured** | Whole-system watts during discharge **and** charging · battery level over time · %/h and minutes-per-1% · cumulative Wh · charge recovery rate · test conditions · machine spec |
| **Not measured** | Per-app power breakdown — Windows does not report accurate per-process wattage, so wattlog refuses to guess. NPU/GPU utilization counters — vendor naming differs per chipset |

Run one app alone and the whole-system watts are effectively that configuration.
For a single app's contribution, log an idle baseline and subtract it.

Watts come from two paths: the battery's own charge/discharge rate when the driver
exposes it, otherwise `capacity × level-change ÷ elapsed time`. The fallback works on
any machine that reports battery level.

## Why not the built-in battery report or a hardware monitor?

`powercfg /batteryreport` is free and built-in — keep using it. It estimates from
*history*. wattlog exists for the thing it cannot do: **measure a scenario you chose,
on a machine you are reviewing, with conditions attached**, and hand you a
publishable chart. HWiNFO64 is excellent but its free tier is licensed for
non-commercial use only; wattlog is MIT.

## Quick start

1. Copy the folder to the laptop you want to test (zip or USB — there is no installer).
2. Double-click `wattlog.cmd` and pick one of four measurements — discharge or charge,
   each by battery level or by minutes:
   ```
   1) Discharge (on battery): auto-stops at 10.0% remaining (default)
   2) Discharge (on battery): stop after N minutes (ends early at 10.0%) (default)
   3) Charge (plugged in): auto-stops at 100.0% or when charging completes (default)
   4) Charge (plugged in): stop after N minutes (ends early at 100.0% or charge complete) (default)
   ```
   Only 2 and 4 ask how many minutes; then one optional note about the conditions
   (Enter to skip). The thresholds shown are the values that will actually apply —
   if `wattlog.conf` or `-StopAt` changed them, you see the new number and where it came from.
3. Do the thing you want to measure. It stops itself at the threshold you set
   (default: 10% remaining) so the machine never hard-shuts-down mid-test.
4. Open the generated HTML, hit **Screenshot mode**, publish. The CSV sits next to it.

```
:: discharge: video playback, stop at 10% remaining
powershell -NoProfile -ExecutionPolicy Bypass -File logger.ps1 -Mode discharge -Interval 5 -StopAt 10 -Note "brightness 60%, volume 20, WiFi on"

:: charge: 10 minutes
powershell -NoProfile -ExecutionPolicy Bypass -File logger.ps1 -Mode charge -Interval 5 -Duration 10

:: rebuild only the HTML from an existing CSV (no re-measuring)
powershell -NoProfile -ExecutionPolicy Bypass -File logger.ps1 -FromCsv logs\wattlog-discharge-20261003-091417-menu.csv
```

### Options

| Flag | Meaning |
|---|---|
| `-Mode discharge\|charge` | measurement mode (skips the 4-choice menu) |
| `-Interval s` | sampling interval, default 5 |
| `-StopAt %` | auto-stop threshold — discharge stops at/below, charge at/above (default 10 / 100) |
| `-Duration min` | stop after N minutes |
| `-Note text` | free-text test conditions; power plan & screen brightness are captured automatically |
| `-Label text` | suffix for output filenames |
| `-Out dir` | output directory (default `logs`, absolute paths accepted) |
| `-KeepAwake on\|off` | prevent sleep during the run (default on) |
| `-FromCsv csv` | skip measuring, rebuild the HTML from an existing CSV |
| `-Lang en\|ja` | tool UI + report language (defaults to your Windows display language) |
| `-Conf path` | settings file to load (default: `wattlog.conf` next to `logger.ps1`, ignored when absent) |

### Settings file (wattlog.conf)

Tired of typing the same flags? Copy `wattlog.conf.sample` to `wattlog.conf` next to
`logger.ps1` and keep one `key=value` per line (`#` starts a comment, save as UTF-8):

```
interval=5
duration=60
stopat=10
```

Precedence: **command line > wattlog.conf > menu input > built-in default**, so a flag you
type always wins over the file. Writable keys are `interval`, `stopat`, `duration`, `out`,
`label`, `keepawake`, `lang`.

`mode` and `note` are deliberately **not** configurable — discharge/charge and the test
conditions change per run, so they are asked every time instead of being pinned in a file.

Bad values stop the run with an error instead of quietly falling back to a default
(a typo in `duration` must not silently disable the auto-stop you asked for).
Unknown keys, empty values and lines that aren't `key=value` are skipped with a warning
that names the line number.

Each CSV records what actually was in effect, so a run measured weeks ago stays
reproducible:

```
# params: mode=discharge interval=5.0 stopat=10.0 duration=60.0 keepawake=on lang=ja source=duration:conf
# config: C:\tools\wattlog\wattlog.conf
```

`source=` lists only the keys that are **not** at their built-in default, tagged `cli`,
`conf` or `menu`, and the `# config:` line is written only when a settings file was applied.

## The report

- **Charts** — battery % (pinned 0–100), instantaneous watts rendered as a ~1-minute
  rolling median (raw logs contain single-sample driver spikes; hover and selection
  statistics still use raw values), cumulative Wh.
- **Selection statistics** — click a start point, click an end point: average W, Δ%,
  %/h, ΔWh, Wh/h for that window. Drag works too.
- **Paste-ready table** — 15 min / 30 min / 1 h time-step table, copied as rich text
  straight into WordPress (visual editor) or as raw HTML markup.
- **Screenshot mode** — one button hides every interactive control and un-clips the
  sidebar so a full-page capture shows everything.
- **Machine spec, auto-captured** — model, OS build, CPU (cores/threads), RAM, GPU,
  resolution + refresh, disk types, NPU presence, battery cycle count. Read via
  CIM/registry as a normal user; unreadable items are skipped silently.
- **Available in English & Japanese UI** — menus, console and report language follow
  your Windows display language, or force it with `-Lang en|ja`. CSV data is
  language-neutral, so any recorded CSV can be rebuilt as either language:
  `logger.ps1 -FromCsv logs\run.csv -Lang en`.
- **Self-contained** — one HTML file, inline SVG/JS, opens from disk or USB with no
  dependencies. Nothing is uploaded anywhere.

## Requirements

- Windows 10 / 11 with a battery (desktops without a battery are out of scope)
- PowerShell 5.1 (built into Windows — `wattlog.cmd` handles the launch)
- No admin rights, no internet, no dependencies

## Limitations

- Sleep-prevention covers the run itself; lid-close behaviour follows your power
  plan (`powercfg` lid action if you need it closed).
- Charging watts depend on the vendor's charge controller; expect a few seconds of
  ramp-up noise at the start of a session (kept in the CSV, smoothed in the chart).
- Instantaneous watts are window-accurate, not sub-second transient-accurate.

## License

MIT — see [LICENSE](LICENSE). Built by [Convly](https://convly.jp).
