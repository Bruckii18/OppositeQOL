#!/usr/bin/env python3
"""Standalone tests for tools/prepull_report.py (no third-party deps).

Run from the project root:  python3 tools/test_prepull_report.py

Built around the real L'ura prepull from the combat log: a Shaman's Earthbind
Totem applies Earthbind to the boss, which starts the encounter. The puller is
the totem's owner (Torm), reachable only by chaining the totem GUID back through
SPELL_SUMMON -- exactly what the in-game addon cannot do.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import prepull_report as pr  # noqa: E402

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
# Two pulls in one log: (1) L'ura, prepulled by Torm's Earthbind Totem; (2) a
# second boss pulled by a plain tank melee swing (the direct, non-totem path).
LOG = """\
COMBAT_LOG_VERSION,21,ADVANCED_LOG_ENABLED,1,BUILD_VERSION,12.0.0,PROJECT_ID,1
6/17/2026 22:14:30.0000  SPELL_CAST_SUCCESS,Player-1092-0B277307,"Torm-Drak'thul-EU",0x514,0x0,0000000000000000,nil,0x80000000,0x80000000,2484,"Earthbind Totem",0x8
6/17/2026 22:14:32.0612  SPELL_SUMMON,Player-1092-0B277307,"Torm-Drak'thul-EU",0x514,0x80000000,Creature-0-4243-2913-7785-2630-0000330027,"Unknown",0xa28,0x80000000,2484,"Earthbind Totem",0x8
6/17/2026 22:14:32.0612  SPELL_CAST_SUCCESS,Creature-0-4243-2913-7785-2630-0000330027,"Unknown",0x2114,0x80000000,0000000000000000,nil,0x80000000,0x80000000,3600,"Earthbind",0x8
6/17/2026 22:14:32.1142  SPELL_AURA_APPLIED,Creature-0-4243-2913-7785-2630-0000330027,"Unknown",0x2114,0x80000000,Vehicle-0-4243-2913-7785-240391-0000330020,"L'ura",0xa48,0x80000000,3600,"Earthbind",0x8,DEBUFF
6/17/2026 22:14:32.1322  ENCOUNTER_START,3183,"Midnight Falls",16,20,2913
6/17/2026 22:14:33.5000  SPELL_DAMAGE,Player-1092-0AAA0001,"Dpsy-Drak'thul-EU",0x511,0x0,Vehicle-0-4243-2913-7785-240391-0000330020,"L'ura",0x10a48,0x0,12345,"Frostbolt",0x10,500,500,0,0,0,0,nil,nil,nil
6/17/2026 22:40:00.0000  ENCOUNTER_END,3183,"Midnight Falls",16,20,0
6/17/2026 23:01:10.0000  SWING_DAMAGE,Player-1092-0CCC0002,"Tankzor-Drak'thul-EU",0x511,0x0,Creature-0-4243-2913-7785-2700-0000331111,"Gatekeeper",0x10a48,0x0,9001,9001,0,0,0,0,0,nil,nil,nil
6/17/2026 23:01:10.5000  ENCOUNTER_START,3184,"The Gatekeeper",16,20,2913
6/17/2026 23:01:11.0000  SPELL_DAMAGE,Player-1092-0CCC0002,"Tankzor-Drak'thul-EU",0x511,0x0,Creature-0-4243-2913-7785-2700-0000331111,"Gatekeeper",0x10a48,0x0,222,"Strike",0x1,222,222,0,0,0,0,nil,nil,nil
"""

SAVEDVARS = """\
OppositeQOLDB = {
\t["whoPulled"] = {
\t\t["sessions"] = {
\t\t\t{
\t\t\t\t["instanceName"] = "Midnight Falls",
\t\t\t\t["pulls"] = {
\t\t\t\t\t{
\t\t\t\t\t\t["ts"] = 1750191272,
\t\t\t\t\t\t["localTime"] = "2026-06-17 22:14:32",
\t\t\t\t\t\t["encounterID"] = 3183,
\t\t\t\t\t\t["encounterName"] = "Midnight Falls",
\t\t\t\t\t\t["pullTimeDiff"] = -2.34,
\t\t\t\t\t},
\t\t\t\t},
\t\t\t},
\t\t},
\t},
}
"""

# ---------------------------------------------------------------------------
# Tiny check harness (mirrors the Lua tests' style)
# ---------------------------------------------------------------------------
_ok = True


def check(name, cond):
    global _ok
    print(("PASS " if cond else "FAIL ") + name)
    _ok = _ok and bool(cond)


# ---- low-level parsing -----------------------------------------------------
ev = pr.parse_log_line(
    '6/17/2026 22:14:32.1142  SPELL_AURA_APPLIED,Creature-0-4243-2913-7785-2630-0000330027,'
    '"Unknown",0x2114,0x80000000,Vehicle-0-4243-2913-7785-240391-0000330020,"L\'ura",0xa48,'
    '0x80000000,3600,"Earthbind",0x8,DEBUFF')
check("parses subevent", ev.sub == "SPELL_AURA_APPLIED")
check("parses source name", ev.src_name == "Torm-Drak'thul-EU" or ev.src_guid.startswith("Creature-"))
check("parses dest name", ev.dst_name == "L'ura")
check("decodes friendly source flag", ev.src_friendly is True)
check("decodes hostile dest flag", ev.dst_hostile is True)
check("reads aura type", ev.aura_type == "DEBUFF")
check("reads spell name", ev.spell_name == "Earthbind")
check("header line is skipped", pr.parse_log_line("COMBAT_LOG_VERSION,21,...") is None)

check("npc id from vehicle guid",
      pr.npc_id("Vehicle-0-4243-2913-7785-240391-0000330020") == "240391")
check("npc id from creature guid",
      pr.npc_id("Creature-0-4243-2913-7785-2630-0000330027") == "2630")
check("player guid has no npc id", pr.npc_id("Player-1092-0B277307") is None)
check("guid type", pr.guid_type("Player-1092-0B277307") == "Player"
      and pr.guid_type(pr.NULL_GUID) == "Null")

# ---- Lua SavedVariables parser ---------------------------------------------
mixed = pr.parse_savedvariables(
    'X = { ["a"] = "hi\\nthere", ["b"] = -2.34, ["c"] = true, ["d"] = nil, '
    '["e"] = 0x2114, [1] = "first", [2] = "second", ["t"] = { ["k"] = 7 } }')["X"]
check("lua: string with escape", mixed["a"] == "hi\nthere")
check("lua: negative float", mixed["b"] == -2.34)
check("lua: boolean", mixed["c"] is True)
check("lua: nil", mixed["d"] is None)
check("lua: hex number", mixed["e"] == 0x2114)
check("lua: positional entries become 1-based int keys",
      pr.seq(mixed)[:2] == ["first", "second"])
check("lua: nested table", mixed["t"]["k"] == 7)

db = pr.parse_savedvariables(SAVEDVARS)["OppositeQOLDB"]
addon_pulls = pr.extract_addon_pulls(db)
check("extracts one addon pull", len(addon_pulls) == 1)
check("addon pull keeps encounterID + localTime + diff",
      addon_pulls[0]["encounterID"] == 3183
      and addon_pulls[0]["localTime"] == "2026-06-17 22:14:32"
      and addon_pulls[0]["pullTimeDiff"] == -2.34)

# ---- end to end: prepuller resolution --------------------------------------
events = pr.parse_events(LOG.splitlines())
pulls = pr.detect_pulls(events, window=10.0, post=15.0)
check("one pull per ENCOUNTER_START", len(pulls) == 2)

lura = pulls[0]
check("lura: encounter id", lura.encounter_id == 3183)
check("lura: engaged unit named", lura.engaged_unit == "L'ura")
check("lura: trigger is the Earthbind debuff", lura.trigger_spell == "Earthbind")
check("lura: puller resolved to a player", lura.puller is not None and lura.puller.is_player)
check("lura: puller is the TOTEM OWNER, not the totem",
      lura.puller.name == "Torm-Drak'thul-EU")
check("lura: attributed via the totem", lura.puller.via_summon == "Earthbind Totem")
check("lura: raw source was the totem (not a player)", lura.puller.raw_name == "Unknown")

gate = pulls[1]
check("boss2: direct melee pull resolves the swinger",
      gate.puller is not None and gate.puller.name == "Tankzor-Drak'thul-EU")
check("boss2: no summon chain for a direct pull", gate.puller.via_summon is None)

# ---- isolated early debuff must NOT be blamed (real-log regression) ---------
# A Hunter's Mark lands 12.5s before the pull; then nothing until the real pull
# burst (a Fireball) right before ENCOUNTER_START. The puller is the burst, not
# the stray early debuff -- this is the exact mistake the Belo'ren log exposed.
LOG_GAP = """\
6/1/2026 20:00:00.0000  SPELL_CAST_SUCCESS,Player-9-0000AAAA,"Marksman-Realm",0x511,0x0,Creature-0-1-2-3-5000-0000110001,"Boss",0x10a48,0x0,1130,"Hunter's Mark",0x1
6/1/2026 20:00:00.0000  SPELL_AURA_APPLIED,Player-9-0000AAAA,"Marksman-Realm",0x511,0x0,Creature-0-1-2-3-5000-0000110001,"Boss",0x10a48,0x0,1130,"Hunter's Mark",0x1,DEBUFF
6/1/2026 20:00:12.5000  SPELL_DAMAGE,Player-9-0000BBBB,"Puller-Realm",0x511,0x0,Creature-0-1-2-3-5000-0000110001,"Boss",0x10a48,0x0,133,"Fireball",0x4,5000,5000,0,0,0,0,nil,nil,nil
6/1/2026 20:00:12.7000  ENCOUNTER_START,4000,"Test Gap Boss",16,20,2913
6/1/2026 20:00:13.2000  SPELL_DAMAGE,Player-9-0000BBBB,"Puller-Realm",0x511,0x0,Creature-0-1-2-3-5000-0000110001,"Boss",0x10a48,0x0,133,"Fireball",0x4,5000,5000,0,0,0,0,nil,nil,nil
"""
gap_events = pr.parse_events(LOG_GAP.splitlines())
gp = pr.detect_pulls(gap_events, window=15.0)[0]   # both actions inside the 15s window
check("gap: blames the burst, not the isolated early debuff",
      gp.puller is not None and gp.puller.name == "Puller-Realm")
check("gap: trigger is the real pulling spell", gp.trigger_spell == "Fireball")
# Widening the gap past the 12.5s lull *would* reach back to the early debuff,
# proving --gap is what separates them (and that the debuff is still parsed).
gp_wide = pr.detect_pulls(gap_events, window=15.0, gap=999.0)[0]
check("gap: a huge --gap reverts to the earliest action (control)",
      gp_wide.puller is not None and gp_wide.puller.name == "Marksman-Realm")

# ---- merge with addon timing -----------------------------------------------
pr.merge_timing(pulls, addon_pulls)
check("lura: addon timing merged in", lura.timing_source == "OppositeQOL"
      and abs((lura.timing_diff or 0) + 2.34) < 1e-9)
check("boss2: no addon record -> no timing", gate.timing_source is None)

# ---- console rendering (color off for stable substring checks) -------------
text = pr.render_text(pulls, "WoWCombatLog.txt", color=False)
check("report shows WHO (the real prepuller)", "Torm-Drak'thul-EU" in text)
check("report shows WHEN (timestamp)", "2026-06-17 22:14:32" in text)
check("report shows WHICH ABILITY (and the totem behind it)",
      "using Earthbind (Earthbind Totem)" in text)
check("report shows the early timing", "2.34s EARLY" in text)
check("no vestigial 'addon saw [Unknown]' line (addon records no puller guess)",
      "addon saw" not in text)
check("report has a leaderboard when there are several pulls", "Prepull leaderboard" in text)
check("log-only pull (no addon timing) omits the timing noise",
      "timing n/a" not in pr.render_text([gate], "x", color=False))
check("unresolved pull is shown plainly, not blamed",
      "no pre-pull action" in pr.render_text(
          [pr.Pull(ts=pulls[0].ts, encounter_id=1, encounter_name="x")], "x", color=False))

# --last shows only the most recent pull, and drops the (now pointless) leaderboard
last_only = pr.render_text(pulls[-1:], "WoWCombatLog.txt", color=False)
check("--last shows the most recent pull only",
      "Tankzor-Drak'thul-EU" in last_only and "Torm-Drak'thul-EU" not in last_only)
check("--last drops the single-entry leaderboard", "leaderboard" not in last_only)

js = pr.render_json(pulls)
check("json output is valid + names puller", '"Torm-Drak\'thul-EU"' in js or "Torm-Drak" in js)

# ---- file discovery (zero-arg ergonomics) ----------------------------------
# Build a fake WoW tree and confirm the log + SavedVariables are found by shape,
# so `python3 prepull_report.py` with no paths can locate both itself.
with tempfile.TemporaryDirectory() as _root:
    flavor = os.path.join(_root, "_retail_")
    logs_dir = os.path.join(flavor, "Logs")
    sv_dir = os.path.join(flavor, "WTF", "Account", "ACC#1", "SavedVariables")
    nested = os.path.join(flavor, "Interface", "AddOns", "OppositeQOL", "tools")
    for d in (logs_dir, sv_dir, nested):
        os.makedirs(d)
    old_log = os.path.join(logs_dir, "WoWCombatLog-010125_000000.txt")
    new_log = os.path.join(logs_dir, "WoWCombatLog-020125_000000.txt")
    sv_file = os.path.join(sv_dir, "OppositeQOL.lua")
    for p in (old_log, new_log, sv_file):
        with open(p, "w") as fh:
            fh.write("x")
    os.utime(old_log, (1000, 1000))
    os.utime(new_log, (2000, 2000))   # newer -> should win

    check("flavor dir recognized by Logs/ + WTF/", pr._is_wow_flavor_dir(flavor))
    check("resolve from the install root finds _retail_",
          pr._resolve_flavor_dir(_root) == flavor)
    check("resolve from the flavor dir returns it",
          pr._resolve_flavor_dir(flavor) == flavor)
    check("ascend from a nested dir finds the flavor dir",
          pr._ascend_for_flavor_dir(nested) == flavor)
    check("explicit --wow path wins", pr.find_wow_dir(explicit=flavor) == flavor)
    check("a --sv path locates the WoW dir (so newest-log works from --sv alone)",
          pr.find_wow_dir(sv_hint=sv_file) == flavor)
    check("newest combat log is picked", pr.find_latest_log(flavor) == new_log)
    check("savedvariables located across accounts",
          pr.find_savedvariables(flavor) == sv_file)
    check("no log dir -> None", pr.find_latest_log(os.path.join(_root, "_classic_")) is None)

    # ---- saved settings (`--save` / set-once config) -----------------------
    import argparse as _argparse
    cfg = os.path.join(_root, "config.json")
    _orig_config_path = pr._config_path
    pr._config_path = lambda: cfg
    try:
        check("config: missing file reads as empty", pr.load_config() == {})
        pr.save_config({"wow_dir": flavor, "sv": sv_file, "blank": ""})
        loaded = pr.load_config()
        check("config: round-trips wow_dir + sv",
              loaded.get("wow_dir") == flavor and loaded.get("sv") == sv_file)
        check("config: empty values are dropped on save", "blank" not in loaded)
        check("config: feeds find_wow_dir via config_dir",
              pr.find_wow_dir(config_dir=flavor) == flavor)
        check("config: explicit --wow still overrides the saved config",
              pr.find_wow_dir(explicit=flavor,
                              config_dir=os.path.join(_root, "does-not-exist")) == flavor)
        # `--save` with only --sv derives the WoW folder from the SV file's path.
        saved = pr._settings_to_save(_argparse.Namespace(wow=None, sv=sv_file), None)
        check("config: _settings_to_save derives wow_dir from --sv",
              saved.get("wow_dir") == flavor and saved.get("sv") == os.path.abspath(sv_file))
    finally:
        pr._config_path = _orig_config_path

print("\nALL TESTS PASSED" if _ok else "\nSOME TESTS FAILED")
sys.exit(0 if _ok else 1)
