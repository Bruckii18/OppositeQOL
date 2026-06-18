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

**Module suite** — Every feature is a module with its own on/off setting, saved
per account. Disabling one hides its UI and stops it immediately, no reload
needed.

## Commands

- `/oqol` — open the module list (toggle modules, open their windows)
- `/oqol list` — print modules and their state
- `/oqol enable <module>` / `/oqol disable <module>`
- `/invitehelper` (or `/oqol invite`) — open Invite Helper

## Installation

Copy the `OppositeQOL` folder into your AddOns directory:

```
World of Warcraft/_retail_/Interface/AddOns/OppositeQOL/
```

The folder must be named `OppositeQOL` and contain `OppositeQOL.toc`. If it shows
as out of date, tick *Load out of date AddOns* on the character-select screen or
update the `## Interface:` line in the `.toc`.

## Development

A standalone logic test (no game required):

```sh
luajit tests/test_invitehelper.lua
```
