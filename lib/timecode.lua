-- lib/timecode.lua : parse the config `finished_at` knob, decide near-end, and
-- format seconds for the resume prompt. Lua 5.1 compatible, pure, no globals.
--
-- `finished_at` is a single knob meaning "how close to the end counts as
-- finished". It accepts EITHER an absolute duration (a margin measured back
-- from the end) OR a fraction/percentage of the total. We disambiguate by the
-- value's *shape*, never by a separate flag:
--   "97%"     -> fraction 0.97   (trailing percent)
--   "0.97"    -> fraction 0.97   (bare number < 1)
--   "15s"     -> 15 seconds      (unit suffix)
--   "1h2m3s"  -> 3723 seconds    (compound units)
--   "1:30"    -> 90 seconds      (mm:ss colon form)
--   "1:02:03" -> 3723 seconds    (hh:mm:ss colon form)
--   "15"      -> 15 seconds      (bare number >= 1)

local M = {}

-- Parse colon forms: mm:ss or hh:mm:ss. Returns seconds or nil if not colon.
local function parse_colon(str)
  local h, m, s = str:match("^(%d+):(%d+):(%d+)$")
  if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
  local mm, ss = str:match("^(%d+):(%d+)$")
  if mm then return tonumber(mm) * 60 + tonumber(ss) end
  return nil
end

-- Parse unit forms: any of h/m/s (case-insensitive), e.g. "1h2m3s", "2m", "45s".
-- Returns seconds, or nil if the string carries no unit letter we recognize.
local function parse_units(str)
  local lower = str:lower()
  if not lower:match("[hms]") then return nil end
  local total = 0
  local hh = lower:match("(%d+%.?%d*)h")
  local mm = lower:match("(%d+%.?%d*)m")
  local ss = lower:match("(%d+%.?%d*)s")
  if hh then total = total + tonumber(hh) * 3600 end
  if mm then total = total + tonumber(mm) * 60 end
  if ss then total = total + tonumber(ss) end
  return total
end

-- parse_finished_at(str) -> {kind="abs", secs=N} | {kind="frac", frac=F}
-- Precedence (per design): percent, then units/colon, then bare<1, then bare>=1.
-- Malformed/unparseable input is treated as a safe default of "never finished":
-- an absolute margin of 0 seconds (pos must reach the very end). This avoids
-- accidentally marking partially-watched media as finished from a typo.
function M.parse_finished_at(str)
  if type(str) ~= "string" then return { kind = "abs", secs = 0 } end
  str = str:gsub("^%s+", ""):gsub("%s+$", "")

  -- 1) trailing percent -> fraction. Divide by 100 so "97%" lands on the same
  --    double as tonumber("0.97") for exact equality in callers/tests.
  local pct = str:match("^(%d+%.?%d*)%%$")
  if pct then return { kind = "frac", frac = tonumber(pct) / 100 } end

  -- 2) colon form -> absolute seconds.
  local colon = parse_colon(str)
  if colon then return { kind = "abs", secs = colon } end

  -- 2b) unit-letter form -> absolute seconds.
  if str:match("[hHmMsS]") then
    local secs = parse_units(str)
    if secs then return { kind = "abs", secs = secs } end
  end

  -- 3/4) bare number: < 1 is a fraction, >= 1 is seconds.
  local num = tonumber(str)
  if num then
    if num < 1 then return { kind = "frac", frac = num } end
    return { kind = "abs", secs = num }
  end

  -- Unparseable: safe default (require reaching the end).
  return { kind = "abs", secs = 0 }
end

-- near_end(pos, duration, parsed) -> boolean
-- Live/unknown streams (duration <= 0) are never "finished".
function M.near_end(pos, duration, parsed)
  if type(duration) ~= "number" or duration <= 0 then return false end
  if not parsed then return false end
  if parsed.kind == "abs" then
    return pos >= duration - parsed.secs
  elseif parsed.kind == "frac" then
    return pos / duration >= parsed.frac
  end
  return false
end

-- format_hms(seconds) -> "H:MM:SS" (>= 1h) or "M:SS" (< 1h).
-- Seconds always zero-padded to 2; minutes zero-padded only in the H:MM:SS form.
function M.format_hms(seconds)
  local total = math.floor(tonumber(seconds) or 0)
  if total < 0 then total = 0 end
  local h = math.floor(total / 3600)
  local m = math.floor((total % 3600) / 60)
  local s = total % 60
  if h >= 1 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

return M
