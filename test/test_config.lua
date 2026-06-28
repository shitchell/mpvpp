local T = require("test.harness")
local cfg = require("lib.config")

-- defaults()
T.eq(cfg.defaults().record_position, true, "default record")
T.eq(cfg.defaults().finished_at, "97%", "default finished_at")

-- parse_conf(text, on_warn) -> table of validated values (only keys present)
local warns = {}
local function warn(m) warns[#warns+1] = m end
local got = cfg.parse_conf([[
# comment
; also comment
record_position = no
finished_at = 15s
no_ui_fallback = beginning
save_interval = 10
bogus_key = 1
no_ui_fallback_typo = nope
]], warn)
T.eq(got.record_position, false, "yes/no -> bool")
T.eq(got.finished_at, "15s", "string passthrough")
T.eq(got.no_ui_fallback, "beginning", "valid enum")
T.eq(got.save_interval, 10, "number coercion")
T.eq(got.bogus_key, nil, "unknown key skipped")
T.ok(#warns >= 1, "unknown key warned")

-- bad enum value -> warn + omit (caller keeps prior via merge)
local w2 = {}
local g2 = cfg.parse_conf("no_ui_fallback = wat\n", function(m) w2[#w2+1]=m end)
T.eq(g2.no_ui_fallback, nil, "bad enum omitted")
T.ok(#w2 >= 1, "bad enum warned")

-- merge(base, override) shallow
local merged = cfg.merge({a=1, b=2}, {b=3, c=4})
T.eq(merged.a, 1, "base kept"); T.eq(merged.b, 3, "override wins"); T.eq(merged.c, 4, "new key")
