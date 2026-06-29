-- lib/paths.lua : path normalization + config-cascade helpers. Lua 5.1, pure.
--
-- Pure string manipulation only: no file IO, no mpv, no globals, no side
-- effects. POSIX-style `/` paths (that's all mpv hands us on this Linux box).
-- Used by main.lua to turn an mpv filename into an absolute normalized path
-- (hashed into a store key), the list of ancestor directories to walk for the
-- per-directory `.mpvpp.conf` cascade, and the store filename for a hash.

local M = {}

-- absolute_path(path, cwd) : make PATH absolute and lexically normalized.
-- If PATH is relative (no leading `/`), it is joined onto CWD. Then the result
-- is normalized purely lexically: segments are split on `/`, empty segments
-- (from `//`) and `.` are dropped, and each `..` pops the previous segment
-- (never popping above root). The result always begins with `/`.
--
-- TODO(v1): no symlink resolution; see plan "Known v1 simplification"
function M.absolute_path(path, cwd)
  -- Prepend cwd for relative paths so we always normalize an absolute path.
  if path:sub(1, 1) ~= "/" then
    path = cwd .. "/" .. path
  end

  local stack = {}
  for seg in path:gmatch("[^/]+") do
    if seg == "." then
      -- current dir: no-op
    elseif seg == ".." then
      -- pop one level, but never above root
      if #stack > 0 then
        stack[#stack] = nil
      end
    else
      stack[#stack + 1] = seg
    end
  end

  return "/" .. table.concat(stack, "/")
end

-- ancestor_dirs(filepath) : ancestor directories from the topmost real segment
-- down to the file's immediate parent, EXCLUDING the file's own basename.
-- For "/path/to/some/movie.mkv" -> { "/path", "/path/to", "/path/to/some" }.
-- A file directly under root ("/movie.mkv") yields {} -- there are no
-- intermediate directories to carry a per-directory config.
function M.ancestor_dirs(filepath)
  local segs = {}
  for seg in filepath:gmatch("[^/]+") do
    segs[#segs + 1] = seg
  end

  local dirs = {}
  -- Build cumulative prefixes for every segment except the last (the basename).
  local prefix = ""
  for i = 1, #segs - 1 do
    prefix = prefix .. "/" .. segs[i]
    dirs[#dirs + 1] = prefix
  end
  return dirs
end

-- config_files_for(filepath, conf_name) : ancestor_dirs mapped to the config
-- file path within each ancestor directory (root -> parent order, so callers
-- merge closest-wins by overlaying later entries last).
function M.config_files_for(filepath, conf_name)
  local dirs = M.ancestor_dirs(filepath)
  local out = {}
  for i = 1, #dirs do
    out[i] = dirs[i] .. "/" .. conf_name
  end
  return out
end

-- store_filename(hash) : the on-disk store filename for a given key hash.
function M.store_filename(hash)
  return hash .. ".json"
end

return M
