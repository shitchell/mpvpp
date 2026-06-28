local T = require("test.harness")
local P = require("lib.paths")

-- absolute_path(path, cwd) : pure; prepend cwd if relative; collapse . and ..
T.eq(P.absolute_path("/a/b/c.mkv", "/home/guy"), "/a/b/c.mkv", "already abs")
T.eq(P.absolute_path("rel/c.mkv", "/home/guy"), "/home/guy/rel/c.mkv", "relative")
T.eq(P.absolute_path("/a/b/../c", "/x"), "/a/c", "collapse ..")
T.eq(P.absolute_path("/a/./b", "/x"), "/a/b", "collapse .")

-- ancestor_dirs("/path/to/some/movie.mkv") root->parent, EXCLUDING the file itself
local d = P.ancestor_dirs("/path/to/some/movie.mkv")
T.eq(d[1], "/path", "first ancestor")
T.eq(d[2], "/path/to", "second")
T.eq(d[3], "/path/to/some", "parent last")
T.eq(#d, 3, "three ancestors")

-- config_files_for(abspath, conf_name) appends conf_name to each ancestor dir
local cf = P.config_files_for("/path/to/some/movie.mkv", "mpvpp.conf")
T.eq(cf[1], "/path/mpvpp.conf", "first conf path")
T.eq(cf[#cf], "/path/to/some/mpvpp.conf", "parent conf path")

-- store_filename(hash) -> hash .. ".json"
T.eq(P.store_filename("abc"), "abc.json", "store filename")
