# mpvpp Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. (This session uses superpowers:subagent-driven-development — fresh subagent per task + review.)

**Goal:** Build the `mpvpp` mpv Lua script that records last playback position and prompts resume/beginning/skip, per the validated design in `docs/plans/2026-06-28-mpvpp-design.md`.

**Architecture:** Pure, side-effect-free logic lives in `lib/*.lua` modules (unit-tested under plain `lua` 5.1 with a tiny home-grown harness). All mpv-API contact (events, properties, OSD, key bindings, file IO, JSON) lives in `main.lua` and is verified with a manual mpv checklist. Dependency injection lets `lib/store.lua` be tested with an in-memory fs + stub JSON.

**Tech Stack:** Lua 5.1 (mpv runtime is LuaJIT/5.1-compatible), mpv 0.35 scripting API (`mp`, `mp.utils`, `mp.msg`, OSD/ASS, `mp.add_forced_key_binding`, `script-message`). No external/luarocks dependencies at runtime or test time.

**Read first:** `docs/plans/2026-06-28-mpvpp-design.md` (full design + decision rationale).

---

## Conventions

- **Lua version:** target 5.1 (no native bitwise operators, no `goto`, no integer type). Pure-arithmetic where bit math is needed.
- **Module style:** every `lib/*.lua` returns a table `M` of pure functions; **no `require('mp')` inside `lib/`**. That keeps them runnable under bare `lua`.
- **Run tests:** from repo root, `lua test/run.lua` (exit 0 = all pass, non-zero = failure).
- **Commit cadence:** commit after each task's tests pass. Conventional-commit style (`feat:`, `test:`, `chore:`). Footer on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01T2B61KMALr11zXf2F1vxoq
  ```
- **TDD:** write the failing test, run it red, implement minimal, run it green, commit.

### Known v1 simplification (flagged for the maintainer)

The design says local-file identity "resolves symlinks." mpv's `mp.utils` has **no canonicalize/realpath**, and resolving symlinks would require a subprocess spawn (against the "zero-spawn" decision). **v1 uses pure absolute-path normalization** (prepend cwd if relative, collapse `.`/`..`), **without** symlink resolution. Tracked in `lib/paths.lua` as a TODO; revisit if it ever bites (e.g. the same file reached via two symlink paths getting two entries).

---

## Module / file layout

```
main.lua                 -- mpv entry + glue (manual test)
lib/md5.lua              -- pure-arithmetic md5 -> 32-char hex
lib/url.lua              -- is_url, normalize_url
lib/timecode.lua         -- parse_finished_at, near_end, format_hms
lib/config.lua           -- DEFAULTS, parse_conf, coerce/validate, merge
lib/paths.lua            -- absolute_path, ancestor_dirs, config_files_for, store_filename
lib/store.lua            -- load/save/clear (deps injected: fs + json)
config.example.conf      -- documented sample config
input.conf.example       -- sample reset keybindings
test/harness.lua         -- ~40-line assert/report harness
test/run.lua             -- sets package.path, requires test files, reports
test/test_*.lua          -- one per lib module
docs/plans/...           -- design + this plan
```

`main.lua` sets `package.path` from `mp.get_script_directory()` at startup so `require('lib.x')` resolves both in mpv and in tests.

---

## Task 0: Test harness

**Files:**
- Create: `test/harness.lua`
- Create: `test/run.lua`
- Create: `test/test_smoke.lua`

**Step 1 — harness.lua** (zero deps):

```lua
-- test/harness.lua : minimal assert + report harness
local M = { pass = 0, fail = 0, failures = {} }

local function show(v)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do parts[#parts+1] = tostring(k).."="..tostring(val) end
    return "{"..table.concat(parts, ", ").."}"
  end
  return tostring(v)
end

function M.eq(actual, expected, msg)
  if actual == expected then M.pass = M.pass + 1
  else
    M.fail = M.fail + 1
    M.failures[#M.failures+1] = string.format(
      "%s\n    expected: %s\n    actual:   %s", msg or "eq", show(expected), show(actual))
  end
end

function M.ok(cond, msg)
  if cond then M.pass = M.pass + 1
  else M.fail = M.fail + 1; M.failures[#M.failures+1] = msg or "expected truthy" end
end

function M.report()
  print(string.format("\n%d passed, %d failed", M.pass, M.fail))
  for _, f in ipairs(M.failures) do print("  FAIL: "..f) end
  os.exit(M.fail > 0 and 1 or 0)
end

return M
```

**Step 2 — run.lua:**

```lua
-- test/run.lua : run from repo root with `lua test/run.lua`
package.path = "./?.lua;" .. package.path
local files = {
  "test.test_smoke",
  -- append modules as tasks land:
  -- "test.test_md5", "test.test_url", "test.test_timecode",
  -- "test.test_config", "test.test_paths", "test.test_store",
}
for _, mod in ipairs(files) do require(mod) end
require("test.harness").report()
```

**Step 3 — test_smoke.lua:**

```lua
local T = require("test.harness")
T.eq(1 + 1, 2, "sanity")
```

**Step 4 — run:** `lua test/run.lua` → expect `1 passed, 0 failed`, exit 0.

**Step 5 — commit:** `test: add zero-dependency lua test harness`

---

## Task 1: `lib/md5.lua` (pure-arithmetic md5)

**Why:** filename-safe stable key for the store. Must run under Lua 5.1 with **no `bit`/`bit32` dependency**.

**Files:** Create `lib/md5.lua`, `test/test_md5.lua`. Register `"test.test_md5"` in `run.lua`.

**Step 1 — failing tests (RFC 1321 known-answer vectors):**

```lua
local T = require("test.harness")
local md5 = require("lib.md5")
T.eq(md5.sum(""),    "d41d8cd98f00b204e9800998ecf8427e", "md5 empty")
T.eq(md5.sum("a"),   "0cc175b9c0f1b6a831c399e269772661", "md5 a")
T.eq(md5.sum("abc"), "900150983cd24fb0d6963f7d28e17f72", "md5 abc")
T.eq(md5.sum("message digest"), "f96b697d7cb7938d525a2f31aaf161d0", "md5 message digest")
T.eq(md5.sum("The quick brown fox jumps over the lazy dog"),
            "9e107d9d372bb6826bd81d3542a419d6", "md5 fox")
```

**Step 2 — run red:** `lua test/run.lua` → FAIL (module missing).

**Step 3 — implement** `lib/md5.lua`: a self-contained md5 returning lowercase hex. Implement 32-bit bitwise helpers via arithmetic (`band`/`bor`/`bxor`/`bnot`/`lshift`/`rshift`/`rol`) operating on numbers mod 2^32, then the standard RFC 1321 rounds. Return `{ sum = function(s) ... end }`. **Do not** assume `bit`/`bit32`/`#` integer ops. Iterate against the vectors until green. (Reference: RFC 1321; structure = pad message, process 512-bit blocks, four rounds of 16 ops, little-endian output.)

**Step 4 — run green:** all 5 vectors pass.

**Step 5 — commit:** `feat: add pure-lua md5`

---

## Task 2: `lib/url.lua`

**Files:** Create `lib/url.lua`, `test/test_url.lua`. Register in `run.lua`.

**Step 1 — failing tests:**

```lua
local T = require("test.harness")
local url = require("lib.url")

-- is_url
T.eq(url.is_url("https://youtu.be/abc"), true,  "https is url")
T.eq(url.is_url("http://x/y"),           true,  "http is url")
T.eq(url.is_url("ytdl://x"),             true,  "scheme is url")
T.eq(url.is_url("/home/guy/v.mkv"),      false, "abs path not url")
T.eq(url.is_url("rel/v.mkv"),            false, "rel path not url")

-- normalize_url (Plan A): lowercase host, strip www., strip volatile params, trim trailing /
local n = url.normalize_url
T.eq(n("https://www.youtube.com/watch?v=abc123"),
     n("https://www.youtube.com/watch?v=abc123&t=42s"),  "strip t=")
T.eq(n("https://www.youtube.com/watch?v=abc123"),
     n("https://www.youtube.com/watch?v=abc123&list=PLx&index=3"), "strip list/index")
T.eq(n("https://WWW.YouTube.com/watch?v=abc123"),
     n("https://youtube.com/watch?v=abc123"), "lowercase host + strip www")
T.eq(n("https://example.com/video/"),
     n("https://example.com/video"), "trim trailing slash")
-- keep a meaningful param
T.ok(n("https://x.com/w?v=a") ~= n("https://x.com/w?v=b"), "keep v=")
```

**Step 2 — run red.**

**Step 3 — implement:**
- `is_url(s)` → `s:match("^%a[%w+.%-]*://") ~= nil`.
- `normalize_url(u)`: split into scheme, host, path, query. Lowercase scheme+host; strip leading `www.`; trim trailing `/` from path (keep root `/`); drop query params whose key ∈ `{t,start,list,index,feature,si}` (extensible set as a local table); re-sort remaining params for stable ordering; reassemble. No external deps — hand-roll the split with `string.match`/`gmatch`.

**Step 4 — run green. Step 5 — commit:** `feat: add url identity + plan-a normalization`

---

## Task 3: `lib/timecode.lua`

**Files:** Create `lib/timecode.lua`, `test/test_timecode.lua`. Register in `run.lua`.

**Step 1 — failing tests:**

```lua
local T = require("test.harness")
local tc = require("lib.timecode")

-- parse_finished_at -> {kind="abs", secs=N} | {kind="frac", frac=F}
local p = tc.parse_finished_at
T.eq(p("97%").kind, "frac", "percent kind");  T.eq(p("97%").frac, 0.97, "percent val")
T.eq(p("0.97").kind, "frac", "fraction kind"); T.eq(p("0.97").frac, 0.97, "fraction val")
T.eq(p("15s").kind,  "abs",  "secs kind");     T.eq(p("15s").secs, 15, "secs val")
T.eq(p("2m").secs,   120, "2m")
T.eq(p("1m30s").secs, 90, "1m30s")
T.eq(p("1:30").secs,  90, "mm:ss")
T.eq(p("1:02:03").secs, 3723, "hh:mm:ss")
T.eq(p("15").kind, "abs", "bare>=1 is secs"); T.eq(p("15").secs, 15, "bare 15")
T.eq(p("90").secs, 90, "bare 90")

-- near_end(pos, duration, parsed)
local ne = tc.near_end
T.eq(ne(1370, 1380, p("15s")), true,  "abs within margin")
T.eq(ne(1300, 1380, p("15s")), false, "abs outside margin")
T.eq(ne(1360, 1380, p("97%")), true,  "frac past threshold")  -- 1360/1380=0.985
T.eq(ne(1300, 1380, p("97%")), false, "frac under threshold") -- 0.942
T.eq(ne(500, 0,    p("97%")), false, "unknown duration never finished")
T.eq(ne(500, -1,   p("15s")), false, "live never finished")

-- format_hms(seconds) -> "H:MM:SS" or "M:SS"
T.eq(tc.format_hms(92),   "1:32",    "m:ss")
T.eq(tc.format_hms(3723), "1:02:03", "h:mm:ss")
T.eq(tc.format_hms(5),    "0:05",    "pads seconds")
```

**Step 2 — run red. Step 3 — implement** the three functions per the design's grammar table (precedence: `%` → frac; unit/`:` → abs; bare `<1` → frac; bare `>=1` → abs secs). `near_end` guards `duration <= 0` → false. **Step 4 — green. Step 5 — commit:** `feat: add timecode parsing + near-end detection`

---

## Task 4: `lib/config.lua`

**Files:** Create `lib/config.lua`, `test/test_config.lua`. Register in `run.lua`.

**Schema (single source of truth in this module):**

```lua
local SCHEMA = {
  record_position   = { type = "bool",  default = true },
  show_prompt       = { type = "bool",  default = true },
  cli_prompt_only   = { type = "bool",  default = false },
  no_ui_fallback    = { type = "enum",  default = "resume",
                        values = { resume = true, force_window = true, beginning = true } },
  save_interval     = { type = "number", default = 5 },
  min_position      = { type = "number", default = 30 },
  finished_at       = { type = "string", default = "97%" },   -- parsed by timecode at use
  finished_behavior = { type = "enum",  default = "play_from_beginning",
                        values = { skip = true, play_from_beginning = true } },
}
```

**Step 1 — failing tests:**

```lua
local T = require("test.harness")
local cfg = require("lib.config")

-- defaults()
T.eq(cfg.defaults().record_position, true, "default record")
T.eq(cfg.defaults().finished_at, "97%", "default finished_at")

-- parse_conf(text, on_warn) -> table of validated values (only keys present)
local warns = {}
local function warn(m) warns[#warns+1] = m end
local got = cfg.parse_conf([[
# comment
; also comment
record_position = no
finished_at = 15s
no_ui_fallback = beginning
save_interval = 10
bogus_key = 1
no_ui_fallback_typo = nope
]], warn)
T.eq(got.record_position, false, "yes/no -> bool")
T.eq(got.finished_at, "15s", "string passthrough")
T.eq(got.no_ui_fallback, "beginning", "valid enum")
T.eq(got.save_interval, 10, "number coercion")
T.eq(got.bogus_key, nil, "unknown key skipped")
T.ok(#warns >= 1, "unknown key warned")

-- bad enum value -> warn + omit (caller keeps prior via merge)
local w2 = {}
local g2 = cfg.parse_conf("no_ui_fallback = wat\n", function(m) w2[#w2+1]=m end)
T.eq(g2.no_ui_fallback, nil, "bad enum omitted")
T.ok(#w2 >= 1, "bad enum warned")

-- merge(base, override) shallow
local merged = cfg.merge({a=1, b=2}, {b=3, c=4})
T.eq(merged.a, 1, "base kept"); T.eq(merged.b, 3, "override wins"); T.eq(merged.c, 4, "new key")
```

**Step 2 — run red. Step 3 — implement:**
- `defaults()` → fresh table from SCHEMA defaults.
- `parse_conf(text, on_warn)`: iterate lines, skip blanks + `#`/`;`; split on first `=`; trim; look up SCHEMA; coerce by type (`bool`: yes/true/1→true, no/false/0→false; `number`: `tonumber`; `enum`: must be in `values`; `string`: as-is). On unknown key or bad value → call `on_warn` + skip. Return only present+valid keys.
- `merge(base, over)`: shallow copy base, overlay over.

**Step 4 — green. Step 5 — commit:** `feat: add config schema, parser, merge`

---

## Task 5: `lib/paths.lua`

**Files:** Create `lib/paths.lua`, `test/test_paths.lua`. Register in `run.lua`.

**Step 1 — failing tests:**

```lua
local T = require("test.harness")
local P = require("lib.paths")

-- absolute_path(path, cwd) : pure; prepend cwd if relative; collapse . and ..
T.eq(P.absolute_path("/a/b/c.mkv", "/home/guy"), "/a/b/c.mkv", "already abs")
T.eq(P.absolute_path("rel/c.mkv", "/home/guy"), "/home/guy/rel/c.mkv", "relative")
T.eq(P.absolute_path("/a/b/../c", "/x"), "/a/c", "collapse ..")
T.eq(P.absolute_path("/a/./b", "/x"), "/a/b", "collapse .")

-- ancestor_dirs("/path/to/some/movie.mkv") root->parent, EXCLUDING the file itself
local d = P.ancestor_dirs("/path/to/some/movie.mkv")
T.eq(d[1], "/path", "first ancestor")
T.eq(d[2], "/path/to", "second")
T.eq(d[3], "/path/to/some", "parent last")
T.eq(#d, 3, "three ancestors")

-- config_files_for(abspath, conf_name) appends conf_name to each ancestor dir
local cf = P.config_files_for("/path/to/some/movie.mkv", "mpvpp.conf")
T.eq(cf[1], "/path/mpvpp.conf", "first conf path")
T.eq(cf[#cf], "/path/to/some/mpvpp.conf", "parent conf path")

-- store_filename(hash) -> hash .. ".json"
T.eq(P.store_filename("abc"), "abc.json", "store filename")
```

**Step 2 — run red. Step 3 — implement** the four pure functions (string manipulation only; `ancestor_dirs` splits on `/`, builds cumulative prefixes excluding the basename). Add a `-- TODO(v1): no symlink resolution; see plan "Known v1 simplification"` comment in `absolute_path`. **Step 4 — green. Step 5 — commit:** `feat: add path + config-cascade helpers`

---

## Task 6: `lib/store.lua` (dependency-injected)

**Files:** Create `lib/store.lua`, `test/test_store.lua`. Register in `run.lua`.

**Design:** `store.new(deps)` where `deps = { dir, read_file, write_file, rename, exists, json_encode, json_decode }`. Returns `{ load(key), save(key, data), clear(key) }`. In tests, inject an in-memory fs table + identity-ish JSON stub (encode = a tagging function, decode = inverse) so we test *logic*, not real JSON.

**Step 1 — failing tests:**

```lua
local T = require("test.harness")
local store = require("lib.store")

-- in-memory fs + round-trippable stub json
local function mkfs()
  local files = {}
  return files, {
    dir = "/state",
    read_file = function(p) return files[p] end,
    write_file = function(p, s) files[p] = s; return true end,
    rename = function(a, b) files[b] = files[a]; files[a] = nil; return true end,
    exists = function(p) return files[p] ~= nil end,
    json_encode = function(t) return t end,        -- stub: pass table through
    json_decode = function(s) return s end,        -- stub: identity
  }
end

local files, deps = mkfs()
local s = store.new(deps)
T.eq(s.load("k1"), nil, "missing key -> nil")
s.save("k1", { position = 42 })
T.eq(s.load("k1").position, 42, "save then load")
T.ok(files["/state/k1.json"] ~= nil, "writes to dir/<key>.json")
T.eq(files["/state/k1.json.tmp"], nil, "tmp renamed away (atomic)")
s.clear("k1")
T.eq(s.load("k1"), nil, "clear removes")
```

**Step 2 — run red. Step 3 — implement:**
- `save`: `write_file(dir/key.json.tmp, json_encode(data))` then `rename(...tmp, dir/key.json)` (atomic).
- `load`: if `exists(dir/key.json)` → `json_decode(read_file(...))` else nil.
- `clear`: write nil / remove (in real fs main injects an `os.remove`-backed remover; in stub, `rename` to nowhere or set nil — implement `clear` via a `deps.remove` with fallback to `write_file(path, nil)`; adjust deps + test accordingly).

**Step 4 — green. Step 5 — commit:** `feat: add injectable position store`

---

## Task 7: `main.lua` (mpv glue — manual verification)

No unit tests (requires mpv runtime). Build incrementally; **after each sub-step, load in mpv and check the relevant checklist item** (Task 9). Commit per sub-step.

**File:** Create `main.lua`.

**7a — bootstrap + config cascade.**
- At top: `local sdir = mp.get_script_directory(); if sdir then package.path = sdir.."/?.lua;"..package.path end`.
- `require` all libs + `mp`, `mp.utils`, `mp.msg`.
- Load merged config: `cfg = config.defaults()`; merge user `~/.config/mpvpp/config.conf` (expand `~` via `os.getenv("HOME")`); then for local files only, for each path in `paths.config_files_for(abspath, "mpvpp.conf")` that exists, `config.merge(cfg, config.parse_conf(read, warn))`. Memoize parsed config files by path within the run.
- Commit: `feat: main bootstrap + config cascade`

**7b — identity + store wiring.**
- `media_key()`: read `mp.get_property("path")`; if `url.is_url` → `md5.sum(url.normalize_url(path))` else `md5.sum(paths.absolute_path(path, utils.getcwd()))`.
- Wire `store.new` with real deps: `read_file`/`write_file` via `io.open`, `rename`/`remove` via `os`, `exists` via `utils.file_info`, `json_encode/decode` via `utils.format_json`/`utils.parse_json`. `dir = ~/.local/state/mpvpp` (create via `utils.mkdir`? mpv lacks mkdir → use `os.execute("mkdir -p ...")` ONCE at init — note: this is the one allowed spawn, at startup only, or use `mp.command_native({"subprocess",...})`; document it).
- Commit: `feat: identity + store wiring`

**7c — lifecycle skeleton.**
- `mp.register_event("file-loaded", on_load)`. In `on_load`: rebuild cfg cascade for this file; if not `cfg.record_position` → return; compute key; `saved = store.load(key)`; `duration = mp.get_property_number("duration")`; `finished = saved and tc.near_end(saved.position, duration, tc.parse_finished_at(cfg.finished_at))`; branch to finished-flow (7f) or resume-flow (7d). Log decisions via `mp.msg`.
- Commit: `feat: file-loaded lifecycle skeleton`

**7d — prompt module (resume).**
- Channel: `cli = cfg.cli_prompt_only or not mp.get_property_bool("vo-configured")`. If channel is CLI but no terminal (`not mp.get_property_bool("terminal")`) → apply `no_ui_fallback`.
- Window-settle: if choosing OSD and `vo-configured` is not yet true, `mp.observe_property("vo-configured", "bool", ...)` once, then show.
- Pause on prompt (`mp.set_property_bool("pause", true)`), show choices (skip if `saved.position < cfg.min_position` → silent beginning; skip if `not cfg.show_prompt` → silent resume; skip if `session.progress_action` set → apply it).
- `PROMPT_KEYS` declarative table; `render_prompt(state)` (OSD via `mp.set_osd_ass`; terminal via `print`); `handle_key` resolves action (`resume` → `mp.set_property_number("time-pos", saved.position)`; `beginning` → start at 0), sets `session.progress_action` if remember, unbinds keys, unpauses, clears OSD.
- Commit: `feat: resume prompt (osd + terminal)`

**7e — save loop.**
- `mp.observe_property("time-pos", "number", on_tick)`; throttle writes to ≥ `cfg.save_interval` apart (track last write time via `os.time()`); store `{ source, position, duration, title=mp.get_property("media-title"), play_count, updated=os.time(), last_watch_timestamp=os.time() }`.
- Final save on `end-file` and `shutdown`. Bump `play_count` once per loaded file. **Never clear** here.
- Commit: `feat: throttled + final position saving`

**7f — finished handling.**
- If `finished`: bypass resume prompt. If `not cfg.show_prompt` or `session.finished_action` set → apply directly. Else show finished prompt (Skip / Beginning / `[x]` rewatch). `skip` → `mp.commandv("playlist-next", "force")`; **if no next entry** (`playlist-pos == playlist-count-1`) → fall back to play_from_beginning. `beginning` → start at 0. Set `session.finished_action` if remember.
- Commit: `feat: finished handling + skip/restart + no-next fallback`

**7g — reset.**
- `mp.register_script_message("mpvpp-reset-file", reset_current_file)` → `store.clear(media_key())`.
- `mp.register_script_message("mpvpp-reset", reset_folder)` → for each current-playlist entry whose directory == current file's directory, clear its key; then restart current from beginning.
- Finished prompt `[x]` → calls `reset_folder`.
- Commit: `feat: reset (file + folder via playlist) script messages`

---

## Task 8: Sample config + docs

**Files:** Create `config.example.conf`, `input.conf.example`; update `README.md`.

- `config.example.conf`: every key from SCHEMA, commented, with the design's defaults.
- `input.conf.example`:
  ```
  # add to ~/.config/mpv/input.conf
  Alt+r script-message mpvpp-reset        # clear this folder's progress + restart
  Alt+R script-message mpvpp-reset-file   # clear just this file
  ```
- README: flip "design phase" → "usage", document install (submodule), config keys, reset bindings.
- Commit: `docs: sample config, input bindings, README usage`

---

## Task 9: Manual mpv test checklist

**File:** Create `docs/manual-test-checklist.md`. Run each against real mpv 0.35.1 and check off. Test media: a short local clip, an audio-only file (with + without cover art), and a YouTube URL.

1. Local video, no saved pos → no prompt, plays from start; quit mid-way; replay → **resume prompt on OSD overlay**; `r` resumes, `b` restarts.
2. `cli_prompt_only = yes` → prompt appears in **terminal**, not OSD.
3. Audio-only **with** cover art → `vo-configured` true → **OSD** prompt (per design: album art counts).
4. Audio-only **no** window, launched from terminal → **terminal** prompt.
5. Audio-only no window, launched detached (no terminal) → applies `no_ui_fallback` (test `resume`/`beginning`/`force_window`).
6. `m` toggles checkbox (OSD re-renders; terminal reprints); `R`/`B` accelerators set session memory; next playlist file auto-applies without prompting.
7. Finished file (seek past `finished_at`, quit) → replay shows **finished prompt**; `s` skips to next; on last/single entry skip → **falls back to play-from-beginning** (no quit).
8. `finished_behavior = skip` over a season dir: watched eps skipped, lands on first in-progress.
9. yt-dlp URL: resume works; `?v=…&t=42s` and bare `?v=…` resolve to the **same** saved position.
10. Per-dir `mpvpp.conf` override (drop `finished_at = 15s` in a folder) takes effect; unknown key logs a warn.
11. Reset: `Alt+R`/`Alt+r` bindings clear file/folder; finished prompt `[x]` clears folder + restarts.
12. Hard `kill -9` mid-play → relaunch resumes within `save_interval` seconds of where you were.

- Commit (after run, noting results inline): `docs: manual mpv test checklist (verified)`

---

## Task 10: Wire into dotfiles as submodule

**REQUIRED SKILL:** use `dotfiles-manager` for this task.

- Add the mpvpp repo as a git submodule at `dotfiles/packages/mpv/.config/mpv/scripts/mpvpp`.
- Confirm `~/.config/mpv/scripts/mpvpp/main.lua` resolves (the dotfiles mpv package is already stowed/symlinked to `~/.config/mpv`).
- Launch mpv, confirm script loads (no errors in `mpv --msg-level=all=v` / script console), re-run a couple checklist items end-to-end through the real install path.
- Commit in the dotfiles repo (its own history): `feat: add mpvpp playback-position script as submodule`.

---

## Done criteria

- `lua test/run.lua` → all green (Tasks 0–6).
- Manual checklist (Task 9) all checked against mpv 0.35.1.
- Submodule loads from the real `~/.config/mpv/scripts/mpvpp/` path.
- `record_position`, `show_prompt`, `cli_prompt_only`, `no_ui_fallback`, `finished_at`, `finished_behavior`, per-dir cascade, session memory, and reset all verified.
