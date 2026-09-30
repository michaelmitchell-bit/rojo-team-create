--[[
	Team sync lets several people sync into the same place at once without
	overwriting each other. The rules live in Policy; this module connects them
	to the place, where each machine's write log is stored, and to Rojo patches.

	Storage: ServerStorage.RojoTeamSync is a Folder holding one StringValue per
	machine, named by that machine's id. Each plugin only ever writes its own
	value, so simultaneous syncs can't clobber each other's records.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local StudioService = game:GetService("StudioService")

local plugin = plugin or script:FindFirstAncestorWhichIsA("Plugin")
local Rojo = script:FindFirstAncestor("Rojo")
local Log = require(Rojo.Packages.Log)

local PatchSet = require(script.Parent.PatchSet)
local decodeValue = require(script.Parent.Reconciler.decodeValue)
local getProperty = require(script.Parent.Reconciler.getProperty)
local trueEquals = require(script.Parent.Reconciler.trueEquals)
local Policy = require(script.Policy)

local STORE_NAME = "RojoTeamSync"
local LOG_ID_ATTRIBUTE = "LogId"
-- Headroom under StringValue's 200,000 character limit.
local MAX_LOG_LENGTH = 190000

local TeamSync = {}
TeamSync.Policy = Policy

local function findStore(): Folder?
	-- Looked up by class too: a plugin from before logs were per machine may
	-- still write a StringValue with the same name.
	for _, child in ServerStorage:GetChildren() do
		if child.Name == STORE_NAME and child:IsA("Folder") then
			return child
		end
	end
	return nil
end

local function legacyStores(): { Instance }
	local found = {}
	for _, child in ServerStorage:GetChildren() do
		if child.Name == STORE_NAME and not child:IsA("Folder") then
			table.insert(found, child)
		end
	end
	return found
end

--[[
	True once anyone has synced into this place with team sync, including the
	older single-value log format.
]]
function TeamSync.placeUsesTeamSync(): boolean
	return ServerStorage:FindFirstChild(STORE_NAME) ~= nil
end

local function isStoreInstance(instance: Instance): boolean
	if instance.Parent == ServerStorage and instance.Name == STORE_NAME then
		return true
	end
	local store = findStore()
	return store ~= nil and instance:IsDescendantOf(store)
end

--[[
	Keeps Rojo from deleting the logs when ServerStorage is managed without
	$ignoreUnknownInstances.
]]
function TeamSync.protectStore(patch)
	for index = #patch.removed, 1, -1 do
		local removed = patch.removed[index]
		if typeof(removed) == "Instance" and isStoreInstance(removed) then
			table.remove(patch.removed, index)
		end
	end
end

-- Logs are read on every patch; only decode the ones that changed.
local decodedCache: { [string]: { raw: string, log: Policy.MachineLog } } = {}

local function decodeLog(name: string, raw: string): Policy.MachineLog
	local cached = decodedCache[name]
	if cached and cached.raw == raw then
		return cached.log
	end

	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	local log
	if ok and Policy.isMachineLog(decoded) then
		log = decoded
	else
		-- An unreadable log could have touched anything. Treat it as unknown
		-- history until everyone has caught up.
		Log.warn("Rojo team sync log ServerStorage.{}.{} is unreadable", STORE_NAME, name)
		log = Policy.newMachineLog(name, 0, "an unreadable sync log")
		log.counter = 1
		log.floor = 1
	end

	decodedCache[name] = { raw = raw, log = log }
	return log
end

function TeamSync.readLogs(): { Policy.MachineLog }
	local logs = {}
	local store = findStore()
	if store == nil then
		return logs
	end

	for _, child in store:GetChildren() do
		if child:IsA("StringValue") and child.Value ~= "" then
			table.insert(logs, decodeLog(child.Name, child.Value))
		end
	end
	return logs
end

--[[
	Log writes are appended to the sync they describe, so undoing a sync also
	undoes its record instead of leaving one without the other.
]]
local function withRecording(name: string, callback: () -> ())
	local recording = ChangeHistoryService:TryBeginRecording(name)
	callback()
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Append)
	end
end

local function ensureStore(): Folder
	local store = findStore()
	local legacy = legacyStores()
	if store and #legacy == 0 then
		return store
	end

	withRecording("Rojo: Set up team sync", function()
		for _, old in legacy do
			-- The single-value log from earlier versions can't be converted.
			-- Replacing it resets the history for this place.
			Log.warn("Replacing the old Rojo team sync log in ServerStorage.{}", STORE_NAME)
			old:Destroy()
		end

		if store == nil then
			store = Instance.new("Folder")
			store.Name = STORE_NAME
			store:SetAttribute(LOG_ID_ATTRIBUTE, HttpService:GenerateGUID(false))
			store.Parent = ServerStorage
		end
	end)

	return store :: Folder
end

local function logId(): string?
	local store = findStore()
	local id = store and store:GetAttribute(LOG_ID_ATTRIBUTE)
	return if type(id) == "string" then id else nil
end

local function setting(key: string): any
	return if plugin then plugin:GetSetting(key) else nil
end

local function setSetting(key: string, value: any)
	if plugin then
		plugin:SetSetting(key, value)
	end
end

local function machineId(): string
	local existing = setting("Rojo_teamSyncMachine")
	if type(existing) == "string" then
		return existing
	end

	local id = HttpService:GenerateGUID(false)
	setSetting("Rojo_teamSyncMachine", id)
	return id
end

local function localUserName(userId: number): string
	if Players.LocalPlayer then
		return Players.LocalPlayer.Name
	end
	if userId > 0 then
		local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
		if ok then
			return name
		end
	end
	return "user " .. tostring(userId)
end

--[[
	True when applying `update` wouldn't change anything: our files already
	match what's in the place.
]]
local function isNoopUpdate(instance: Instance, update, instanceMap): boolean
	if update.changedName ~= nil and update.changedName ~= instance.Name then
		return false
	end
	if update.changedClassName ~= nil and update.changedClassName ~= instance.ClassName then
		return false
	end

	for propertyName, encoded in update.changedProperties or {} do
		local readOk, current = getProperty(instance, propertyName)
		if not readOk then
			return false
		end
		local decodeOk, value = decodeValue(encoded, instanceMap)
		if not decodeOk or not trueEquals(current, value) then
			return false
		end
	end

	return true
end

local function pathOf(instance: Instance): string
	return instance:GetFullName()
end

local function childPath(parent: Instance, name: string): string
	return if parent == game then name else pathOf(parent) .. "." .. name
end

local function subtreeOf(added, rootId)
	local subtree = {}
	local function visit(id)
		local virtual = added[id]
		if virtual == nil or subtree[id] then
			return
		end
		subtree[id] = virtual
		for _, childId in virtual.Children or {} do
			visit(childId)
		end
	end
	visit(rootId)
	return subtree
end

local function findUnmapped(parent: Instance, name: string, className: string, instanceMap): Instance?
	for _, child in parent:GetChildren() do
		if child.Name == name and child.ClassName == className and instanceMap.fromInstances[child] == nil then
			return child
		end
	end
	return nil
end

--[[
	One connected session's view of team sync.
]]
local Session = {}
Session.__index = Session

function TeamSync.newSession(instanceMap, reconciler)
	local userId = StudioService:GetUserId()
	local machine = machineId()

	return setmetatable({
		__instanceMap = instanceMap,
		__reconciler = reconciler,
		__machine = machine,
		__userId = userId,
		__name = localUserName(userId),
		-- Held changes by path: { change, conflicts }.
		__held = {},
	}, Session)
end

function Session:__acksKey(): string?
	local id = logId()
	return if id then "Rojo_teamSyncAcks_" .. id else nil
end

function Session:__loadAcks(): Policy.Acks
	local key = self:__acksKey()
	local stored = key and setting(key)
	return if type(stored) == "table" then stored else {}
end

function Session:__saveAcks(acks: Policy.Acks)
	local key = self:__acksKey()
	if key then
		setSetting(key, acks)
	end
end

function Session:__myLog(): Policy.MachineLog
	for _, log in TeamSync.readLogs() do
		if log.machine == self.__machine then
			return log
		end
	end
	return Policy.newMachineLog(self.__machine, self.__userId, self.__name)
end

--[[
	Splits `patch` into what can be applied now and what has to be held back
	because it would overwrite another machine's changes. Returns the patch to
	apply, the changes it makes (to record once applied), and conflicts for
	anything newly held.

	`isInitial` is true for the catch-up patch when connecting. Anything
	another machine changed that isn't in that patch already matches our files.
]]
function Session:filter(patch, isInitial: boolean)
	local logs = TeamSync.readLogs()
	local acks = self:__loadAcks()
	local instanceMap = self.__instanceMap
	local toApply = PatchSet.newEmpty()
	local applied = {}
	local newlyHeld = {}
	local heldHere = {}

	local function conflictsFor(changes)
		local found = {}
		for _, change in changes do
			for _, conflict in Policy.conflictsFor(change, logs, self.__machine, acks) do
				table.insert(found, conflict)
			end
		end
		return found
	end

	local function hold(changes, conflicts)
		local alreadyHeld = true
		for _, change in changes do
			alreadyHeld = alreadyHeld and self.__held[change.path] ~= nil
			self.__held[change.path] = { change = change, conflicts = conflicts }
			table.insert(heldHere, change)
		end
		-- Saving a held script again shouldn't announce it again.
		if not alreadyHeld then
			for _, conflict in conflicts do
				table.insert(newlyHeld, conflict)
			end
		end
	end

	local function accept(changes)
		for _, change in changes do
			self.__held[change.path] = nil
			table.insert(applied, change)
		end
	end

	local function caughtUp(changes)
		for _, change in changes do
			self.__held[change.path] = nil
			acks = Policy.catchUpOn(acks, logs, self.__machine, change)
		end
	end

	local run

	local function handleAdded(id, virtual, added)
		local subtree = subtreeOf(added, id)
		local parent = instanceMap.fromIds[virtual.Parent]
		if parent == nil then
			-- Let the reconciler report it; there's nowhere to put it.
			for subId, subVirtual in subtree do
				toApply.added[subId] = subVirtual
			end
			return
		end

		local changes = { { path = childPath(parent, virtual.Name), tree = true } }

		local existing = findUnmapped(parent, virtual.Name, virtual.ClassName, instanceMap)
		if existing then
			-- Someone else already synced this into the place. Match it up
			-- instead of adding a duplicate, then handle what still differs.
			self.__reconciler:hydrate(subtree, id, existing)
			local ok, inner = self.__reconciler:diff(subtree, id)
			if not ok then
				Log.warn("Rojo team sync couldn't compare {} with its copy in the place", changes[1].path)
				hold(changes, conflictsFor(changes))
				return
			end
			if PatchSet.isEmpty(inner) then
				caughtUp(changes)
			else
				run(inner)
			end
			return
		end

		local conflicts = conflictsFor(changes)
		if #conflicts > 0 then
			hold(changes, conflicts)
		else
			for subId, subVirtual in subtree do
				toApply.added[subId] = subVirtual
			end
			accept(changes)
		end
	end

	function run(current)
		for _, removed in current.removed do
			local instance = if typeof(removed) == "Instance" then removed else instanceMap.fromIds[removed]
			if instance == nil or instance.Parent == nil then
				table.insert(toApply.removed, removed)
				continue
			end

			local changes = { { path = pathOf(instance), tree = true } }
			local conflicts = conflictsFor(changes)
			if #conflicts > 0 then
				hold(changes, conflicts)
			else
				table.insert(toApply.removed, removed)
				accept(changes)
			end
		end

		for _, update in current.updated do
			local instance = instanceMap.fromIds[update.id]
			if instance == nil or instance == game then
				table.insert(toApply.updated, update)
				continue
			end

			local renamed = update.changedName ~= nil or update.changedClassName ~= nil
			local changes = { { path = pathOf(instance), tree = renamed } }
			if update.changedName ~= nil and instance.Parent then
				table.insert(changes, { path = childPath(instance.Parent, update.changedName), tree = true })
			end

			local conflicts = conflictsFor(changes)
			if #conflicts == 0 then
				table.insert(toApply.updated, update)
				accept(changes)
			elseif isNoopUpdate(instance, update, instanceMap) then
				caughtUp(changes)
			else
				hold(changes, conflicts)
			end
		end

		for id, virtual in current.added do
			if current.added[virtual.Parent] == nil then
				handleAdded(id, virtual, current.added)
			end
		end
	end

	run(patch)

	if isInitial then
		acks = Policy.catchUpExcept(acks, logs, self.__machine, heldHere)
	end
	self:__saveAcks(acks)

	return toApply, applied, newlyHeld
end

--[[
	Records changes we just applied in our log. `forced` means they were held
	and the user chose to sync over the other changes anyway.
]]
function Session:record(changes: { Policy.Change }, forced: boolean?)
	if #changes == 0 then
		return
	end

	local store = ensureStore()

	if forced then
		local logs = TeamSync.readLogs()
		local acks = self:__loadAcks()
		for _, change in changes do
			acks = Policy.catchUpOn(acks, logs, self.__machine, change)
		end
		self:__saveAcks(acks)
	end

	-- The counter must never go backwards, even if an undo rolls back our log:
	-- other machines treat a counter they've seen as already caught up.
	local log = self:__myLog()
	local counterKey = "Rojo_teamSyncCounter_" .. tostring(logId())
	local lastCounter = setting(counterKey)
	if type(lastCounter) == "number" and lastCounter > log.counter then
		log = table.clone(log)
		log.counter = lastCounter
	end

	log = Policy.recordWrites(log, changes, os.time())
	log.name = self.__name
	log.userId = self.__userId
	setSetting(counterKey, log.counter)

	local encoded = HttpService:JSONEncode(log)
	while #encoded > MAX_LOG_LENGTH and next(log.writes) ~= nil do
		-- Drop the oldest writes until it fits; the floor keeps it safe.
		local oldestPath, oldest = nil, math.huge
		for path, write in log.writes do
			if write.c < oldest then
				oldestPath, oldest = path, write.c
			end
		end
		log.writes[oldestPath] = nil
		log.floor = math.max(log.floor, oldest)
		encoded = HttpService:JSONEncode(log)
	end

	withRecording("Rojo: Update team sync log", function()
		local value = store:FindFirstChild(self.__machine)
		if value == nil or not value:IsA("StringValue") then
			value = Instance.new("StringValue")
			value.Name = self.__machine
			value.Parent = store
		end
		value.Value = encoded
	end)
end

function Session:heldChanges(): { Policy.Change }
	local changes = {}
	for _, item in self.__held do
		table.insert(changes, item.change)
	end
	return changes
end

function Session:heldConflicts(): { Policy.Conflict }
	local conflicts = {}
	for _, item in self.__held do
		for _, conflict in item.conflicts do
			table.insert(conflicts, conflict)
		end
	end
	return conflicts
end

--[[
	From a fresh catch-up patch, picks out everything that was being held, for
	"Sync anyway". Clears the held list. Returns the patch and its changes.
]]
function Session:takeHeld(patch)
	local held = self:heldChanges()
	local instanceMap = self.__instanceMap
	local selected = PatchSet.newEmpty()
	local changes = {}

	local function isHeld(change)
		for _, heldChange in held do
			if Policy.overlaps(change, heldChange) then
				return true
			end
		end
		return false
	end

	for _, removed in patch.removed do
		local instance = if typeof(removed) == "Instance" then removed else instanceMap.fromIds[removed]
		if instance and instance.Parent then
			local change = { path = pathOf(instance), tree = true }
			if isHeld(change) then
				table.insert(selected.removed, removed)
				table.insert(changes, change)
			end
		end
	end

	for _, update in patch.updated do
		local instance = instanceMap.fromIds[update.id]
		if instance and instance ~= game then
			local change = {
				path = pathOf(instance),
				tree = update.changedName ~= nil or update.changedClassName ~= nil,
			}
			if isHeld(change) then
				table.insert(selected.updated, update)
				table.insert(changes, change)
			end
		end
	end

	for id, virtual in patch.added do
		local parent = instanceMap.fromIds[virtual.Parent]
		if patch.added[virtual.Parent] == nil and parent then
			local change = { path = childPath(parent, virtual.Name), tree = true }
			if isHeld(change) then
				for subId, subVirtual in subtreeOf(patch.added, id) do
					selected.added[subId] = subVirtual
				end
				table.insert(changes, change)
			end
		end
	end

	table.clear(self.__held)
	return selected, changes
end

return TeamSync
