#!/usr/bin/env python3
"""OppositeQOL — Prepull report (companion log parser).

The in-game addon can tell you *when* a pull happened and how early/late it was
versus the DBM/BigWigs timer, but in Midnight (12.0) it can no longer see the
combat log live, so it cannot reliably name *who* actually pulled — especially
when the trigger is a totem, pet, trap or DoT rather than a direct hit.

WoWCombatLog.txt *does* record all of that. This script reads that file after a
session, finds the real puller for every ENCOUNTER_START by walking back to the
first hostile-directed action in a short window before the pull, and chains
totem/pet GUIDs back to their owner via SPELL_SUMMON. It then (optionally) merges
the timing OppositeQOL recorded in its SavedVariables, so each pull gets both the
real culprit *and* the "X.XXs early/late" the log alone can't compute.

  Worked example (the L'ura prepull):
    SPELL_SUMMON       Torm  -> Earthbind Totem            (totem belongs to Torm)
    SPELL_AURA_APPLIED Earthbind Totem -> L'ura  (DEBUFF)  (totem pulls the boss)
    ENCOUNTER_START    L'ura
  => prepuller resolved as Torm, via the totem.

Usage:
    python3 tools/prepull_report.py <WoWCombatLog.txt> [--sv <OppositeQOL.lua>]
                                    [--window 10] [--json]

No third-party dependencies; Python 3.9+.
"""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Optional

# ---------------------------------------------------------------------------
# Combat-log subevent classification
# ---------------------------------------------------------------------------
# Unambiguously aggressive: a friendly unit dealing/attempting harm to a hostile
# one. These both *define* which units are the engaged enemies and can *be* the
# pulling action.
DAMAGE_EVENTS = {
    "SWING_DAMAGE", "RANGE_DAMAGE", "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE",
    "SPELL_BUILDING_DAMAGE", "DAMAGE_SHIELD", "DAMAGE_SPLIT",
}
MISS_EVENTS = {
    "SWING_MISSED", "RANGE_MISSED", "SPELL_MISSED", "SPELL_PERIODIC_MISSED",
    "SPELL_BUILDING_MISSED",
}
# Applying a debuff is aggressive too (this is what the Earthbind totem does).
AURA_APPLIED_EVENTS = {"SPELL_AURA_APPLIED", "SPELL_AURA_APPLIED_DOSE", "SPELL_AURA_REFRESH"}
# A successful offensive cast *at* an enemy can be the earliest sign of a pull,
# but only counts as a trigger when its target is a known enemy (casts also land
# on friendly units), so it never *defines* the enemy set on its own.
CAST_EVENTS = {"SPELL_CAST_SUCCESS"}

# COMBATLOG_OBJECT_* flag bits we rely on (reaction toward the player).
REACTION_FRIENDLY = 0x10
REACTION_HOSTILE = 0x40

NULL_GUID = "0000000000000000"


# ---------------------------------------------------------------------------
# GUID helpers
# ---------------------------------------------------------------------------
def guid_type(guid: str) -> str:
    """Player / Creature / Pet / Vehicle / ... or 'Null' for the empty GUID."""
    if not guid or guid == NULL_GUID:
        return "Null"
    return guid.split("-", 1)[0]


def npc_id(guid: str) -> Optional[str]:
    """The npcID embedded in a Creature/Pet/Vehicle GUID, else None.

    Creature-0-<server>-<instance>-<zone>-<npcID>-<spawn>  -> field index 5.
    """
    if guid_type(guid) in ("Creature", "Pet", "Vehicle"):
        parts = guid.split("-")
        if len(parts) >= 6:
            return parts[5]
    return None


def looks_like_guid(token: str) -> bool:
    return token == NULL_GUID or token.split("-", 1)[0] in (
        "Player", "Creature", "Pet", "Vehicle", "GameObject", "BattlePet", "Vignette",
    )


# ---------------------------------------------------------------------------
# Combat-log parsing
# ---------------------------------------------------------------------------
_LINE_RE = re.compile(
    r"^\s*(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\.(\d+)(?:[-+]\d+)?\s+(.*)$"
)


@dataclass
class Event:
    ts: datetime
    sub: str
    parts: list           # raw comma-split payload, subevent at index 0
    src_guid: str = ""
    src_name: str = ""
    src_flags: int = 0
    dst_guid: str = ""
    dst_name: str = ""
    dst_flags: int = 0
    spell_name: Optional[str] = None
    aura_type: Optional[str] = None

    @property
    def src_friendly(self) -> bool:
        return bool(self.src_flags & REACTION_FRIENDLY)

    @property
    def dst_hostile(self) -> bool:
        return bool(self.dst_flags & REACTION_HOSTILE)


def _to_flags(token: str) -> int:
    try:
        return int(token, 16) if token.lower().startswith("0x") else int(token)
    except (ValueError, AttributeError):
        return 0


def parse_log_line(line: str) -> Optional[Event]:
    """Parse one WoWCombatLog.txt line into an Event, or None for header/blank."""
    m = _LINE_RE.match(line)
    if not m:
        return None
    mo, da, yr, hh, mm, ss, frac, payload = m.groups()
    micros = int(round(int(frac) / (10 ** len(frac)) * 1_000_000))
    ts = datetime(int(yr), int(mo), int(da), int(hh), int(mm), int(ss), micros)

    try:
        parts = next(csv.reader([payload]))
    except (StopIteration, csv.Error):
        return None
    if not parts:
        return None

    ev = Event(ts=ts, sub=parts[0], parts=parts)

    # Base parameters (source 4 + dest 4) are present and positionally stable for
    # every "normal" subevent. Special events (ENCOUNTER_START, COMBATANT_INFO,
    # ...) carry a number/GUID we don't treat as source/dest -- guarded below.
    if len(parts) >= 9 and looks_like_guid(parts[1]) and looks_like_guid(parts[5]):
        ev.src_guid, ev.src_name = parts[1], parts[2]
        ev.src_flags = _to_flags(parts[3])
        ev.dst_guid, ev.dst_name = parts[5], parts[6]
        ev.dst_flags = _to_flags(parts[7])
        if ev.sub.startswith(("SPELL_", "RANGE_")) and len(parts) > 10:
            ev.spell_name = parts[10]
        elif ev.sub.startswith("SWING_"):
            ev.spell_name = "Melee"
        if ev.sub.startswith("SPELL_AURA"):
            ev.aura_type = parts[-1]
    return ev


def parse_events(lines) -> list:
    events = [parse_log_line(ln) for ln in lines]
    return [e for e in events if e is not None]


def build_summon_map(events) -> dict:
    """summonedGUID -> (ownerGUID, ownerName, summonSpellName) for SPELL_SUMMON."""
    smap = {}
    for e in events:
        if e.sub == "SPELL_SUMMON" and e.dst_guid:
            smap[e.dst_guid] = (e.src_guid, e.src_name, e.spell_name)
    return smap


# ---------------------------------------------------------------------------
# Puller resolution
# ---------------------------------------------------------------------------
@dataclass
class Puller:
    guid: str
    name: str
    is_player: bool
    via_summon: Optional[str] = None   # totem/pet/guardian label, if resolved through one
    raw_guid: str = ""
    raw_name: str = ""


def resolve_owner(guid: str, name: str, summon_map: dict) -> Puller:
    """Walk a totem/pet/guardian GUID back to the player that summoned it."""
    via = None
    cur_guid, cur_name = guid, name
    seen = set()
    while guid_type(cur_guid) != "Player" and cur_guid in summon_map and cur_guid not in seen:
        seen.add(cur_guid)
        owner_guid, owner_name, summon_spell = summon_map[cur_guid]
        if via is None:
            via = summon_spell          # the first hop names the totem/pet itself
        cur_guid, cur_name = owner_guid, owner_name
    return Puller(
        guid=cur_guid, name=cur_name, is_player=(guid_type(cur_guid) == "Player"),
        via_summon=via, raw_guid=guid, raw_name=name,
    )


def _is_enemy_target(e: Event) -> bool:
    """A friendly unit aggressing a hostile, non-player target."""
    return (
        e.src_friendly and e.dst_hostile
        and guid_type(e.dst_guid) in ("Creature", "Vehicle", "Pet")
    )


def _is_trigger(e: Event) -> bool:
    if e.sub in DAMAGE_EVENTS or e.sub in MISS_EVENTS:
        return _is_enemy_target(e)
    if e.sub in AURA_APPLIED_EVENTS:
        return e.aura_type == "DEBUFF" and _is_enemy_target(e)
    if e.sub in CAST_EVENTS:
        return _is_enemy_target(e)
    return False


@dataclass
class Pull:
    ts: datetime
    encounter_id: Optional[int]
    encounter_name: str
    engaged_unit: Optional[str] = None    # the actual boss/add the trigger hit
    trigger_spell: Optional[str] = None
    puller: Optional[Puller] = None
    # filled in by the merge step:
    timing_diff: Optional[float] = None   # seconds vs the pull timer (negative = early)
    timing_source: Optional[str] = None
    addon_guess: Optional[str] = None     # what OppositeQOL recorded in-game


def _encounter_starts(events):
    for idx, e in enumerate(events):
        if e.sub == "ENCOUNTER_START":
            eid = None
            if len(e.parts) > 1:
                try:
                    eid = int(e.parts[1])
                except ValueError:
                    eid = None
            name = e.parts[2] if len(e.parts) > 2 else "?"
            yield idx, e, eid, name


def _burst_start(pool, gap):
    """The action that *began* the pull.

    `pool` is the time-sorted list of friendly->hostile actions before the pull.
    The encounter starts the instant the boss is engaged, so the pulling action
    runs right into ENCOUNTER_START. Walk back from the action nearest the pull
    through the contiguous burst and stop at the first gap larger than `gap`, so
    an isolated early non-threat debuff (e.g. a Hunter's Mark applied 12s before,
    after which nothing happened until the real pull) is not blamed. The earliest
    action in that final burst is the puller -- the first to commit to the pull
    that actually stuck.
    """
    trigger = pool[-1]
    for earlier in reversed(pool[:-1]):
        if (trigger.ts - earlier.ts).total_seconds() <= gap:
            trigger = earlier
        else:
            break
    return trigger


def detect_pulls(events, window=10.0, post=15.0, gap=3.0):
    """One Pull per ENCOUNTER_START, with the resolved prepuller."""
    summon_map = build_summon_map(events)
    times = [e.ts for e in events]   # events arrive time-ordered; index by ts
    pulls = []

    for _, start, eid, name in _encounter_starts(events):
        T = start.ts
        lo = bisect.bisect_left(times, T - timedelta(seconds=window))
        # Enemies actually engaged just after the pull (boss + adds), to bind the
        # prepull to *this* encounter and ignore unrelated trash in the window.
        hi = bisect.bisect_right(times, T + timedelta(seconds=post))
        engaged = {
            npc_id(e.dst_guid)
            for e in events[bisect.bisect_left(times, T):hi]
            if _is_enemy_target(e) and npc_id(e.dst_guid)
        }

        candidates = [e for e in events[lo:bisect.bisect_left(times, T)] if _is_trigger(e)]
        bound = [e for e in candidates if npc_id(e.dst_guid) in engaged]
        pool = sorted(bound or candidates, key=lambda e: e.ts)

        pull = Pull(ts=T, encounter_id=eid, encounter_name=name)
        if pool:
            trigger = _burst_start(pool, gap)
            pull.trigger_spell = trigger.spell_name
            pull.engaged_unit = trigger.dst_name or name
            pull.puller = resolve_owner(trigger.src_guid, trigger.src_name, summon_map)
        pulls.append(pull)
    return pulls


# ---------------------------------------------------------------------------
# SavedVariables (Lua table) parser -- the subset WoW's serializer emits
# ---------------------------------------------------------------------------
class LuaParseError(Exception):
    pass


class _LuaReader:
    """Recursive-descent reader for WoW SavedVariables tables.

    Handles the machine-generated subset: nested `{ ... }` tables, `["key"]=` and
    `[n]=` and bare positional entries, quoted strings (with \\ escapes), numbers
    (int/float/hex), and true/false/nil. Tables become dicts; positional items get
    1-based integer keys (see `seq`). Comments are tolerated though SV emits none.
    """

    _NUM_RE = re.compile(r"-?0[xX][0-9a-fA-F]+|-?\d+\.?\d*(?:[eE][-+]?\d+)?")
    _NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

    def __init__(self, text: str):
        self.s = text
        self.i = 0
        self.n = len(text)

    def _skip(self):
        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif c == "-" and self.s[self.i:self.i + 2] == "--":
                if self.s[self.i:self.i + 4] == "--[[":
                    end = self.s.find("]]", self.i + 4)
                    self.i = (end + 2) if end != -1 else self.n
                else:
                    nl = self.s.find("\n", self.i)
                    self.i = (nl + 1) if nl != -1 else self.n
            else:
                break

    def _peek(self):
        return self.s[self.i] if self.i < self.n else ""

    def _expect(self, ch):
        self._skip()
        if self._peek() != ch:
            raise LuaParseError(f"expected {ch!r} at offset {self.i}")
        self.i += 1

    def parse_toplevel(self) -> dict:
        """Top level is a series of `Name = value` assignments (one per SV)."""
        out = {}
        self._skip()
        while self.i < self.n:
            m = self._NAME_RE.match(self.s, self.i)
            if not m:
                break
            name = m.group(0)
            self.i = m.end()
            self._expect("=")
            out[name] = self._value()
            self._skip()
            if self._peek() == ";":
                self.i += 1
            self._skip()
        return out

    def _value(self):
        self._skip()
        c = self._peek()
        if c == "{":
            return self._table()
        if c in "\"'":
            return self._string()
        if self.s.startswith("true", self.i):
            self.i += 4
            return True
        if self.s.startswith("false", self.i):
            self.i += 5
            return False
        if self.s.startswith("nil", self.i):
            self.i += 3
            return None
        m = self._NUM_RE.match(self.s, self.i)
        if m:
            self.i = m.end()
            tok = m.group(0)
            if tok.lower().startswith(("0x", "-0x")):
                return int(tok, 16)
            return float(tok) if ("." in tok or "e" in tok.lower()) else int(tok)
        raise LuaParseError(f"unexpected value at offset {self.i}: {self.s[self.i:self.i+20]!r}")

    def _string(self):
        quote = self.s[self.i]
        self.i += 1
        buf = []
        while self.i < self.n:
            c = self.s[self.i]
            if c == "\\":
                nxt = self.s[self.i + 1] if self.i + 1 < self.n else ""
                if nxt.isdigit():
                    j = self.i + 1
                    while j < self.n and self.s[j].isdigit() and j - self.i <= 3:
                        j += 1
                    buf.append(chr(int(self.s[self.i + 1:j])))
                    self.i = j
                    continue
                buf.append({"n": "\n", "t": "\t", "r": "\r"}.get(nxt, nxt))
                self.i += 2
            elif c == quote:
                self.i += 1
                return "".join(buf)
            else:
                buf.append(c)
                self.i += 1
        raise LuaParseError("unterminated string")

    def _table(self):
        self._expect("{")
        out = {}
        idx = 1
        while True:
            self._skip()
            c = self._peek()
            if c == "":
                raise LuaParseError("unterminated table")
            if c == "}":
                self.i += 1
                return out
            if c == "[":
                self.i += 1
                self._skip()
                key = self._string() if self._peek() in "\"'" else self._bracket_number()
                self._expect("]")
                self._expect("=")
                out[key] = self._value()
            else:
                # `name = value` or a positional value.
                m = self._NAME_RE.match(self.s, self.i)
                save = self.i
                if m:
                    self.i = m.end()
                    self._skip()
                    if self._peek() == "=":
                        self.i += 1
                        out[m.group(0)] = self._value()
                    else:                       # it was a bare value (true/false/nil)
                        self.i = save
                        out[idx] = self._value()
                        idx += 1
                else:
                    out[idx] = self._value()
                    idx += 1
            self._skip()
            if self._peek() in ",;":
                self.i += 1

    def _bracket_number(self):
        m = self._NUM_RE.match(self.s, self.i)
        if not m:
            raise LuaParseError(f"expected numeric key at offset {self.i}")
        self.i = m.end()
        return int(m.group(0))


def parse_savedvariables(text: str) -> dict:
    return _LuaReader(text).parse_toplevel()


def seq(table) -> list:
    """Ordered positional values of a parsed table (dict with 1..N int keys)."""
    if table is None:
        return []
    if isinstance(table, list):
        return table
    if isinstance(table, dict):
        return [table[k] for k in sorted(k for k in table if isinstance(k, int))]
    return []


def extract_addon_pulls(db: dict) -> list:
    """Flatten OppositeQOLDB.whoPulled.sessions[].pulls[] into plain dicts."""
    out = []
    wp = (db or {}).get("whoPulled") or {}
    for session in seq(wp.get("sessions")):
        if not isinstance(session, dict):
            continue
        for rec in seq(session.get("pulls")):
            if isinstance(rec, dict):
                out.append({
                    "encounterID": rec.get("encounterID"),
                    "localTime": rec.get("localTime"),
                    "pullTimeDiff": rec.get("pullTimeDiff"),
                    "encounterName": rec.get("encounterName"),
                    "pullerName": rec.get("pullerName"),
                    "pullerClass": rec.get("pullerClass"),
                })
    return out


def _addon_guess_label(rec: dict) -> str:
    name = rec.get("pullerName")
    if name:
        return name
    cls = rec.get("pullerClass")
    return f"[Unknown {cls}]" if cls else "[Unknown]"


def merge_timing(pulls, addon_pulls, tolerance=180.0):
    """Attach each addon record's timing to the matching log pull.

    Match on encounterID, then nearest local wall-clock timestamp (both the log
    line and the addon's `localTime` are the same client's local time).
    """
    parsed = []
    for rec in addon_pulls:
        lt = rec.get("localTime")
        when = None
        if isinstance(lt, str):
            try:
                when = datetime.strptime(lt, "%Y-%m-%d %H:%M:%S")
            except ValueError:
                when = None
        parsed.append((rec, when))

    for pull in pulls:
        best, best_gap = None, tolerance + 1
        for rec, when in parsed:
            if pull.encounter_id is None or rec.get("encounterID") is None:
                continue
            try:
                same = int(rec["encounterID"]) == int(pull.encounter_id)
            except (TypeError, ValueError):
                same = False
            if not same or when is None:
                continue
            gap = abs((when - pull.ts).total_seconds())
            if gap < best_gap:
                best, best_gap = rec, gap
        if best is not None and best_gap <= tolerance:
            pull.timing_diff = best.get("pullTimeDiff")
            pull.timing_source = "OppositeQOL"
            pull.addon_guess = _addon_guess_label(best)
    return pulls


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
# ANSI colors, auto-disabled when stdout isn't a terminal or NO_COLOR is set.
_ANSI = {
    "reset": "\033[0m", "bold": "\033[1m", "dim": "\033[2m",
    "green": "\033[32m", "yellow": "\033[33m", "red": "\033[31m",
    "cyan": "\033[36m", "grey": "\033[90m",
}


def _use_color(explicit):
    if explicit is not None:
        return explicit
    return sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def _timing_text(pull: Pull):
    """Early/late vs the pull timer; None when no addon timing was merged in."""
    if pull.timing_source is None:
        return None
    diff = pull.timing_diff
    if diff is None:
        return "untimed"
    if diff <= -0.25:
        return f"{-diff:.2f}s EARLY"
    if diff < 0.25:
        return "on time"
    return f"{diff:.2f}s late"


def _puller_text(pull: Pull):
    p = pull.puller
    if p is None:
        return None
    if not p.is_player:
        return f"[unattributed {guid_type(p.raw_guid)}: {p.raw_name or p.name or '?'}]"
    return p.name or "?"


def render_text(pulls, log_path, color=None):
    on = _use_color(color)

    def c(s, key):
        return f"{_ANSI[key]}{s}{_ANSI['reset']}" if on else s

    out = [
        c("OppositeQOL · Prepull report", "bold"),
        c(f"{os.path.basename(log_path)}  ·  {len(pulls)} pull(s)", "grey"),
        "",
    ]
    tally = {}
    for pull in pulls:
        # WHEN + which boss
        when = pull.ts.strftime("%Y-%m-%d %H:%M:%S")
        unit = pull.engaged_unit or pull.encounter_name
        out.append(f"  {c(when, 'grey')}  ·  {c(unit, 'cyan')}")

        puller = _puller_text(pull)
        if puller is None:
            out.append("      " + c("no pre-pull action found in the log window", "yellow"))
        else:
            # WHO ... using WHICH ABILITY ... (how early/late)
            line = "      " + c("pulled by", "dim") + " " + c(puller, "green")
            if pull.trigger_spell:
                ability = pull.trigger_spell
                if pull.puller and pull.puller.via_summon:
                    ability += f" ({pull.puller.via_summon})"
                line += " " + c("using", "dim") + " " + ability
            timing = _timing_text(pull)
            if timing:
                key = "yellow" if "EARLY" in timing else "red" if "late" in timing else "dim"
                line += "  (" + c(timing, key) + ")"
            out.append(line)
            if pull.addon_guess and pull.puller and pull.puller.is_player \
                    and pull.addon_guess not in (pull.puller.name or ""):
                out.append("      " + c("addon saw", "dim") + " "
                           + c(f"{pull.addon_guess}  (in-game guess, now corrected)", "grey"))
            tally[puller] = tally.get(puller, 0) + 1
        out.append("")

    if len(pulls) > 1 and tally:  # a leaderboard of one pull is just noise
        out.append(c("Prepull leaderboard", "bold"))
        for i, (name, count) in enumerate(sorted(tally.items(), key=lambda kv: -kv[1]), 1):
            out.append(f"  {i:2d}. {c(name, 'green')}  ×{count}")
    return "\n".join(out)


def render_json(pulls) -> str:
    def as_dict(pull: Pull):
        p = pull.puller
        return {
            "ts": pull.ts.isoformat(),
            "encounterID": pull.encounter_id,
            "encounterName": pull.encounter_name,
            "engagedUnit": pull.engaged_unit,
            "triggerSpell": pull.trigger_spell,
            "puller": None if p is None else {
                "name": p.name, "isPlayer": p.is_player, "viaSummon": p.via_summon,
                "rawName": p.raw_name, "rawType": guid_type(p.raw_guid),
            },
            "timingDiff": pull.timing_diff,
            "timingSource": pull.timing_source,
            "addonGuess": pull.addon_guess,
        }
    return json.dumps([as_dict(p) for p in pulls], indent=2, ensure_ascii=False)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def run(log_path, sv_path=None, window=10.0, post=15.0, gap=3.0, tolerance=180.0):
    with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
        events = parse_events(fh)
    pulls = detect_pulls(events, window=window, post=post, gap=gap)
    if sv_path:
        with open(sv_path, "r", encoding="utf-8", errors="replace") as fh:
            db = parse_savedvariables(fh.read()).get("OppositeQOLDB", {})
        merge_timing(pulls, extract_addon_pulls(db), tolerance=tolerance)
    return pulls


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Resolve who really prepulled each boss from WoWCombatLog.txt, "
                    "merging OppositeQOL's recorded pull timing.")
    ap.add_argument("log", help="path to WoWCombatLog.txt")
    ap.add_argument("--sv", help="path to OppositeQOL.lua SavedVariables (for timing)")
    ap.add_argument("--window", type=float, default=10.0,
                    help="seconds before ENCOUNTER_START to scan for the puller (default 10)")
    ap.add_argument("--gap", type=float, default=3.0,
                    help="max gap (s) between consecutive actions still counted as one "
                         "pull burst; separates the real pull from an isolated early "
                         "debuff (default 3)")
    ap.add_argument("--post", type=float, default=15.0,
                    help="seconds after the pull used to identify the engaged boss/adds (default 15)")
    ap.add_argument("--tolerance", type=float, default=180.0,
                    help="max seconds between a log pull and an addon record to match them (default 180)")
    ap.add_argument("--last", action="store_true",
                    help="show only the most recent pull (e.g. the attempt you just wiped on)")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = ap.parse_args(argv)

    try:
        pulls = run(args.log, args.sv, args.window, args.post, args.gap, args.tolerance)
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    if not pulls:
        print("No ENCOUNTER_START found in the log.", file=sys.stderr)
        return 1
    if args.last:
        pulls = pulls[-1:]
    print(render_json(pulls) if args.json else render_text(pulls, args.log))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
