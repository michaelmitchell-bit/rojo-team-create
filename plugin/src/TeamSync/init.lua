--[[
	Team sync: stops people sharing a place from silently overwriting each
	other's synced changes. The rules live in Policy; this module connects them
	to the place (where the sync log is stored) and to Rojo patches.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local StudioService = game:GetService("StudioService")

local plugin = plugin or script:FindFirstAncestorWhichIsA("Plugin")
local Rojo = script:FindFirstAncestor("Rojo")
local Log = require(Rojo.Packages.Log)

local Types = require(script.Parent.Types)
local Policy = require(script.Policy)

local STORE_NAME = "RojoTeamSync"
-- Headroom under StringValue's 200,000 character limit.
local MAX_STORE_LENGTH = 190000

local TeamSync = {}
TeamSync.Policy = Policy
TeamSync.STORE_NAME = STORE_NAME

local function findStore(): StringValue?
	local store = ServerStorage:FindFirstChild(STORE_NAME)
	if store and store:IsA("StringValue") then
		return store
	end
	return nil
end

function TeamSync.isStore(instance: Instance): boolean
	return instance.Parent == ServerStorage and instance.Name == STORE_NAME and instance:IsA("StringValue")
end

-- Connected sessions read the log every second; only decode when it changes.
-- Callers treat the returned log as read-only.
local cachedRaw: string? = nil
local cachedLog: Policy.Log? = nil

local function decodeLog(raw: string): Policy.Log
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if ok and Policy.isLog(decoded) then
		return decoded
	end

	Log.warn("Rojo team sync log in ServerStorage.{} is unreadable; treating its history as unknown", STORE_NAME)
	local log = Policy.newLog("unreadable")
	log.truncated = true
	table.insert(log.entries, {
		id = "unreadable",
		userId = 0,
		name = "an unreadable sync log",
		at = 0,
		all = true,
		changes = {},
	})
	return log
end

--[[
	Reads the place's sync log. A log that exists but can't be read is treated
	as fully unknown history, so every change conflicts until someone overrides.
]]
function TeamSync.readLog(): Policy.Log?
	local store = findStore()
	if store == nil or store.Value == "" then
		return nil
	end

	if store.Value ~= cachedRaw then
		cachedRaw = store.Value
		cachedLog = decodeLog(store.Value)
	end
	return cachedLog
end

local function writeLog(log: Policy.Log)
	local fitted, encoded = Policy.fitToLength(log, MAX_STORE_LENGTH, function(value)
		return HttpService:JSONEncode(value)
	end)
	if #fitted.entries < #log.entries then
		Log.info("Trimmed the oldest Rojo team sync entries to keep the log small")
	end

	local recording = ChangeHistoryService:TryBeginRecording("Rojo: Update team sync log")

	local store = findStore()
	if store == nil then
		store = Instance.new("StringValue")
		store.Name = STORE_NAME
		store.Parent = ServerStorage
	end
	store.Value = encoded

	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
end

local function baseKey(logId: string): string
	return "Rojo_teamSyncBase_" .. logId
end

function TeamSync.getBaseId(log: Policy.Log?): string?
	if log == nil or plugin == nil then
		return nil
	end
	local value = plugin:GetSetting(baseKey(log.logId))
	return if type(value) == "string" then value else nil
end

local function setBaseId(logId: string, entryId: string)
	if plugin then
		plugin:SetSetting(baseKey(logId), entryId)
	end
end

local cachedName: string? = nil
local function localUserName(userId: number): string
	if cachedName then
		return cachedName
	end

	local name = if Players.LocalPlayer then Players.LocalPlayer.Name else nil
	if name == nil and userId > 0 then
		local ok, result = pcall(Players.GetNameFromUserIdAsync, Players, userId)
		name = if ok then result else nil
	end

	cachedName = name or ("user " .. tostring(userId))
	return cachedName :: string
end

--[[
	Turns a patch into the instance paths it would change. Must run before the
	patch is applied, while removed instances still have their paths.
]]
function TeamSync.changesFromPatch(patch, instanceMap): { Policy.Change }
	local changes = {}

	local function add(instance: Instance?, tree: boolean)
		if instance == nil or instance == game then
			return
		end
		table.insert(changes, { path = instance:GetFullName(), tree = tree })
	end

	for _, removed in patch.removed do
		if typeof(removed) == "Instance" then
			if not TeamSync.isStore(removed) then
				add(removed, true)
			end
		elseif Types.RbxId(removed) then
			add(instanceMap.fromIds[removed], true)
		end
	end

	for _, update in patch.updated do
		local instance = instanceMap.fromIds[update.id]
		local renamed = update.changedName ~= nil or update.changedClassName ~= nil
		add(instance, renamed)

		if instance and update.changedName ~= nil and instance.Parent then
			table.insert(changes, { path = instance.Parent:GetFullName() .. "." .. update.changedName, tree = true })
		end
	end

	-- Only the top of each added subtree matters: `tree` covers the rest.
	for _, virtual in patch.added do
		if patch.added[virtual.Parent] == nil then
			local parent = instanceMap.fromIds[virtual.Parent]
			if parent then
				local path = if parent == game then virtual.Name else parent:GetFullName() .. "." .. virtual.Name
				table.insert(changes, { path = path, tree = true })
			end
		end
	end

	return Policy.mergeChanges({}, changes)
end

--[[
	Keeps Rojo from deleting the sync log when ServerStorage is managed without
	$ignoreUnknownInstances.
]]
function TeamSync.protectStore(patch)
	for index = #patch.removed, 1, -1 do
		local removed = patch.removed[index]
		if typeof(removed) == "Instance" and TeamSync.isStore(removed) then
			table.remove(patch.removed, index)
		end
	end
end

function TeamSync.check(teamSync: boolean, changes: { Policy.Change }, force: boolean): Policy.Decision
	local log = TeamSync.readLog()
	return Policy.evaluate({
		teamSync = teamSync,
		log = log,
		baseId = TeamSync.getBaseId(log),
		changes = changes,
		force = force,
		now = os.time(),
	})
end

--[[
	Records one sync session in the place's log.
]]
local Session = {}
Session.__index = Session

function TeamSync.newSession(decision: Policy.Decision)
	return setmetatable({
		__entry = nil,
		__forced = decision.forced == true,
	}, Session)
end

--[[
	Adds this session's latest changes to its log entry. Returns the entry of
	whoever synced after us instead if we've been superseded; nothing is
	written in that case.
]]
function Session:record(changes: { Policy.Change }): Policy.Entry?
	local log = TeamSync.readLog()

	if self.__entry then
		local newer = Policy.supersededBy(log, self.__entry.id)
		if newer then
			return newer
		end
	end

	if log == nil or log.logId == "unreadable" then
		log = Policy.newLog(HttpService:GenerateGUID(false))
	end

	local entry = self.__entry
	if entry == nil then
		local userId = StudioService:GetUserId()
		entry = {
			id = HttpService:GenerateGUID(false),
			userId = userId,
			name = localUserName(userId),
			at = os.time(),
			forced = if self.__forced then true else nil,
			changes = {},
		}
	end

	entry = Policy.recordChanges(entry, changes, os.time())
	writeLog(Policy.withEntry(log :: Policy.Log, entry))
	setBaseId((log :: Policy.Log).logId, entry.id)
	self.__entry = entry
	return nil
end

--[[
	Returns whoever synced into the place after this session, if anyone.
]]
function Session:supersededBy(): Policy.Entry?
	if self.__entry == nil then
		return nil
	end
	return Policy.supersededBy(TeamSync.readLog(), self.__entry.id)
end

return TeamSync
