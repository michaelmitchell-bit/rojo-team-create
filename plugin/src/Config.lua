local strict = require(script.Parent.strict)

local isDevBuild = script.Parent.Parent:FindFirstChild("ROJO_DEV_BUILD") ~= nil

local Version = script.Parent.Parent.Version
local trimmedVersionValue = Version.Value:gsub("^%s+", ""):gsub("%s+$", "")
local major, minor, patch, metadata = trimmedVersionValue:match("^(%d+)%.(%d+)%.(%d+)(.*)$")

local realVersion = { major, minor, patch, metadata }
for i = 1, 3 do
	local num = tonumber(realVersion[i])
	if num then
		realVersion[i] = num
	else
		error(("invalid version `%s` (field %d)"):format(realVersion[i], i))
	end
end

return strict("Config", {
	isDevBuild = isDevBuild,
	codename = "Epiphany",
	-- Where update checks look for newer releases. Forks point this at themselves
	-- so users aren't told to "update" to a build without their changes.
	releasesRepo = "michaelmitchell-bit/rojo-team-create",
	version = realVersion,
	expectedServerVersionString = ("%d.%d or newer"):format(realVersion[1], realVersion[2]),
	protocolVersion = 5,
	defaultHost = "localhost",
	defaultPort = "34872",
})
