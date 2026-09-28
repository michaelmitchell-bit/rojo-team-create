--[[
	Team sync rules, kept free of Roblox APIs so they can be tested anywhere.

	A shared place carries a sync log: one entry per sync session, listing the
	instance paths that session changed. Each person remembers the last entry
	they wrote (their "base"). Before syncing, their catch-up patch is turned into
	a list of changes and compared with every entry written since their base:

	- Nothing overlaps: they already have everyone else's changes, or only touch
	  instances nobody else did. The sync goes ahead.
	- Something overlaps: syncing would overwrite someone else's work. The sync
	  is refused until they reconcile it through their own workflow (version
	  control, shared drive, whatever) and reconnect, or explicitly override.

	No version control is assumed. If someone has pulled in another person's
	change exactly, that instance simply doesn't appear in their patch.
]]

export type Change = {
	path: string,
	-- True when the whole subtree at `path` was added, removed, or renamed.
	tree: boolean,
}

export type Entry = {
	id: string,
	userId: number,
	name: string,
	at: number,
	-- The session changed more than MAX_CHANGES instances; treat it as having
	-- changed everything.
	all: boolean?,
	forced: boolean?,
	changes: { Change },
}

export type Log = {
	version: number,
	logId: string,
	-- Older entries were dropped, so a base missing from the log can't be
	-- trusted to mean "nothing happened since".
	truncated: boolean,
	entries: { Entry },
}

export type Conflict = {
	path: string,
	entry: Entry?,
}

export type Decision = {
	allowed: boolean,
	reason: string?,
	conflicts: { Conflict }?,
	canForce: boolean,
	forced: boolean?,
}

local Policy = {}

Policy.VERSION = 1
Policy.MAX_ENTRIES = 40
Policy.MAX_CHANGES = 50
Policy.MAX_LISTED_CONFLICTS = 12

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

function Policy.isLog(value: any): boolean
	return type(value) == "table"
		and value.version == Policy.VERSION
		and type(value.logId) == "string"
		and type(value.entries) == "table"
end

function Policy.newLog(logId: string): Log
	return {
		version = Policy.VERSION,
		logId = logId,
		truncated = false,
		entries = {},
	}
end

--[[
	Returns the entries written after `baseId`, and whether that list is known
	to be complete.
]]
function Policy.entriesSince(log: Log, baseId: string?): ({ Entry }, boolean)
	if baseId ~= nil then
		for index = #log.entries, 1, -1 do
			if log.entries[index].id == baseId then
				return table.move(log.entries, index + 1, #log.entries, 1, {}), true
			end
		end
	end

	-- The base isn't in the log: we've never synced here, or our entry was
	-- trimmed. Every entry counts, and if the log was trimmed, so does the
	-- unknown history before it.
	return table.clone(log.entries), not log.truncated
end

function Policy.findConflicts(changes: { Change }, entries: { Entry }, complete: boolean): { Conflict }
	local conflicts = {}

	for _, change in changes do
		local culprit = nil
		local found = not complete

		for index = #entries, 1, -1 do
			local entry = entries[index]
			local hit = entry.all == true
			if not hit then
				for _, theirs in entry.changes do
					if Policy.overlaps(change, theirs) then
						hit = true
						break
					end
				end
			end

			if hit then
				culprit = entry
				found = true
				break
			end
		end

		if found then
			table.insert(conflicts, { path = change.path, entry = culprit })
		end
	end

	return conflicts
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

function Policy.describeConflicts(conflicts: { Conflict }, now: number): string
	local lines = {}

	for index, conflict in conflicts do
		if index > Policy.MAX_LISTED_CONFLICTS then
			table.insert(lines, string.format("…and %d more", #conflicts - Policy.MAX_LISTED_CONFLICTS))
			break
		end

		local who = if conflict.entry
			then string.format("%s, %s", conflict.entry.name, elapsedText(now - conflict.entry.at))
			else "history older than the sync log"
		table.insert(lines, string.format("• %s (%s)", conflict.path, who))
	end

	return table.concat(lines, "\n")
end

--[[
	Decides whether a sync may go ahead.

	`log` is the place's sync log (nil if it has none), `baseId` the last entry
	this person wrote to it, `changes` what their catch-up patch would change.
]]
function Policy.evaluate(options: {
	teamSync: boolean,
	log: Log?,
	baseId: string?,
	changes: { Change },
	force: boolean,
	now: number,
}): Decision
	local log = options.log

	if not options.teamSync then
		if log == nil or #log.entries == 0 then
			return { allowed = true, canForce = false }
		end

		return {
			allowed = false,
			canForce = false,
			reason = "This place uses Rojo team sync, but the project being served doesn't."
				.. '\nAdd "teamSync": true to the project file (or serve the project that has it) and reconnect.',
		}
	end

	if log == nil or #log.entries == 0 then
		return { allowed = true, canForce = false }
	end

	local entries, complete = Policy.entriesSince(log, options.baseId)
	if complete and #entries == 0 then
		return { allowed = true, canForce = false }
	end

	local conflicts = Policy.findConflicts(options.changes, entries, complete)
	if #conflicts == 0 then
		return { allowed = true, canForce = false }
	end

	if options.force then
		return { allowed = true, canForce = false, forced = true, conflicts = conflicts }
	end

	return {
		allowed = false,
		canForce = true,
		conflicts = conflicts,
		reason = "Rojo team sync stopped this sync: it would overwrite changes someone else synced into this place.\n\n"
			.. Policy.describeConflicts(conflicts, options.now)
			.. "\n\nGet their changes into your files (however your team shares code), then reconnect."
			.. "\nIf you've already merged them by hand, choose Sync anyway.",
	}
end

--[[
	Folds new changes into a list, dropping duplicates and anything already
	covered by a subtree change.
]]
function Policy.mergeChanges(existing: { Change }, incoming: { Change }): { Change }
	local merged = table.clone(existing)

	for _, change in incoming do
		local covered = false
		for index = #merged, 1, -1 do
			local other = merged[index]
			local sameOrWider = other.path == change.path and (other.tree or not change.tree)
			if sameOrWider or (other.tree and isWithin(change.path, other.path)) then
				covered = true
				break
			elseif change.tree and isWithin(other.path, change.path) then
				table.remove(merged, index)
			end
		end

		if not covered then
			table.insert(merged, change)
		end
	end

	return merged
end

--[[
	Adds a session's latest changes to its log entry. Past MAX_CHANGES the entry
	stops listing paths and counts as having changed everything.
]]
function Policy.recordChanges(entry: Entry, changes: { Change }, now: number): Entry
	local updated = table.clone(entry)
	updated.at = now

	if entry.all then
		return updated
	end

	local merged = Policy.mergeChanges(entry.changes, changes)
	if #merged > Policy.MAX_CHANGES then
		updated.all = true
		updated.changes = {}
	else
		updated.changes = merged
	end

	return updated
end

--[[
	Adds `entry` to the end of the log, or replaces it if it's already the last
	entry. Trims the oldest entries past MAX_ENTRIES.
]]
function Policy.withEntry(log: Log, entry: Entry): Log
	local entries = table.clone(log.entries)
	local last = entries[#entries]

	if last ~= nil and last.id == entry.id then
		entries[#entries] = entry
	else
		table.insert(entries, entry)
	end

	local truncated = log.truncated
	while #entries > Policy.MAX_ENTRIES do
		table.remove(entries, 1)
		truncated = true
	end

	return {
		version = log.version,
		logId = log.logId,
		truncated = truncated,
		entries = entries,
	}
end

--[[
	Drops the oldest entries until `encode(log)` fits in `maxLength`.
]]
function Policy.fitToLength(log: Log, maxLength: number, encode: (Log) -> string): (Log, string)
	local encoded = encode(log)

	while #encoded > maxLength and #log.entries > 1 do
		local entries = table.clone(log.entries)
		table.remove(entries, 1)
		log = {
			version = log.version,
			logId = log.logId,
			truncated = true,
			entries = entries,
		}
		encoded = encode(log)
	end

	return log, encoded
end

--[[
	Returns the first entry written after ours by someone else's session, if
	any: our view of the place is stale and we have to stop syncing.
]]
function Policy.supersededBy(log: Log?, entryId: string): Entry?
	if log == nil then
		return nil
	end

	for index = #log.entries, 1, -1 do
		local entry = log.entries[index]
		if entry.id == entryId then
			return log.entries[index + 1]
		end
	end

	-- Our entry is gone: either the log was reset or it was trimmed because
	-- many sessions synced after ours. Either way, someone else synced.
	return log.entries[#log.entries]
end

return Policy
