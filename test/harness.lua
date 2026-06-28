-- test/harness.lua : minimal assert + report harness
local M = { pass = 0, fail = 0, failures = {} }

local function show(v)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do parts[#parts+1] = tostring(k).."="..tostring(val) end
    return "{"..table.concat(parts, ", ").."}"
  end
  return tostring(v)
end

function M.eq(actual, expected, msg)
  if actual == expected then M.pass = M.pass + 1
  else
    M.fail = M.fail + 1
    M.failures[#M.failures+1] = string.format(
      "%s\n    expected: %s\n    actual:   %s", msg or "eq", show(expected), show(actual))
  end
end

function M.ok(cond, msg)
  if cond then M.pass = M.pass + 1
  else M.fail = M.fail + 1; M.failures[#M.failures+1] = msg or "expected truthy" end
end

function M.report()
  print(string.format("\n%d passed, %d failed", M.pass, M.fail))
  for _, f in ipairs(M.failures) do print("  FAIL: "..f) end
  os.exit(M.fail > 0 and 1 or 0)
end

return M
