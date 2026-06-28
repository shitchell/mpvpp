-- lib/store.lua : dependency-injected position store. Lua 5.1, no external deps.
--
-- Holds the store LOGIC only -- which path a key maps to, atomic write via a
-- temp file + rename, load, and clear. It performs NO real file IO or JSON
-- itself: every effect (read/write/rename/exists/remove, encode/decode) is
-- INJECTED via `deps`, so the logic is unit-testable under plain `lua` with an
-- in-memory fake fs and a stub JSON codec. In production (main.lua) the deps
-- are wired to mpv's utils.format_json/parse_json and Lua io/os.
--
-- No `require('mp')`, no direct `io`/`os`, no globals.

local paths = require("lib.paths")

local M = {}

-- new(deps) : build a store instance bound to the injected effects.
--
-- deps:
--   dir          (string)                  state directory, no trailing slash.
--   read_file(p) -> string|nil             contents, or nil if missing.
--   write_file(p, s) -> true               write/overwrite.
--   rename(a, b) -> true                   atomic move.
--   exists(p) -> boolean
--   remove(p) -> true                      delete a file.
--   json_encode(t) -> string
--   json_decode(s) -> table
--
-- returns { load = fn(key), save = fn(key, data), clear = fn(key) }.
function M.new(deps)
  -- On-disk path for a key: <dir>/<key>.json (store_filename adds ".json").
  local function path_for(key)
    return deps.dir .. "/" .. paths.store_filename(key)
  end

  -- save(key, data) : encode then atomically swap into place.
  -- Write the encoded string to "<path>.tmp", then rename it onto <path> so a
  -- reader never observes a half-written file. Always routes through
  -- json_encode so a real JSON codec produces the on-disk string.
  local function save(key, data)
    local path = path_for(key)
    local tmp = path .. ".tmp"
    deps.write_file(tmp, deps.json_encode(data))
    deps.rename(tmp, path)
    return true
  end

  -- load(key) : decode the stored table, or nil if the key was never saved.
  -- Always routes through json_decode so a real codec parses the on-disk
  -- string (no in-memory shortcut).
  local function load(key)
    local path = path_for(key)
    if deps.exists(path) then
      return deps.json_decode(deps.read_file(path))
    end
    return nil
  end

  -- clear(key) : remove the stored file. No-op (still true) if absent.
  local function clear(key)
    local path = path_for(key)
    if deps.exists(path) then
      deps.remove(path)
    end
    return true
  end

  return { load = load, save = save, clear = clear }
end

return M
