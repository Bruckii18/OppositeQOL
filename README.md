# OppositeQOL

A small suite of quality-of-life tools for World of Warcraft raid leaders. Each
feature is a self-contained module you can enable or disable independently.

## Features

**Invite Helper** — Compares your expected roster against your current raid or
party: it highlights who's *missing* and who's *not on the list*, then lets you
invite or remove them in one click. **Needs input:** paste your list of expected
players.

**PrePull** — Calls out *how early or late* each boss was pulled versus the
DBM/BigWigs (or Blizzard) pull timer, with a local banner, an optional alarm, and
a per-night timing log you can post to chat (`/oqol pull`). Raid encounters only.
It deliberately does **not** try to name *who* pulled — in Midnight (12.0) addons
can no longer read combat events live, so that could only ever be a wrong guess.
For the actual puller, including totem / pet / trap / DoT pulls, use the
[companion tool](#companion-tool--prepull-report) below.

**Combat Log Status** — Shows whether combat logging is currently on, so you know
your pull is being recorded: a green (on) / red (off) dot on the minimap button,
plus a tooltip line and the `/oqol log` command. It only reports the state — it
never starts or stops logging.

**Module suite** — Every feature is a module with its own on/off setting, saved
per account. Toggle them in `/oqol`; disabling one stops it immediately.

## Commands

- `/oqol` — open the module list (toggle modules, open their windows)
- `/oqol list` — print modules and their state
- `/oqol enable <module>` / `/oqol disable <module>`
- `/invitehelper` (or `/oqol invite`) — open Invite Helper
- `/oqol pull` (or `/oqol wp`) — open the PrePull report
- `/oqol log` (or `/oqol cl`) — report whether combat logging is active
- `/oqol minimap` — show/hide the minimap button

## Minimap button

A minimap button (its own bundled logo) gives one-click access: **left-click**
opens the module list, **right-click** opens the PrePull report, and **drag**
moves it around the minimap edge. A status dot in its corner shows whether combat
logging is active (green) or not (red). Its position and visibility are saved;
hide it with `/oqol minimap`.

## Companion tool — Prepull report

Since Midnight (12.0), addons can no longer read the combat log live, so the
in-game **Who Pulled** module can only *guess* the puller and mislabels pulls set
off by a totem, pet, trap or DoT. The combat log *file* (`WoWCombatLog.txt`,
written while combat logging is on) still records everything, so a small offline
script can recover the truth after a session.

`tools/prepull_report.py` reads that log file and, for every boss pull, reports
**who** pulled, **when**, and **which ability** did it — tracing totem and pet
abilities back to the player who owns them. Optionally it also shows how early or
late each pull was versus the pull timer.

### Installation

It is a single self-contained file with **no dependencies** — just Python 3.9+
(already installed on macOS and Linux; on Windows, install it from python.org).
It is **not** part of the addon download; get the one file:

```sh
curl -O https://raw.githubusercontent.com/Bruckii18/OppositeQOL/main/tools/prepull_report.py
```

(Or download the repository as a ZIP and take `tools/prepull_report.py` out of it.)

### Usage

Run it with no arguments — it finds the newest combat log and your timing data
on its own:

```sh
# newest combat log, with timing, all pulls
python3 prepull_report.py

# just the boss you most recently pulled
python3 prepull_report.py --last
```

For that it needs to know where World of Warcraft is. It checks the usual install
locations and the folder the script sits in, but if your game is elsewhere (a
second drive, a custom path), set it up **once** with `--save`: point it at your
`OppositeQOL.lua` and it works out the rest — your WoW folder, and from there the
newest combat log — then remembers it.

```sh
# one time (this run also prints the report).
# <ACCOUNT> is your account-ID folder under WTF\Account, e.g. 468804367#1:
python3 prepull_report.py --sv "D:\...\World of Warcraft\_retail_\WTF\Account\<ACCOUNT>\SavedVariables\OppositeQOL.lua" --save

# from then on, no arguments needed:
python3 prepull_report.py --last
```

`--save` stores the paths in `~/.prepull_report.json` (a small text file you can
edit or delete to reset). Pointing at the game folder instead works the same
(`--wow "…\_retail_" --save`), as does the `OQOL_WOW_DIR` environment variable:

```sh
# Windows (new terminals): setx OQOL_WOW_DIR "D:\Games\World of Warcraft\_retail_"
# macOS / Linux:           export OQOL_WOW_DIR="/path/to/World of Warcraft/_retail_"
```

The notes printed before the report (`· log:` / `· timing:`) show which files were
picked. You can always pass paths explicitly to override:

```sh
python3 prepull_report.py "…/Logs/WoWCombatLog.txt" --sv "…/SavedVariables/OppositeQOL.lua"
```

Example output:

```
OppositeQOL · Prepull report
WoWCombatLog.txt  ·  2 pull(s)

  2026-01-01 20:00:00  ·  <boss>
      pulled by <player> using <ability>  (1.20s EARLY)

  2026-01-01 20:05:00  ·  <boss>
      pulled by <player> using <ability>  (0.45s late)

Prepull leaderboard
   1. <player>  ×2
```

The `(1.20s EARLY)` / `(0.45s late)` at the end of each line is the timing read
from your SavedVariables — it appears once those are found (auto-detected, or via
`--sv` / `--save`). Without them you still get *who* pulled, *when*, and with
*which ability*, just no early/late figure.

**Options:**

- `--last` — show only the most recent pull (e.g. the attempt you just wiped on)
- `--sv <file>` — use a specific SavedVariables file (otherwise auto-detected);
  this is what adds the early/late timing to each pull
- `--wow <folder>` — your `_retail_` folder, if it isn't found automatically
  (same as the `OQOL_WOW_DIR` environment variable)
- `--save` — remember `--wow`/`--sv` (or the auto-detected folder) in
  `~/.prepull_report.json`, so future runs need no arguments
- `--no-sv` — skip the timing merge entirely
- `--window N` — seconds before the pull to scan for the puller (default 10)
- `--gap N` — largest pause still counted as one pull, so an isolated early debuff
  isn't mistaken for the puller (default 3)
- `--json` — machine-readable output
- `NO_COLOR=1` — disable colored output

> The early/late timing comes from the addon's SavedVariables, which WoW only
> writes on `/reload` or logout — reload before running the tool if you want the
> very latest pulls' timing.

The tool only *reads* the log and prints to the console — nothing is written back
into the game, so you can run it anytime, even mid-raid with the game open. Keep
combat logging on during the raid (an auto-logger, or `/combatlog`); the **Combat
Log Status** dot shows whether it is.

## Installation

**Addon manager (recommended):** install from this repo's
[Releases](https://github.com/Bruckii18/OppositeQOL/releases) — each tagged
version is published as a packaged zip, so managers like WoWUp can keep it
updated automatically.

**Manual:** download the latest release zip and extract the `OppositeQOL` folder
into your AddOns directory:

```
World of Warcraft/_retail_/Interface/AddOns/OppositeQOL/
```

The folder must be named `OppositeQOL` and contain `OppositeQOL.toc`. If it shows
as out of date, tick *Load out of date AddOns* on the character-select screen or
update the `## Interface:` line in the `.toc`.

## Development

Standalone logic tests (no game required):

```sh
luajit tests/test_invitehelper.lua
luajit tests/test_whopulled.lua
luajit tests/test_combatlog.lua
python3 tools/test_prepull_report.py   # companion log parser
```
