# mpvpp — mpv Playback Position — Design

**Date:** 2026-06-28
**Status:** Design validated, ready for implementation planning
**Repo:** `~/code/git/github.com/shitchell/mpvpp` (standalone), wired into dotfiles as a git submodule at `packages/mpv/.config/mpv/scripts/mpvpp/`

---

## 1. Purpose

Record and restore the last playback position (PP) for media played in `mpv`, with a
prompt to choose **Resume** vs **Play from beginning**, a per-session "remember" toggle,
finished-item handling (skip / restart), and a layered, per-directory config system.

This is a *layer on top of* mpv's built-in resume (`save-position-on-quit` / `watch_later`).
We write our own state store rather than reuse mpv's, because we need extra metadata and
our own prompt + session semantics.

### Why not just mpv's built-in resume?

mpv already hashes the file path/URL into `watch_later` and auto-resumes. What it lacks —
and what this project adds — is: an interactive prompt (resume vs beginning), per-session
memory, finished-state handling (skip seen episodes), and per-directory configuration.

---

## 2. Architecture

A single idiomatic mpv Lua **script directory** loaded from
`~/.config/mpv/scripts/mpvpp/` (entry point `main.lua`, per mpv's script-directory
convention). **No external binaries, no bundled libraries** — only mpv built-ins:
`mp`, `mp.utils`, `mp.msg`, OSD/ASS APIs, and a tiny pure-Lua `md5`.

Decision (rationale: user) — **idiomatic mpv only.** "nah, just idiomatic. built-in mpv
stuff." No GUI toolkit dependency (zenity/yad/etc.).

Four internal pieces, one script:

1. **Identity** — current media → stable key.
2. **Store** — one small JSON file per media, keyed by hash.
3. **Config** — built-in defaults → user config → per-directory cascade.
4. **Prompt** — OSD overlay or terminal, with declarative keymap.

### Lifecycle (per `file-loaded`)

```
file-loaded
  → compute identity (key)
  → load merged config (defaults → user → dir cascade)
  → if not record_position: return (inert)
  → load saved state for key
  → derive finished = near_end(saved.position, duration, finished_at)
  → if finished:  finished-prompt / finished_behavior  (Section 6)
    else:         resume-prompt / resume flow           (Section 5)
during playback:
  → throttled periodic position save (save_interval)
on end-file / shutdown:
  → final position save  (NEVER auto-clear — Section 7)
```

---

## 3. Identity (source identification)

Called at `file-loaded` to produce the storage key.

- **Local file** → resolve symlinks → absolute path → `md5`.
- **URL / yt-dlp** → take mpv's `path` property (the *original* URL, before yt-dlp
  rewrites it to a tokenized CDN URL) → **light generic normalization** → `md5`.

### URL normalization (Plan A — generic, low-maintenance)

Decision (rationale: user picked "A seems fine enough") — generic normalization, **not**
site-aware canonical IDs (too much maintenance) and **not** raw URLs (would split the same
video across `&t=`, `youtu.be`, `&list=` variants).

Steps:
- lowercase host
- strip leading `www.`
- strip a known-volatile param set: `t`, `start`, `list`, `index`, `feature`, `si`, …
- trim trailing `/`

So these collapse to one key:

```
https://www.youtube.com/watch?v=abc123
https://www.youtube.com/watch?v=abc123&t=42s
https://www.youtube.com/watch?v=abc123&list=PLxxxx
https://youtu.be/abc123          (host/short-form normalized)
```

`md5` is a tiny pure-Lua implementation (zero process spawn). Decision (rationale: user
"looks good" to pure-Lua over shelling to `md5sum`).

---

## 4. Store

One JSON file per media: `~/.local/state/mpvpp/<md5>.json`.

```json
{
  "source": "<normalized path or url>",
  "position": 872.4,
  "duration": 1380.0,
  "title": "…",
  "play_count": 3,
  "updated": 1719000000,
  "last_watch_timestamp": 1719000000
}
```

- Filename is the hash; `source` kept in plaintext **inside** the file so the store is
  greppable / debuggable.
- `updated` = last write for any reason; `last_watch_timestamp` = epoch of last actual
  playback (added as future fuel for a possible recency-cursor feature — see Section 7,
  Model B).
- Reads/writes via mpv's built-in `utils.format_json` / `parse_json`.
- Writes are **atomic** (`write tmp → os.rename`) so a crash mid-write can't corrupt state.

---

## 5. Config — cascade & parsing

### Resolution order (later overrides earlier, shallow per-key merge)

```
1. DEFAULTS            (table literal in the script)
2. ~/.config/mpvpp/config.conf      (user base)
3..N. directory cascade, filesystem root → file's parent dir (closest wins)
```

Decision (rationale: user designed the cascade) — closest config to the file wins; each
later file overrides only the keys it sets.

### Directory walk (local files only)

For `file = /path/to/some/movie.mkv`, load in order (missing = no-op):

```
/mpvpp.conf
/path/mpvpp.conf
/path/to/mpvpp.conf
/path/to/some/mpvpp.conf      ← immediate parent, highest priority
```

- **Config filename in media dirs:** `mpvpp.conf`. **User base:** `~/.config/mpvpp/config.conf`.
  Both tweakable via constants at the top of the script.
- **URLs have no directory path** → they get levels 1–2 only (defaults + user config).
- **Walk scope:** filesystem root `/` down to parent; stat each, load what exists.
- **Caching:** each file's parsed result is memoized by path within one mpv run, so a
  200-file playlist in one dir doesn't re-parse the same configs 200×.

### Format & parser

Flat mpv-style `key = value` (decision rationale: user OK'd JSON or flat; flat chosen —
easiest to hand-edit, trivial dependency-free parse, matches mpv.conf feel).

```ini
# comment   (also ';')
key = value
```

- `#` / `;` comments and blank lines ignored.
- Values coerced by the key's declared type: `yes/no/true/false` → bool, numbers → number,
  enums validated against an allowed set.
- **Unknown keys → `mp.msg.warn` + skip** (typos don't silently no-op).
- **Bad values → warn + keep prior.**
- **Strictly declarative — no shell, no code eval.** A stray config in a downloaded media
  folder can only flip declared knobs, never execute anything.

### Config key reference

```ini
# --- recording & prompting ---
record_position   = yes        # master switch: record positions at all?
show_prompt       = yes        # show prompts, or act silently (resume / handle)
cli_prompt_only   = no         # force terminal prompt even when a window exists
no_ui_fallback    = resume     # audio + no terminal: resume | force_window | beginning

# --- resume tuning ---
save_interval     = 5          # throttle: write position at most every N seconds
min_position      = 30         # resume floor; below N sec → no resume prompt, start at 0

# --- finished detection & handling ---
finished_at       = 97%        # 15s | 2m | 1:30 | 1:02:03 | 97% | 0.97
finished_behavior = play_from_beginning   # skip | play_from_beginning
```

---

## 6. The prompt

### Channel selection (user's priority logic)

Decision (rationale: user refined to "is mpv rendering a GUI?") — branch on whether a
window is actually being drawn, so **album-art counts as a window** (overlay is preferable
since the window is focused above the terminal; avoids a keystroke flip-flop).

```lua
if cfg.cli_prompt_only or not mp.get_property_bool("vo-configured") then
  channel = CLI      -- terminal; rendered to stdout
else
  channel = OSD      -- ASS overlay on the window (video OR album art)
end
```

- `vo-configured` is true exactly when a rendered output window exists.
- **Timing:** at `file-loaded` the window may not be configured yet (created on first
  decoded frame). The script briefly waits for `vo-configured` to settle before deciding.
- **CLI channel but no terminal attached** (e.g. podcast launched from a file manager:
  no window, no stdout) → nowhere to prompt → apply `no_ui_fallback`:
  - `resume` (default) — silently resume. Least surprising for background audio.
  - `force_window` — set `force-window`, re-route to OSD.
  - `beginning` — silently start at 0.

### Resume prompt (in-progress media)

```
  ⏵ Resume from 14:32?

    [r] Resume        [b] Play from beginning
    [m] Remember for this session   [ ]      (accelerators: R / B)
```

### Finished prompt (media past `finished_at`)

```
  ⏹  "S02E04.mkv" — finished

    [s] Skip          [b] Play from beginning
    [m] Remember for this session   [ ]      (accelerators: S / B)
    [x] rewatch (clear this folder's progress)
```

### Toggle + accelerators model

Decision (rationale: user — wants radio + checkbox semantics from single-key inputs, plus
fast accelerators; "i might change my mind later" → keep it modular).

- `m` toggles the "Remember for session" checkbox (overlay re-renders; terminal reprints
  the toggle line) — the common case is one keystroke (`r`/`b`/`s`), remember is opt-in.
- Capital accelerators commit action **+ remember** in one press (`R`/`B`/`S`).
- `Esc` / `q` **quit mpv** (not shown as a prompt option). The saved position is
  preserved exactly as-is — the quit deliberately does *not* tear the prompt down, so
  `prompt_pending` stays set and the shutdown save is suppressed (no clobber to ~0).
  *(Supersedes the original "dismiss = safe default (resume/no-skip)" decision — see appendix.)*
- While the prompt is up, mpv is **paused on the first frame**; playback does not advance
  until a choice is made.

Keep behavior in a **declarative keymap table** so re-binding/restructuring is data, not
logic; rendering (`render_prompt`) and input (`handle_key`) stay in separate small functions.

```lua
local PROMPT_KEYS = {
  r = { action = "resume",    remember = false },
  b = { action = "beginning", remember = false },
  R = { action = "resume",    remember = true  },
  B = { action = "beginning", remember = true  },
  m = { toggle  = "remember" },
  ENTER = { action = "resume", remember = false },
}
```

### Per-state session memory

The "remember for session" result is a **script-global**, alive only for this mpv process
(matches the playlist semantics: "this session" = this one process run). It is **per-state**,
not global:

```lua
session.progress_action = nil   -- {resume|beginning}  set by the resume prompt
session.finished_action = nil   -- {skip|beginning}    set by the finished prompt
```

So "skip + remember" silently skips later **finished** items, while an in-progress ep4
still gets its **own** resume prompt. Worked example:

```
ep1 (finished)    → finished prompt → user: Skip + Remember
ep2,3 (finished)  → skipped silently
ep4 (in-progress) → resume prompt   → user: Resume
```

---

## 7. Finished handling & the rewatch problem

### "Finished" is a derived state, never a destructive action

Decision (rationale: user — "i don't think i ever ever clear the data") — we **always**
store the last position (throttled + on end-file) and **never auto-clear**. Finished-ness
is recomputed on every load from `position + duration + finished_at`. This is what lets
`finished_at` be freely toggled (even per-directory) without losing data.

```lua
local finished = near_end(saved.position, duration, cfg.finished_at)
if finished then
  -- bypass resume prompt; finished prompt / finished_behavior decides
  -- skip → playlist-next force ; play_from_beginning → start at 0
else
  -- normal resume flow
end
```

### `finished_at` value grammar (single knob, parsed by shape)

Decision (rationale: user — one setting, resolve abs-time vs percentage in code, no
two-variable conflict).

| Rule | Matches | Means |
|---|---|---|
| 1. ends with `%` | `97%`, `90%` | fraction = n / 100 |
| 2. has unit `h`/`m`/`s` or a `:` | `15s` `2m` `1m30s` `1:30` `1:02:03` `1h` | absolute seconds-from-end |
| 3. bare number `< 1` | `0.97` `0.9` | fraction |
| 4. bare number `>= 1` | `15` `90` | absolute seconds-from-end |

```lua
if kind == "abs"  then near_end = duration > 0 and pos >= duration - secs
if kind == "frac" then near_end = duration > 0 and pos / duration >= frac
-- live / unknown duration (<= 0) → never "finished"; just keep saving raw position
end
```

Default `finished_at = 97%` (scales across any length; drop `15s` in a per-dir config for
absolute).

### `finished_behavior`

Decision (rationale: user) — `skip` (advance in playlist; great for `mpv "Season 02"`) or
`play_from_beginning` (restart; great for a finished movie). Default `play_from_beginning`
(least surprising for a single double-clicked file).

**Skip with nothing to skip to** (single-file invocation, or last finished entry):
`playlist-next` would quit mpv — instead **fall back to `play_from_beginning`** (decision:
user picked option A) rather than quitting.

### The rewatch problem & resolution (Model A — explicit reset)

Problem: "finished" derived purely from position **cannot represent progression through a
rewatch.** On a first watch the boundary is crisp (watched = finished, ahead = *no data*).
On a rewatch, finishing ep3 again creates no boundary, because ep4 was *already* finished
from last time — so a relaunch skips past ep4 too. The cursor is lost.

**Chosen: Model A — explicit reset.** (Decision rationale: user — "i think the rewatch
option is reasonable :) and we can play with it as we go if needed.")

- The automatic path **never** clears (preserves `finished_at` toggle-ability).
- A **deliberate, opt-in reset** restores crisp first-watch semantics:
  - mpv keybinding via `script-message` (bound in `input.conf`):
    - `mpvpp-reset-file` → clears the current file's stored position.
    - `mpvpp-reset` → clears stored positions for every **current-playlist** entry sharing
      the current file's directory (the "season"), then restarts current from the beginning.
  - the finished prompt's `[x]` key = same as `mpvpp-reset`.
- After reset, the folder behaves like a fresh first watch — skip-remember + resume-ep4 all
  work as designed.
- The "folder group" is enumerated from the **live playlist** (entries in the same dir), so
  no separate folder index is needed in the store.

**Deferred: Model B — recency cursor.** Never-clear; use `last_watch_timestamp` to find the
most-recently-watched episode in a group at launch and skip finished items behind it,
landing on the right episode automatically (no manual reset). Rejected for v1 as a real
architectural addition (reason about the whole playlist at launch, assume playlist order ≈
episode order, tie-break timestamps). `last_watch_timestamp` is captured now so this stays
open. ("we can play with it as we go.")

---

## 8. Save / clear lifecycle (revised by Section 7)

- **Throttled periodic save:** observe `time-pos`; write at most once per `save_interval`
  (default 5s) so a hard `kill` loses at most ~5s.
- **Final save** on `end-file` and shutdown.
- **Atomic writes** (`tmp` → `os.rename`).
- **Never auto-clear** — finished is derived (Section 7). Clearing only happens via explicit
  reset.
- **Position floor:** ignore saved positions below `min_position` (default 30s) for resume
  prompting — no "resume from 8s."
- **Inert mode:** `record_position = no` for a media → neither save nor prompt.
- **Live / unknown duration:** skip percentage finished-check; keep saving raw position.

---

## 9. Open questions / future

- **Model B (recency cursor)** — possible replacement/augment for explicit reset.
- **Prompt timeout** — currently waits indefinitely (paused). A `prompt_timeout` knob could
  auto-resolve to a default after N seconds; left out of v1 (YAGNI), trivial to add given the
  modular prompt.
- **URL normalization tuning** — the volatile-param set may need per-site additions over time.

---

## Appendix — decisions & rationale (captured per user's CLAUDE.md guidance)

| Topic | Decision | Status | Rationale (user, direct) |
|---|---|---|---|
| Architecture | Idiomatic mpv Lua script only | Accepted | "nah, just idiomatic. built-in mpv stuff." |
| Prompt channels | Both OSD + terminal | Accepted | wants overlay when a window is drawn to avoid keystroke flip-flop |
| Channel branch | `vo-configured` (window drawn?), not "has video" | Accepted | "if there is instead some way to make the logic `if mpv is rendering a gui …`, that would be more precisely what i'm after" |
| Config format | Flat `key = value` | Accepted | "i don't want a bundled dependency, but i'm good with JSON or mpv-style flat key/value pairs. whichever you think is preferable" |
| Config layering | Per-directory cumulative cascade, closest wins | Accepted | user-designed walk; per-dir is "quite helpful … different groups of media will often have different … 'this is the end' timings" |
| URL identity | Plan A generic normalization | Accepted | "A seems fine enough to me" |
| md5 | Pure-Lua, no spawn | Accepted | "looks good" |
| Remember-for-session | Toggle checkbox + capital accelerators, per-state | Accepted | "(Resume \|\| Beginning) && (Remember for Session)"; "i might change my mind later lol, so it should either be dead simple code … or … modular" |
| `finished_at` | Single shape-parsed knob; default `97%` | Accepted | "one setting to handle the 'how far from the end' config, and then we handle percentage vs static time in the code" |
| Never auto-clear | Always store last PP; finished derived | Accepted | "i don't think i ever ever clear the data" |
| `finished_behavior` | `skip` \| `play_from_beginning`; default latter | Accepted | skip for TV seasons, restart for finished movies |
| Skip-with-no-next | Fall back to play_from_beginning | Accepted | user picked option A |
| Rewatch | Model A explicit reset; Model B deferred | Accepted | "i think the rewatch option is reasonable :) and we can play with it as we go if needed" |
| `last_watch_timestamp` | Store now for future cursor | Accepted | "can we save one more piece of metadata to potentially play with in the future? last_watch_timestamp, epoch" |
| Project home | Standalone repo + dotfiles submodule | Accepted | "standalone repo + submodule in dotfiles" |
| Esc/q at prompt | Quit mpv (position preserved); not shown as an option. Supersedes "dismiss = safe default". | Accepted | "if i press esc or q at either prompt, i'd like for it to exit :) we don't have to display these as prompt options" |
