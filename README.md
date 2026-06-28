# mpvpp — mpv Playback Position

An idiomatic [mpv](https://mpv.io) Lua script that records the last playback position (PP)
for whatever you watch — local files **and** yt-dlp/URL streams — and prompts you to
**Resume** or **Play from beginning** on replay, with per-session memory, finished-episode
handling, and layered per-directory config.

> Status: **design phase.** See [`docs/plans/2026-06-28-mpvpp-design.md`](docs/plans/2026-06-28-mpvpp-design.md)
> for the full validated design. Implementation not yet started.

## Highlights (planned)

- **Works across sources** — local files (resolved path) and yt-dlp URLs (generically
  normalized so `?v=…`, `&t=42s`, `youtu.be/…`, and `&list=…` collapse to one entry).
- **Prompt, your way** — an OSD overlay when mpv is drawing a window (video *or* album art),
  or a terminal prompt otherwise; forced to CLI via config. Toggle "remember for this
  session" with `m`, or use capital accelerators (`R`/`B`/`S`).
- **Finished handling** — past your `finished_at` threshold, skip the episode (great for
  `mpv "Season 02"`) or restart it.
- **Layered config** — built-in defaults → `~/.config/mpvpp/config.conf` → a per-directory
  `mpvpp.conf` cascade (closest to the media wins). Flat `key = value`, no dependencies.

## Install (planned)

Loaded as an mpv *script directory* — this repo is added to your mpv config as a submodule:

```
~/.config/mpv/scripts/mpvpp/   ← this repo (entry point: main.lua)
```

## Config

See the [design doc](docs/plans/2026-06-28-mpvpp-design.md#config-key-reference) for the
full key reference.
