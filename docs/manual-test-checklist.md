# mpvpp manual test checklist

Status legend: ✅ verified headlessly (automated, mpv 0.35.1, `--vo=null`) · 👁 needs a real
display / terminal interaction (do these by hand) · ⬜ not yet run.

Test media suggestions: a short local video, an audio-only file (with and without embedded
cover art), and a yt-dlp URL (e.g. a YouTube link).

> The automated checks live in the integration runs done during development. The 👁 items
> can't be automated here because they need a visible window (OSD overlay can only be seen
> with a real VO) or interactive keypresses.

## Core lifecycle

1. ✅ **Fresh play, no saved position** → loads with no errors, plays from start, writes
   `~/.local/state/mpvpp/<md5>.json` with `position`, `duration`, `title`, `play_count`,
   `source`, `updated`, `last_watch_timestamp`.
2. ✅ **Silent resume** (`show_prompt = no`) → on replay, seeks to the saved position
   (log: `resumed at <t>s`).
3. ✅ **Position key correctness** → store filename == `md5(absolute path)`; URL keys use the
   normalized URL.
4. ✅ **Crash safety** → throttled saves every `save_interval`s; final save on `end-file` /
   `shutdown`. (`kill -9` mid-play → on relaunch, resumes within `save_interval` of where you
   were. 👁 optionally re-confirm with a real `kill -9`.)

## Prompt — resume (👁 interactive)

5. 👁 **OSD overlay** — local video, saved position ≥ `min_position`, replay → the resume
   prompt is drawn **on the video window**, playback paused on the first frame.
   `r` resumes, `b` restarts.
6. 👁 **Album art counts as a window** — audio file *with* embedded cover art → prompt shows
   on the **OSD** (not terminal), because a window is being drawn.
7. 👁 **Terminal prompt** — audio-only *without* a window, launched from a terminal → prompt
   prints in the **terminal**; keys work.
8. 👁 **`cli_prompt_only = yes`** → even for video, the prompt appears in the terminal, not
   the OSD.
9. ✅/👁 **No-UI fallback** — audio-only, no window, no terminal (launch detached from a file
   manager) → applies `no_ui_fallback`. Channel-selection logic is unit-reasoned; 👁 confirm
   each of `resume` / `beginning` / `force_window` behaves.
10. 👁 **Remember toggle + accelerators** — `m` flips the `[ ]`/`[x]` checkbox (OSD re-renders;
    terminal reprints); committing with remember on sets session memory. `R`/`B` commit +
    remember in one press. Next playlist entry auto-applies the remembered resume choice
    without prompting.
11. 👁 **Esc/q quits** — `Esc` or `q` at either prompt quits mpv, and the saved position is
    **preserved** (next launch still offers the same resume point — not reset to 0).

## Prompt — finished

12. ✅ **Finished detection** — position past `finished_at` → bypasses the resume prompt and
    routes to finished handling.
13. ✅ **Skip with no next entry** — single-file (or last entry) + `finished_behavior = skip`
    → falls back to play-from-beginning (does **not** quit mpv).
14. 👁 **Skip across a season** — `mpv "Season XX"` with `finished_behavior = skip` and some
    finished episodes → finished prompt on the first; `s` skips, `S` skips + remembers so
    later finished episodes skip silently, landing on the first in-progress/unwatched one.
15. 👁 **Finished prompt `[x]` rewatch** → clears the folder's saved progress and restarts
    from the beginning.

## Config cascade

16. ✅ **User config applied** — `~/.config/mpvpp/config.conf` keys take effect.
17. ✅ **Per-directory override** — an `mpvpp.conf` in the media folder overrides user config
    (verified: user `finished_at = 20%` → finished; folder `90%` → resumes instead).
18. ✅ **Unknown key / bad value** → logged as a warning, ignored (prior value kept).
19. 👁 **Closest-wins across multiple levels** — nested `mpvpp.conf` files; the one nearest
    the media wins. (Logic unit-tested; 👁 optional end-to-end spot check.)

## Sources

20. ✅ **Reset (file + folder)** via `script-message mpvpp-reset-file` / `mpvpp-reset`
    (fired over IPC): clears the right key(s); folder reset also seeks to start.
21. 👁 **yt-dlp URL** — resume works for a YouTube link; `?v=…&t=42s` and bare `?v=…` resolve
    to the **same** saved entry (same `<md5>.json`).

## How to run an interactive item

```sh
# point mpv at the repo as a script dir, isolate state if you like:
XDG_STATE_HOME=/tmp/mpvpp-test/state \
  mpv --script=/path/to/mpvpp /path/to/media.mkv
```
