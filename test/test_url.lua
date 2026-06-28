local T = require("test.harness")
local url = require("lib.url")

-- is_url
T.eq(url.is_url("https://youtu.be/abc"), true,  "https is url")
T.eq(url.is_url("http://x/y"),           true,  "http is url")
T.eq(url.is_url("ytdl://x"),             true,  "scheme is url")
T.eq(url.is_url("/home/guy/v.mkv"),      false, "abs path not url")
T.eq(url.is_url("rel/v.mkv"),            false, "rel path not url")

-- normalize_url (Plan A): lowercase host, strip www., strip volatile params, trim trailing /
local n = url.normalize_url
T.eq(n("https://www.youtube.com/watch?v=abc123"),
     n("https://www.youtube.com/watch?v=abc123&t=42s"),  "strip t=")
T.eq(n("https://www.youtube.com/watch?v=abc123"),
     n("https://www.youtube.com/watch?v=abc123&list=PLx&index=3"), "strip list/index")
T.eq(n("https://WWW.YouTube.com/watch?v=abc123"),
     n("https://youtube.com/watch?v=abc123"), "lowercase host + strip www")
T.eq(n("https://example.com/video/"),
     n("https://example.com/video"), "trim trailing slash")
-- keep a meaningful param
T.ok(n("https://x.com/w?v=a") ~= n("https://x.com/w?v=b"), "keep v=")
