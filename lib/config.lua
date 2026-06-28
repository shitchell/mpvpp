-- lib/config.lua : config schema, parser, and shallow merge. Lua 5.1, pure.
--
-- This module is the single source of truth for config keys, their types,
-- defaults, and (for enums) the allowed value set. It does NO file IO and never
-- touches mpv -- it operates only on strings and tables. Reading files from
-- disk and walking the per-directory cascade belong to main.lua / lib/paths.lua.
--
-- The config file format is flat, mpv-style `key = value`, strictly declarative:
-- no code, no shell, no nesting. Layers (built-in DEFAULTS -> user config ->
-- per-directory cascade) are combined via M.merge, each later layer shallow-
-- overriding earlier keys.

local M = {}

-- SCHEMA: the single source of truth. Each entry has a `type` and a `default`;
-- enum entries additionally carry a `values` set of allowed strings.
local SCHEMA = {
  record_position   = { type = "bool",  default = true },
  show_prompt       = { type = "bool",  default = true },
  cli_prompt_only   = { type = "bool",  default = false },
  no_ui_fallback    = { type = "enum",  default = "resume",
                        values = { resume = true, force_window = true, beginning = true } },
  save_interval     = { type = "number", default = 5 },
  min_position      = { type = "number", default = 30 },
  finished_at       = { type = "string", default = "97%" },
  finished_behavior = { type = "enum",  default = "play_from_beginning",
                        values = { skip = true, play_from_beginning = true } },
}

-- Truthy/falsey token sets for bool coercion. Kept deliberately small and
-- explicit: anything outside these sets is an error (warn + skip), not silently
-- coerced, so typos surface instead of defaulting to false.
local BOOL_TRUE  = { yes = true, ["true"] = true, on = true, ["1"] = true }
local BOOL_FALSE = { no = true, ["false"] = true, off = true, ["0"] = true }

-- Trim leading/trailing ASCII whitespace (incl. \r, so CRLF lines are handled).
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- defaults() : return a FRESH table populated from SCHEMA defaults. A new table
-- is built on every call because callers mutate the result during the merge
-- cascade; sharing one would corrupt the schema's defaults.
function M.defaults()
  local t = {}
  for key, spec in pairs(SCHEMA) do
    t[key] = spec.default
  end
  return t
end

-- parse_conf(text, on_warn) : parse flat `key = value` config TEXT into a table
-- of validated values. Only keys that are present AND valid appear in the
-- result; unknown keys and invalid values are warned about and omitted, so a
-- later merge transparently keeps the prior layer's value for them.
--
-- on_warn is an optional callback function(message); nil is tolerated.
--
-- Comments: only WHOLE lines whose first non-space char is `#` or `;` are
-- comments. An inline `#` is NOT a comment (a value may legitimately contain
-- one), keeping the parser simple and predictable.
function M.parse_conf(text, on_warn)
  local warn = on_warn or function() end
  local out = {}

  for line in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = trim(line)
    -- Skip blank lines and whole-line comments (# or ; leader).
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" and trimmed:sub(1, 1) ~= ";" then
      -- Split on the FIRST `=` only, so values may themselves contain `=`.
      local key, value = line:match("^(.-)=(.*)$")
      if not key then
        warn("config: ignoring line without '=': " .. trimmed)
      else
        key = trim(key)
        value = trim(value)
        local spec = SCHEMA[key]
        if not spec then
          warn("config: unknown key '" .. key .. "'")
        elseif spec.type == "bool" then
          local lower = value:lower()
          if BOOL_TRUE[lower] then
            out[key] = true
          elseif BOOL_FALSE[lower] then
            out[key] = false
          else
            warn("config: invalid bool for '" .. key .. "': " .. value)
          end
        elseif spec.type == "number" then
          local n = tonumber(value)
          if n == nil then
            warn("config: invalid number for '" .. key .. "': " .. value)
          else
            out[key] = n
          end
        elseif spec.type == "enum" then
          if spec.values[value] then
            out[key] = value
          else
            warn("config: invalid value for '" .. key .. "': " .. value)
          end
        else -- "string"
          out[key] = value
        end
      end
    end
  end

  return out
end

-- merge(base, over) : return a NEW shallow-merged table (over's keys overlaid on
-- a copy of base). Copies rather than mutating so neither input is corrupted --
-- safer for the layered cascade where base may be reused.
function M.merge(base, over)
  local out = {}
  if base then for k, v in pairs(base) do out[k] = v end end
  if over then for k, v in pairs(over) do out[k] = v end end
  return out
end

return M
