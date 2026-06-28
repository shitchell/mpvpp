-- test/run.lua : run from repo root with `lua test/run.lua`
package.path = "./?.lua;" .. package.path
local files = {
  "test.test_smoke",
  "test.test_md5",
  "test.test_url",
  -- append modules as tasks land:
  -- "test.test_timecode",
  -- "test.test_config", "test.test_paths", "test.test_store",
}
for _, mod in ipairs(files) do require(mod) end
require("test.harness").report()
