local T = require("test.harness")
local md5 = require("lib.md5")
T.eq(md5.sum(""),    "d41d8cd98f00b204e9800998ecf8427e", "md5 empty")
T.eq(md5.sum("a"),   "0cc175b9c0f1b6a831c399e269772661", "md5 a")
T.eq(md5.sum("abc"), "900150983cd24fb0d6963f7d28e17f72", "md5 abc")
T.eq(md5.sum("message digest"), "f96b697d7cb7938d525a2f31aaf161d0", "md5 message digest")
T.eq(md5.sum("The quick brown fox jumps over the lazy dog"),
            "9e107d9d372bb6826bd81d3542a419d6", "md5 fox")
