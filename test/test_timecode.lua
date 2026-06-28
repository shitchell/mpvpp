local T = require("test.harness")
local tc = require("lib.timecode")

-- parse_finished_at -> {kind="abs", secs=N} | {kind="frac", frac=F}
local p = tc.parse_finished_at
T.eq(p("97%").kind, "frac", "percent kind");  T.eq(p("97%").frac, 0.97, "percent val")
T.eq(p("0.97").kind, "frac", "fraction kind"); T.eq(p("0.97").frac, 0.97, "fraction val")
T.eq(p("15s").kind,  "abs",  "secs kind");     T.eq(p("15s").secs, 15, "secs val")
T.eq(p("2m").secs,   120, "2m")
T.eq(p("1m30s").secs, 90, "1m30s")
T.eq(p("1:30").secs,  90, "mm:ss")
T.eq(p("1:02:03").secs, 3723, "hh:mm:ss")
T.eq(p("15").kind, "abs", "bare>=1 is secs"); T.eq(p("15").secs, 15, "bare 15")
T.eq(p("90").secs, 90, "bare 90")

-- near_end(pos, duration, parsed)
local ne = tc.near_end
T.eq(ne(1370, 1380, p("15s")), true,  "abs within margin")
T.eq(ne(1300, 1380, p("15s")), false, "abs outside margin")
T.eq(ne(1360, 1380, p("97%")), true,  "frac past threshold")  -- 1360/1380=0.985
T.eq(ne(1300, 1380, p("97%")), false, "frac under threshold") -- 0.942
T.eq(ne(500, 0,    p("97%")), false, "unknown duration never finished")
T.eq(ne(500, -1,   p("15s")), false, "live never finished")

-- format_hms(seconds) -> "H:MM:SS" or "M:SS"
T.eq(tc.format_hms(92),   "1:32",    "m:ss")
T.eq(tc.format_hms(3723), "1:02:03", "h:mm:ss")
T.eq(tc.format_hms(5),    "0:05",    "pads seconds")
