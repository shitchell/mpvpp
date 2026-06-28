local T = require("test.harness")
local store = require("lib.store")

-- in-memory fs + round-trippable stub json
local function mkfs()
  local files = {}
  return files, {
    dir = "/state",
    read_file = function(p) return files[p] end,
    write_file = function(p, s) files[p] = s; return true end,
    rename = function(a, b) files[b] = files[a]; files[a] = nil; return true end,
    exists = function(p) return files[p] ~= nil end,
    remove = function(p) files[p] = nil; return true end,
    json_encode = function(t) return t end,        -- stub: pass table through
    json_decode = function(s) return s end,        -- stub: identity
  }
end

local files, deps = mkfs()
local s = store.new(deps)
T.eq(s.load("k1"), nil, "missing key -> nil")
s.save("k1", { position = 42 })
T.eq(s.load("k1").position, 42, "save then load")
T.ok(files["/state/k1.json"] ~= nil, "writes to dir/<key>.json")
T.eq(files["/state/k1.json.tmp"], nil, "tmp renamed away (atomic)")
s.clear("k1")
T.eq(s.load("k1"), nil, "clear removes")
