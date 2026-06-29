# mpvpp — mpv Playback Position

An idiomatic [mpv](https://mpv.io) Lua script that records the last playback position (PP)
for whatever you watch — local files **and** yt-dlp/URL streams — and prompts you to
**Resume** or **Play from beginning** on replay, with per-session memory, finished-episode
handling, and layered per-directory config. No external dependencies (pure Lua + mpv's
built-in APIs).

## Features

- **Works across sources** — local files (resolved absolute path) and yt-dlp URLs
  (generically normalized so `?v=…`, `&t=42s`, `youtu.be/…`, and `&list=…` collapse to one
  entry where they refer to the same video).
- **Prompt, your way** — an OSD overlay when mpv is drawing a window (video *or* album
  art), or a terminal prompt otherwise; force the terminal one via config. Toggle "remember
  for this session" with `m`, or use capital accelerators (`R`/`B`/`S`) to commit + remember
  in one keypress.
- **Finished handling** — past your `finished_at` threshold, **skip** the episode (great for
  `mpv "Season 02"`) or **restart** it. Never auto-clears, so you can re-tune `finished_at`
  any time; start a rewatch with an explicit reset.
- **Layered config** — built-in defaults → `~/.config/mpvpp/config.conf` → a per-directory
  `.mpvpp.conf` cascade (closest to the media wins). Flat `key = value`, no dependencies.

## Install

mpvpp loads as an mpv *script directory* — the repo folder itself is the script (entry
point `main.lua`). Put it (or a symlink/submodule of it) at:

```
~/.config/mpv/scripts/mpvpp/        # this repo; mpv runs main.lua
```

For example, as a git submodule of a dotfiles repo whose `mpv` package maps to
`~/.config/mpv`:

```sh
git submodule add https://…/mpvpp packages/mpv/.config/mpv/scripts/mpvpp
```

Then optionally:

```sh
mkdir -p ~/.config/mpvpp
cp ~/.config/mpv/scripts/mpvpp/config.example.conf ~/.config/mpvpp/config.conf   # tweak to taste
cat ~/.config/mpv/scripts/mpvpp/input.conf.example >> ~/.config/mpv/input.conf   # reset bindings
```

## Configuration

Flat `key = value`, strictly declarative. See **[`config.example.conf`](config.example.conf)**
for every key, documented. Quick reference:

| Key | Default | Meaning |
|---|---|---|
| `record_position` | `yes` | Master switch; `no` = fully inert for this media. |
| `show_prompt` | `yes` | Show the prompt, or act silently. |
| `cli_prompt_only` | `no` | Force the terminal prompt even when a window exists. |
| `no_ui_fallback` | `resume` | Terminal wanted but no terminal: `resume`/`beginning`/`force_window`. |
| `save_interval` | `5` | Write position at most every N seconds (crash safety). |
| `min_position` | `30` | Don't prompt to resume below N seconds. |
| `finished_at` | `97%` | "How far from the end is finished": `15s`/`2m`/`1:30`/`97%`/`0.97`. |
| `finished_behavior` | `play_from_beginning` | When finished: `skip` or `play_from_beginning`. |

**Per-directory overrides:** drop a `.mpvpp.conf` in any media folder to override just those
keys for everything under it — e.g. `finished_at = 30s` in a `Shows/` folder, `97%` in
`Lectures/`. The folder closest to the file wins.

## Prompts

When you replay something with a saved position:

```
  ⏵ Resume from 14:32?
    [r] Resume        [b] Play from beginning
    [m] Remember for this session   [ ]      (accelerators: R / B)
```

When a media is already finished:

```
  ⏹  "S02E04.mkv" — finished
    [s] Skip          [b] Play from beginning
    [m] Remember for this session   [ ]      (accelerators: S / B)
    [x] rewatch (clear this folder's progress)
```

"Remember for this session" applies only to the current mpv process (e.g. the rest of a
playlist), and is tracked separately for resume vs finished decisions.

The "Remember for this session" toggle only appears when the playlist has more than one
entry (with a single file there's nothing later to apply it to).

`Esc` or `q` at either prompt quits mpv, leaving your saved position untouched.

## Reset (rewatch)

mpvpp never clears saved positions automatically. To start a rewatch fresh, use the
bindings from [`input.conf.example`](input.conf.example):

- `script-message mpvpp-reset` — clear every playlist entry in the current file's folder,
  then restart from the beginning.
- `script-message mpvpp-reset-file` — clear just the current file.

The finished prompt's `[x]` key does the folder reset too.

## State

One small JSON file per media at `~/.local/state/mpvpp/<md5>.json` (honors
`XDG_STATE_HOME`). The hash keys the file; the readable `source` path/URL is kept inside for
grepping/debugging.

## Development

Pure logic lives in `lib/*.lua` and is unit-tested under plain Lua 5.1 with a zero-dependency
harness:

```sh
lua test/run.lua      # all green = pass
```

`main.lua` is the mpv glue (events, properties, OSD, key bindings, IO); its non-interactive
paths are verified against mpv headlessly, and the interactive prompt is covered by
[`docs/manual-test-checklist.md`](docs/manual-test-checklist.md). Design and rationale:
[`docs/plans/2026-06-28-mpvpp-design.md`](docs/plans/2026-06-28-mpvpp-design.md).
