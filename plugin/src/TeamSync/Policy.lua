--[[
	Team sync rules, kept free of Roblox APIs so they can be tested anywhere.

	Several people can be connected to the same place at once. Each machine
	keeps its own write log in the place: the instance paths it synced, each
	stamped with that machine's own counter. Separate logs mean two people
	syncing at the same moment can't overwrite each other's records.

	Every machine also remembers, per other machine, how far into that
	machine's writes it has caught up ("acks"). A change is held back when it
	touches something another machine wrote that we haven't caught up to, since
	applying it would overwrite their work. We catch up on a path when our files
	turn out to match what they synced, or when we deliberately sync over it.
]]

export type Change = {
	path: string,
	-- True when the whole subtree at `path` was added, removed, or renamed.
	tree: boolean,
}

export type Write = {
	c: number,
	tree: boolean,
	at: number,
}

export type MachineLog = {
	version: number,
	machine: string,
	userId: number,
	name: string,
	counter: number,
	-- Highest counter among writes dropped to keep the log small.
	floor: number,
	writes: { [string]: Write },
}

export type MachineAcks = {
	-- Every write with a counter at or below this is caught up.
	all: number,
	paths: { [string]: number },
}

export type Acks = { [string]: MachineAcks }

export type Conflict = {
	path: string,
	machine: string,
	name: string,
	at: number?,
	-- The other machine dropped writes we never caught up on, so we can't tell
	-- what they touched.
	unknown: boolean?,
}

local Policy = {}

Policy.VERSION = 2
Policy.MAX_WRITES = 500
Policy.MAX_LISTED = 12

local function isWithin(path: string, ancestor: string): boolean
	return path == ancestor or string.sub(path, 1, #ancestor + 1) == ancestor .. "."
end

--[[
	Two changes overlap when they touch the same instance, or when one replaced
	a whole subtree that contains the other.
]]
function Policy.overlaps(a: Change, b: Change): boolean
	if a.path == b.path then
		return true
	end

	return (a.tree and isWithin(b.path, a.path)) or (b.tree and isWithin(a.path, b.path))
end

function Policy.newMachineLog(machine: string, userId: number, name: string): MachineLog
	return {
		version = Policy.VERSION,
		machine = machine,
		userId = userId,
		name = name,
		counter = 0,
		floor = 0,
		writes = {},
	}
end

function Policy.isMachineLog(value: any): boolean
	return type(value) == "table"
		and value.version == Policy.VERSION
		and type(value.machine) == "string"
		and type(value.counter) == "number"
		and type(value.floor) == "number"
		and type(value.writes) == "table"
end

local function machineAcks(acks: Acks, machine: string): MachineAcks
	return acks[machine] or { all = 0, paths = {} }
end

function Policy.caughtUpTo(acks: Acks, machine: string, path: string): number
	local entry = machineAcks(acks, machine)
	return math.max(entry.all, entry.paths[path] or 0)
end

local function hasUnknownHistory(log: MachineLog, acks: Acks): boolean
	return log.floor > machineAcks(acks, log.machine).all
end

--[[
	Other machines' writes that `change` would overwrite.
]]
function Policy.conflictsFor(change: Change, logs: { MachineLog }, myMachine: string, acks: Acks): { Conflict }
	local conflicts = {}

	for _, log in logs do
		if log.machine == myMachine then
			continue
		end

		if hasUnknownHistory(log, acks) then
			table.insert(conflicts, { path = change.path, machine = log.machine, name = log.name, unknown = true })
			continue
		end

		for path, write in log.writes do
			if
				write.c > Policy.caughtUpTo(acks, log.machine, path)
				and Policy.overlaps(change, { path = path, tree = write.tree })
			then
				table.insert(conflicts, { path = path, machine = log.machine, name = log.name, at = write.at })
			end
		end
	end

	return conflicts
end

--[[
	Collapses fully caught-up machines back to a single number so acks don't
	grow without bound.
]]
local function compact(entry: MachineAcks, log: MachineLog): MachineAcks
	if hasUnknownHistory(log, { [log.machine] = entry }) then
		return entry
	end

	for path, write in log.writes do
		if write.c > math.max(entry.all, entry.paths[path] or 0) then
			return entry
		end
	end

	return { all = log.counter, paths = {} }
end

--[[
	Marks every other machine's write that overlaps `change` as caught up. Used
	when our files turn out to match theirs, or when we sync over them on purpose.
]]
function Policy.catchUpOn(acks: Acks, logs: { MachineLog }, myMachine: string, change: Change): Acks
	local updated = table.clone(acks)

	for _, log in logs do
		if log.machine == myMachine then
			continue
		end

		local entry = machineAcks(updated, log.machine)
		local paths = table.clone(entry.paths)
		local changed = false

		for path, write in log.writes do
			if Policy.overlaps(change, { path = path, tree = write.tree }) and write.c > (paths[path] or 0) then
				paths[path] = write.c
				changed = true
			end
		end

		if changed then
			updated[log.machine] = compact({ all = entry.all, paths = paths }, log)
		end
	end

	return updated
end

--[[
	After a full catch-up sync, anything another machine wrote that we're not
	holding back already matches our files: our sync would have touched it
	otherwise. Catch up on all of it.
]]
function Policy.catchUpExcept(acks: Acks, logs: { MachineLog }, myMachine: string, held: { Change }): Acks
	local updated = table.clone(acks)

	for _, log in logs do
		if log.machine == myMachine then
			continue
		end

		local entry = machineAcks(updated, log.machine)
		local paths = table.clone(entry.paths)
		local blocked = false

		for path, write in log.writes do
			local isHeld = false
			for _, change in held do
				if Policy.overlaps(change, { path = path, tree = write.tree }) then
					isHeld = true
					break
				end
			end

			if isHeld then
				blocked = true
			else
				paths[path] = write.c
			end
		end

		if not blocked and #held == 0 then
			-- Nothing at all is held, so even writes they dropped must match.
			updated[log.machine] = { all = log.counter, paths = {} }
		else
			updated[log.machine] = compact({ all = entry.all, paths = paths }, log)
		end
	end

	return updated
end

--[[
	Records a batch of our own changes in our log.
]]
function Policy.recordWrites(log: MachineLog, changes: { Change }, now: number): MachineLog
	if #changes == 0 then
		return log
	end

	local counter = log.counter + 1
	local writes = table.clone(log.writes)
	for _, change in changes do
		local existing = writes[change.path]
		writes[change.path] = {
			c = counter,
			tree = change.tree or (existing ~= nil and existing.tree),
			at = now,
		}
	end

	local floor = log.floor
	local count = 0
	for _ in writes do
		count += 1
	end

	if count > Policy.MAX_WRITES then
		local ordered = {}
		for path, write in writes do
			table.insert(ordered, { path = path, c = write.c })
		end
		table.sort(ordered, function(a, b)
			return a.c < b.c
		end)

		for index = 1, count - Policy.MAX_WRITES do
			writes[ordered[index].path] = nil
			floor = math.max(floor, ordered[index].c)
		end
	end

	return {
		version = log.version,
		machine = log.machine,
		userId = log.userId,
		name = log.name,
		counter = counter,
		floor = floor,
		writes = writes,
	}
end

local function elapsedText(seconds: number): string
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return string.format("%d min ago", seconds // 60)
	elseif seconds < 86400 then
		return string.format("%d h ago", seconds // 3600)
	end
	return string.format("%d d ago", seconds // 86400)
end

--[[
	One line per held path, naming who changed it.
]]
function Policy.describe(conflicts: { Conflict }, now: number): string
	local lines = {}
	local seen = {}

	for _, conflict in conflicts do
		local key = conflict.path .. "\0" .. conflict.machine
		if seen[key] then
			continue
		end
		seen[key] = true

		if #lines >= Policy.MAX_LISTED then
			table.insert(lines, "…and more")
			break
		end

		local when = if conflict.unknown
			then "older changes you haven't seen"
			elseif conflict.at then elapsedText(now - conflict.at)
			else "earlier"
		table.insert(lines, string.format("• %s (%s, %s)", conflict.path, conflict.name, when))
	end

	return table.concat(lines, "\n")
end

return Policy
