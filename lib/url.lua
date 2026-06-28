-- lib/url.lua : URL identity + Plan-A normalization, Lua 5.1 compatible.
--
-- "Plan A" is generic, low-maintenance normalization (NOT site-aware canonical
-- IDs): lowercase scheme/host, strip a leading `www.`, drop a small set of
-- volatile query params, sort the survivors so order is irrelevant, and trim a
-- trailing slash. The goal is that the same media reached via cosmetically
-- different URLs collapses to one stable string (and thus one md5 key), while
-- meaningfully different URLs stay distinct.

local M = {}

-- Volatile query keys: params that change the URL but not the identity of the
-- media it points at (time offsets, playlist context, share/tracking tags).
-- Stored as a set for O(1) lookup. Extensible: add keys as new volatile
-- params are encountered.
local VOLATILE = {
  t       = true, -- youtube/generic start-time offset
  start   = true, -- alternate start-time param
  list    = true, -- playlist id (context, not identity)
  index   = true, -- position within a playlist
  feature = true, -- youtube referral/source tag
  si      = true, -- youtube share-tracking token
}

-- True iff `s` begins with a URI scheme (e.g. "https://", "ytdl://").
function M.is_url(s)
  if type(s) ~= "string" then return false end
  return s:match("^%a[%w+.%-]*://") ~= nil
end

-- Split "k=v" (or bare "k") into key, value. Value is "" when absent so that a
-- valueless param still round-trips deterministically.
local function split_pair(pair)
  local k, v = pair:match("^([^=]*)=(.*)$")
  if k == nil then return pair, "" end
  return k, v
end

-- Normalize a URL into a canonical identity string. Non-URLs are returned
-- unchanged (callers gate on is_url, but this keeps the function total).
function M.normalize_url(u)
  if type(u) ~= "string" or not M.is_url(u) then return u end

  -- scheme://rest
  local scheme, rest = u:match("^(%a[%w+.%-]*)://(.*)$")
  if not scheme then return u end
  scheme = scheme:lower()

  -- Drop any fragment (#...): never part of media identity.
  rest = rest:gsub("#.*$", "")

  -- Split off the query (?...) from authority+path.
  local hostpath, query = rest:match("^([^?]*)%??(.*)$")

  -- authority (host[:port]) is everything up to the first '/'.
  local host, path = hostpath:match("^([^/]*)(.*)$")
  host = host:lower():gsub("^www%.", "")

  -- Trim a single trailing slash, but preserve a bare root "/" as "".
  -- (Both "" and a trimmed "/" collapse to "", keeping identity consistent.)
  if path ~= "/" then
    path = path:gsub("/$", "")
  else
    path = ""
  end

  -- Filter + collect surviving query params.
  local kept = {}
  if query ~= "" then
    for pair in query:gmatch("[^&]+") do
      local k = split_pair(pair)
      if k ~= "" and not VOLATILE[k] then
        kept[#kept + 1] = pair
      end
    end
  end
  -- Sort so ?a=1&b=2 and ?b=2&a=1 yield the same canonical string.
  table.sort(kept)

  local canon = scheme .. "://" .. host .. path
  if #kept > 0 then
    canon = canon .. "?" .. table.concat(kept, "&")
  end
  return canon
end

return M
