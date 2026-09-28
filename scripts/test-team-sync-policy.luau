local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

-- Runs plugin/src/TeamSync/Policy.spec.lua under Lune with a minimal TestEZ shim,
-- so the team sync rules can be tested without Studio: lune run scripts/test-team-sync-policy
local dir = "plugin/src/TeamSync/"
local Policy = luau.load(fs.readFile(dir .. "Policy.lua"), { debugName = "Policy" })()

local function expect(value)
	local function check(ok, message)
		if not ok then
			error(message, 3)
		end
	end
	local api = {}
	api.to = {
		equal = function(expected)
			check(value == expected, string.format("expected %s, got %s", tostring(expected), tostring(value)))
		end,
		be = { ok = function() check(value ~= nil, "expected a value, got nil") end },
	}
	api.never = { to = { be = { ok = function() check(value == nil, "expected nil, got " .. tostring(value)) end } } }
	return api
end

local failures, passes, prefix = 0, 0, {}
local env = setmetatable({
	script = { Parent = { Policy = "Policy" } },
	require = function() return Policy end,
	describe = function(name, fn) table.insert(prefix, name); fn(); table.remove(prefix) end,
	it = function(name, fn)
		local ok, err = pcall(fn)
		local label = table.concat(prefix, " › ") .. " › " .. name
		if ok then passes += 1 else failures += 1; print("FAIL " .. label .. "\n  " .. tostring(err)) end
	end,
	expect = expect,
}, { __index = getfenv(1) })

luau.load(fs.readFile(dir .. "Policy.spec.lua"), { debugName = "Policy.spec", environment = env })()()
print(string.format("%d passed, %d failed", passes, failures))
process.exit(if failures > 0 then 1 else 0)
