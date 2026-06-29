-- mpvpp : mpv playback-position recorder + resume/finished prompt
-- Loaded as an mpv script directory (~/.config/mpv/scripts/mpvpp/main.lua).
-- Pure logic lives in lib/*.lua (unit-tested under bare lua); this file is the
-- mpv glue: events, properties, OSD/terminal prompt, key bindings, file IO, JSON.
-- Design: docs/plans/2026-06-28-mpvpp-design.md

local utils = require("mp.utils")
local msg = require("mp.msg")

-- Make co-located lib/*.lua requireable both in mpv and (via run.lua) in tests.
local sdir = mp.get_script_directory()
if sdir then package.path = sdir .. "/?.lua;" .. package.path end

local md5     = require("lib.md5")
local url     = require("lib.url")
local tc      = require("lib.timecode")
local config  = require("lib.config")
local paths   = require("lib.paths")
local storelib = require("lib.store")

--------------------------------------------------------------------------------
-- Constants (tweak here)
--------------------------------------------------------------------------------

local CONF_NAME = "mpvpp.conf"
local HOME = os.getenv("HOME") or ""
local USER_CONF = (os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")) .. "/mpvpp/config.conf"
local STATE_DIR = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/mpvpp"

--------------------------------------------------------------------------------
-- File IO + JSON deps for the store
--------------------------------------------------------------------------------

local function read_file(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function write_file(p, s)
  local f = io.open(p, "wb"); if not f then return false end
  f:write(s); f:close(); return true
end

local function exists(p) return utils.file_info(p) ~= nil end

local store = storelib.new({
  dir = STATE_DIR,
  read_file = read_file,
  write_file = write_file,
  rename = os.rename,
  exists = exists,
  remove = os.remove,
  json_encode = utils.format_json,
  json_decode = function(s) local t = utils.parse_json(s); return t end,
})

-- Ensure the state dir exists (one spawn at load; mpv 0.35 has no utils.mkdir).
mp.command_native({ name = "subprocess", playback_only = false,
                    args = { "mkdir", "-p", STATE_DIR } })

-- Is mpv's stdout actually a terminal? The "terminal" property only reflects
-- the --terminal option (default yes), not whether a tty is attached — so a
-- detached launch from a file manager would otherwise print the CLI prompt into
-- a void and pause forever. Resolve mpv's own fd 1 via /proc (Linux). Falls back
-- to "assume tty" where it can't tell (non-Linux), preserving prior behavior.
local function detect_stdout_tty()
  local pid = utils.getpid and utils.getpid()
  if not pid then return true end
  local r = mp.command_native({ name = "subprocess", playback_only = false,
    capture_stdout = true, args = { "readlink", "/proc/" .. pid .. "/fd/1" } })
  if not r or r.status ~= 0 or not r.stdout or r.stdout == "" then return true end
  return r.stdout:match("/dev/pts/") ~= nil or r.stdout:match("/dev/tty") ~= nil
end
local STDOUT_TTY = detect_stdout_tty()

--------------------------------------------------------------------------------
-- Config cascade (memoized per run)
--------------------------------------------------------------------------------

local conf_cache = {}  -- path -> parsed table | false (missing/invalid)

local function load_conf_file(path)
  local cached = conf_cache[path]
  if cached ~= nil then return cached end
  local text = read_file(path)
  local parsed = false
  if text then
    parsed = config.parse_conf(text, function(m) msg.warn(path .. ": " .. m) end)
  end
  conf_cache[path] = parsed
  return parsed
end

-- defaults -> user config -> per-directory cascade (local files only, closest wins)
local function merged_config(is_url_media, abspath)
  local cfg = config.defaults()
  local u = load_conf_file(USER_CONF)
  if u then cfg = config.merge(cfg, u) end
  if not is_url_media and abspath then
    for _, cpath in ipairs(paths.config_files_for(abspath, CONF_NAME)) do
      local c = load_conf_file(cpath)
      if c then cfg = config.merge(cfg, c) end
    end
  end
  return cfg
end

--------------------------------------------------------------------------------
-- Identity
--------------------------------------------------------------------------------

local function media_identity()
  local path = mp.get_property("path")
  if not path or path == "" then return nil end
  if url.is_url(path) then
    local norm = url.normalize_url(path)
    return { key = md5.sum(norm), source = norm, is_url = true }
  end
  local abspath = paths.absolute_path(path, utils.getcwd() or "")
  return { key = md5.sum(abspath), source = abspath, is_url = false, abspath = abspath }
end

--------------------------------------------------------------------------------
-- Session memory (this process only) + per-file state
--------------------------------------------------------------------------------

local session = { progress_action = nil, finished_action = nil }  -- "resume"/"beginning"/"skip"
local cur = nil  -- per-loaded-file context

--------------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------------

local function save_position()
  -- prompt_pending: a resume/finished prompt (or its window-settle wait) is up
  -- and playback is paused on ~frame 0; saving now would clobber the real
  -- position with ~0 (the very data this tool exists to protect). Skip it.
  if not cur or not cur.cfg.record_position or cur.prompt_pending then return end
  local pos = mp.get_property_number("time-pos") or cur.last_pos
  if not pos or pos < 0 then return end
  local now = os.time()
  store.save(cur.key, {
    source = cur.source,
    position = pos,
    duration = mp.get_property_number("duration") or cur.duration,
    title = cur.title,
    play_count = cur.play_count,
    updated = now,
    last_watch_timestamp = now,
  })
end

local function on_tick(_, value)
  if not cur then return end
  if value then cur.last_pos = value end
  local now = mp.get_time()
  if now - cur.last_save >= cur.cfg.save_interval then
    cur.last_save = now
    save_position()
  end
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function do_resume(pos)
  mp.commandv("seek", tostring(pos), "absolute", "exact")
  msg.verbose(string.format("resumed at %.1fs", pos))
end

local function do_beginning()
  msg.verbose("playing from beginning")
  -- mpv already starts at 0; nothing to do.
end

-- returns true if it advanced, false if there was no next entry
local function do_skip()
  local pos = mp.get_property_number("playlist-pos") or 0
  local count = mp.get_property_number("playlist-count") or 1
  if pos < count - 1 then
    msg.verbose("skipping finished entry")
    mp.commandv("playlist-next", "force")
    return true
  end
  return false
end

--------------------------------------------------------------------------------
-- Reset (explicit; never automatic)
--------------------------------------------------------------------------------

local function reset_current_file()
  local id = media_identity()
  if id then store.clear(id.key); msg.info("mpvpp: cleared position for current file") end
end

local function reset_folder()
  local id = media_identity()
  if not id or id.is_url or not id.abspath then return end
  local dir = id.abspath:match("^(.*)/[^/]*$") or ""
  local count = mp.get_property_number("playlist-count") or 0
  local cleared = 0
  for i = 0, count - 1 do
    local entry = mp.get_property("playlist/" .. i .. "/filename")
    if entry and not url.is_url(entry) then
      local ap = paths.absolute_path(entry, utils.getcwd() or "")
      if (ap:match("^(.*)/[^/]*$") or "") == dir then
        store.clear(md5.sum(ap)); cleared = cleared + 1
      end
    end
  end
  msg.info(string.format("mpvpp: reset folder (%d entries) — restarting from beginning", cleared))
  mp.commandv("seek", "0", "absolute", "exact")
end

--------------------------------------------------------------------------------
-- Prompt engine (OSD overlay or terminal), shared by resume + finished
--------------------------------------------------------------------------------

-- Declarative keymaps. Edit these to rebind. Each entry is one of:
--   { action = "<name>", remember = bool }   -- commit
--   { toggle = "remember" }                  -- flip the checkbox
--   { special = "reset" }                    -- folder reset
local RESUME_KEYS = {
  r = { action = "resume",    remember = false },
  b = { action = "beginning", remember = false },
  R = { action = "resume",    remember = true  },
  B = { action = "beginning", remember = true  },
  m = { toggle = "remember" },
  ENTER = { action = "resume", remember = false },
  ESC = { quit = true },   -- dismiss = quit mpv (position preserved); not shown as an option
  q = { quit = true },
}
local FINISHED_KEYS = {
  s = { action = "skip",      remember = false },
  b = { action = "beginning", remember = false },
  S = { action = "skip",      remember = true  },
  B = { action = "beginning", remember = true  },
  m = { toggle = "remember" },
  x = { special = "reset" },
  ENTER = { action = "skip", remember = false },     -- affirmative: Skip is the primary action
  ESC = { quit = true },   -- dismiss = quit mpv (position preserved); not shown as an option
  q = { quit = true },
}

local BINDING_PREFIX = "mpvpp-prompt-"
local active_overlay = nil
local active_dismiss = nil  -- teardown for the currently-showing/pending prompt (if any)

local function ass_escape(s) return (s:gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")) end

local function render(spec, state)
  local check = state.remember and "[x]" or "[ ]"
  -- "Remember for this session" only matters across a multi-entry playlist; with
  -- a single item there's nothing later to apply it to, so omit it entirely.
  if spec.channel == "osd" then
    local lines = {
      "{\\fs30}" .. ass_escape(spec.title),
      "",
      "{\\fs22}" .. ass_escape(spec.line1),
    }
    if spec.line_extra then lines[#lines + 1] = "{\\fs22}" .. ass_escape(spec.line_extra) end
    if spec.show_remember then
      lines[#lines + 1] = "{\\fs22}[m] Remember for this session   " .. check
    end
    if not active_overlay then active_overlay = mp.create_osd_overlay("ass-events") end
    active_overlay.data = "{\\an5}{\\bord2}" .. table.concat(lines, "\\N")
    active_overlay:update()
  else
    -- terminal
    io.write("\n  " .. spec.title .. "\n")
    io.write("    " .. spec.line1 .. "\n")
    if spec.line_extra then io.write("    " .. spec.line_extra .. "\n") end
    if spec.show_remember then
      io.write("    [m] Remember for this session   " .. check .. "\n")
    end
    io.flush()
  end
end

local function clear_render()
  if active_overlay then active_overlay:remove(); active_overlay = nil end
end

-- Pick channel per design: CLI if forced or no window; else OSD. Returns
-- "osd", "cli", or "none" (cli wanted but no terminal attached).
local function pick_channel(cfg)
  if cfg.cli_prompt_only or not mp.get_property_bool("vo-configured") then
    if mp.get_property_bool("terminal") and STDOUT_TTY then return "cli" else return "none" end
  end
  return "osd"
end

-- spec: { kind, title, line1, line_extra, keymap, cfg, resolve(action, remember) }
local function show_prompt(spec)
  local state = { remember = false }
  local bound = {}
  local shown = false                       -- has present() run (bindings + pause)?
  local settled, observer, timer = false, nil, nil

  -- Fully dismiss the prompt: cancel any pending window-settle wait, drop key
  -- bindings + overlay, and unpause only if we had paused. Safe to call in any
  -- phase (waiting OR shown), and idempotent.
  local function teardown()
    settled = true
    if observer then mp.unobserve_property(observer); observer = nil end
    if timer then timer:kill(); timer = nil end
    for _, name in ipairs(bound) do mp.remove_key_binding(name) end
    bound = {}
    clear_render()
    if cur then cur.prompt_pending = false end
    if shown then mp.set_property_bool("pause", false) end
    active_dismiss = nil
  end

  local function resolve(action, remember)
    if remember then
      if spec.kind == "resume" then session.progress_action = action
      else session.finished_action = action end
    end
    spec.resolve(action)  -- act (e.g. seek) while still paused...
    teardown()            -- ...then drop bindings + unpause (avoids a frame-0 flash)
  end

  local function on_key(entry)
    if entry.toggle then
      state.remember = not state.remember
      render(spec, state)
    elseif entry.quit then
      -- Quit WITHOUT tearing down: leaving prompt_pending set means the shutdown
      -- save is suppressed, so the saved position is preserved exactly as-is.
      mp.commandv("quit")
    elseif entry.special == "reset" then
      teardown(); reset_folder()
    elseif entry.action then
      resolve(entry.action, entry.remember)
    end
  end

  local function present()
    spec.channel = pick_channel(spec.cfg)
    if spec.channel == "none" then
      teardown()
      return spec.no_ui()  -- nowhere to prompt
    end
    shown = true
    mp.set_property_bool("pause", true)
    for key, entry in pairs(spec.keymap) do
      -- skip the remember keys (m toggle, capital accelerators) for a lone item
      if spec.show_remember or not (entry.toggle or entry.remember) then
        local name = BINDING_PREFIX .. key
        bound[#bound + 1] = name
        mp.add_forced_key_binding(key, name, function() on_key(entry) end)
      end
    end
    render(spec, state)
  end

  -- Register teardown immediately so a file reload during EITHER the settle wait
  -- or the shown prompt tears this down (prevents orphaned bindings/overlay and
  -- stale-closure crashes). Suppress saves for the whole pending window (C1).
  if active_dismiss then active_dismiss() end
  active_dismiss = teardown
  if cur then cur.prompt_pending = true end

  -- The video window's VO isn't configured yet at file-loaded (mpv creates it a
  -- frame later), so deciding OSD-vs-terminal right now would wrongly pick the
  -- terminal for video. Wait for "vo-configured" to settle first. Pure audio
  -- (no video track) and cli_prompt_only have no window to wait for -> decide now.
  if spec.cfg.cli_prompt_only
     or mp.get_property_bool("vo-configured")
     or mp.get_property("vid") == "no" then
    return present()
  end

  local function settle()
    if settled then return end
    settled = true
    if observer then mp.unobserve_property(observer); observer = nil end
    if timer then timer:kill(); timer = nil end
    present()
  end
  observer = function(_, val) if val then settle() end end
  mp.observe_property("vo-configured", "bool", observer)
  timer = mp.add_timeout(1.0, settle)  -- fallback: no window ever appeared
end

--------------------------------------------------------------------------------
-- Decision flows
--------------------------------------------------------------------------------

local function apply_finished(action)
  if action == "skip" then
    if not do_skip() then do_beginning() end  -- no next entry -> restart
  else
    do_beginning()
  end
end

local function handle_finished()
  local cfg = cur.cfg
  if not cfg.show_prompt or session.finished_action then
    apply_finished(session.finished_action or cfg.finished_behavior)
    return
  end
  show_prompt({
    kind = "finished",
    title = "⏹  \"" .. (mp.get_property("media-title") or "?") .. "\" — finished",
    line1 = "[s] Skip        [b] Play from beginning",
    line_extra = "[x] rewatch (clear this folder's progress)",
    keymap = FINISHED_KEYS,
    show_remember = (mp.get_property_number("playlist-count") or 1) > 1,
    cfg = cfg,
    no_ui = function() apply_finished(cfg.finished_behavior) end,
    resolve = apply_finished,
  })
end

local function apply_resume(action)
  if action == "resume" then do_resume(cur.saved.position) else do_beginning() end
end

local function handle_resume()
  local cfg, saved = cur.cfg, cur.saved
  if saved.position < cfg.min_position then return end          -- below floor -> just play
  if not cfg.show_prompt then do_resume(saved.position); return end
  if session.progress_action then apply_resume(session.progress_action); return end

  local function no_ui()
    local fb = cfg.no_ui_fallback
    if fb == "resume" then do_resume(saved.position)
    elseif fb == "beginning" then do_beginning()
    elseif fb == "force_window" then
      mp.set_property("force-window", "yes")
      do_resume(saved.position)  -- best-effort; window may appear late
    end
  end

  show_prompt({
    kind = "resume",
    title = "⏵ Resume from " .. tc.format_hms(saved.position) .. "?",
    line1 = "[r] Resume        [b] Play from beginning",
    keymap = RESUME_KEYS,
    show_remember = (mp.get_property_number("playlist-count") or 1) > 1,
    cfg = cfg,
    no_ui = no_ui,
    resolve = apply_resume,
  })
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function on_file_loaded()
  if active_dismiss then active_dismiss() end  -- tear down a prompt left up from the previous file
  cur = nil
  local id = media_identity()
  if not id then return end
  local cfg = merged_config(id.is_url, id.abspath)
  if not cfg.record_position then msg.verbose("mpvpp: recording disabled for this media"); return end

  local saved = store.load(id.key)
  cur = {
    key = id.key, source = id.source, abspath = id.abspath, is_url = id.is_url,
    cfg = cfg, duration = mp.get_property_number("duration"), saved = saved,
    title = mp.get_property("media-title"),
    last_save = mp.get_time(), last_pos = 0,
    play_count = ((saved and saved.play_count) or 0) + 1,
  }

  if saved and saved.position then
    local finished = tc.near_end(saved.position, cur.duration, tc.parse_finished_at(cfg.finished_at))
    if finished then handle_finished() else handle_resume() end
  end
end

mp.register_event("file-loaded", on_file_loaded)
mp.observe_property("time-pos", "number", on_tick)
mp.register_event("end-file", function() save_position() end)
mp.register_event("shutdown", function() save_position() end)
mp.register_script_message("mpvpp-reset-file", reset_current_file)
mp.register_script_message("mpvpp-reset", reset_folder)

msg.verbose("mpvpp loaded; state dir = " .. STATE_DIR)
