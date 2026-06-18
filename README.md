# OppositeQOL

A small suite of quality-of-life tools for World of Warcraft raid leaders. Each
feature is a self-contained module you can enable or disable independently.

## Features

**Invite Helper** — Compares your expected roster against your current raid or
party: it highlights who's *missing* and who's *not on the list*, then lets you
invite or remove them in one click. **Needs input:** paste your list of expected
players.

**Who Pulled** — Calls out *who* pulled the boss and *how early or late* it was
versus the DBM/BigWigs pull timer, and keeps a per-night leaderboard you can post
to chat (`/oqol pull`). Raid encounters only; tanks are exempt. **Optional
input:** in the report window you can turn on an alarm sound and/or a chat
call-out for prepulls (both off by default).

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
- `/oqol pull` (or `/oqol wp`) — open the Who Pulled report
- `/oqol log` (or `/oqol cl`) — report whether combat logging is active
- `/oqol minimap` — show/hide the minimap button

## Minimap button

A minimap button (its own bundled logo) gives one-click access: **left-click**
opens the module list, **right-click** opens the Who Pulled report, and **drag**
moves it around the minimap edge. A status dot in its corner shows whether combat
logging is active (green) or not (red). Its position and visibility are saved;
hide it with `/oqol minimap`.

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
```
