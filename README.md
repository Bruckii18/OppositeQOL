# OppositeQOL

A small suite of quality-of-life tools for World of Warcraft raid leaders. Each
feature is a self-contained module you can enable or disable independently.

## Features

**Invite Helper** — Paste your list of expected players and compare it against
your current raid or party. The addon highlights who is *missing* (expected but
not in the group) and who is *not on the list* (in the group but not expected),
then lets you invite the missing players and remove the extras — all at once or
one name at a time. Matching is case-insensitive, supports cross-realm names,
and assumes your own realm when none is given.

**Who Pulled** — Calls out *who* pulled the boss and *how early or late* it was
versus the DBM/BigWigs pull timer (or Blizzard's countdown). Shows a local
center-screen banner on engage (`Boss pulled 0.42 seconds early by <Name>.`),
plays an optional alarm, and exempts tanks — they're supposed to pull. Raid
encounters only. Every pull is recorded into a per-night, per-instance session;
open the report (`/oqol pull`) for a per-puller leaderboard you can post to raid
or party chat.

The puller is resolved from the boss's target (= who holds aggro) first, then
the `C_DamageMeter` session as a fallback. *Combat-log "first hit" detection is
deliberately omitted:* Midnight (12.0) errors on `COMBAT_LOG_EVENT_UNFILTERED`
and wraps combat data in "secret values" during raid/M+ encounters, so the
first attacker can't be read at pull time.

Settings (in the `/oqol pull` window), both **off by default — opt in**: an
**alarm sound** toggle with a **sound dropdown** (the game's built-in alert
sounds, plus everything registered with LibSharedMedia if you run DBM /
WeakAuras / Details / ElvUI — no dependency, it just uses the shared pool when
present) and a **Play** preview button, and an **announce-puller-in-chat**
toggle with an `AUTO`/`SAY`/`YELL` channel selector.
The chat call-out fires for **prepulls only** (early pulls) and reads:

```
OppositeQOL: Prepulled the boss by 0.50sec. Who prepulled? Playername.
```

Because Midnight blocks addon chat during combat lockdown, the call-out is
*deferred* — it's queued at the pull and posted the moment the group leaves
combat (seconds later on a wipe). The live banner is always local-only and still
covers on-time/late pulls; only the chat shame is early-pull-specific.

**Module suite** — Every feature is a module with its own on/off setting, saved
per account. Disabling one hides its UI and stops it immediately, no reload
needed.

## Commands

- `/oqol` — open the module list (toggle modules, open their windows)
- `/oqol list` — print modules and their state
- `/oqol enable <module>` / `/oqol disable <module>`
- `/invitehelper` (or `/oqol invite`) — open Invite Helper
- `/oqol pull` (or `/oqol wp`) — open the Who Pulled report
- `/oqol minimap` — show/hide the minimap button

## Minimap button

A minimap button (its own bundled logo) gives one-click access: **left-click**
opens the module list, **right-click** opens the Who Pulled report, and you can
**drag** it around the minimap edge. Its position and visibility are saved; hide
it with `/oqol minimap`. It's built in without LibDBIcon/LibDataBroker, so the
addon stays dependency-free.

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
```
