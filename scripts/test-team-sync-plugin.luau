--[[
	Runs two copies of the real plugin code (TeamSync, InstanceMap, Reconciler,
	PatchSet, RbxDom) against one shared place under Lune, the way two people
	in Team Create would be. Each "machine" has its own module instances and
	plugin settings, and its own Rojo server state, described as a list of
	scripts.

	lune run scripts/test-team-sync-plugin
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

-- Studio-only APIs the plugin calls, stubbed on the shared place.
local currentUser = 0
roblox.implementMethod("StudioService", "GetUserId", function()
	return currentUser
end)
roblox.implementMethod("ChangeHistoryService", "TryBeginRecording", function()
	return "recording"
end)
roblox.implementMethod("ChangeHistoryService", "FinishRecording", function() end)
roblox.implementMethod("HttpService", "JSONEncode", function(_, value)
	return serde.encode("json", value)
end)
roblox.implementMethod("HttpService", "JSONDecode", function(_, text)
	return serde.decode("json", text)
end)
local guidCounter = 0
roblox.implementMethod("HttpService", "GenerateGUID", function()
	guidCounter += 1
	return string.format("GUID-%04d", guidCounter)
end)
roblox.implementMethod("Players", "GetNameFromUserIdAsync", function(_, userId)
	return "user" .. tostring(userId)
end)
-- Rojo reads and writes script source through the script editor.
roblox.implementMethod("ScriptEditorService", "GetEditorSource", function(_, script)
	return script.Source
end)
roblox.implementMethod("ScriptEditorService", "UpdateSourceAsync", function(_, script, callback)
	script.Source = callback(script.Source)
end)

--[[ Module loader: mirrors plugin.project.json closely enough for these modules. ]]

local function stripExtension(name: string): string?
	for _, ext in { ".luau", ".lua" } do
		if string.sub(name, -#ext) == ext then
			local base = string.sub(name, 1, -#ext - 1)
			if string.find(base, "%.spec$") or string.find(base, "%.server$") or string.find(base, "%.client$") then
				return nil
			end
			return base
		end
	end
	return nil
end

local function buildNode(name, fsPath, parent)
	local node = { name = name, parent = parent, children = {} }

	if fs.isDir(fsPath) then
		local projectPath = fsPath .. "/default.project.json"
		if fs.isFile(projectPath) then
			local project = serde.decode("json", fs.readFile(projectPath))
			if project.tree and project.tree["$path"] then
				return buildNode(name, fsPath .. "/" .. project.tree["$path"], parent)
			end
		end

		for _, init in { "init.luau", "init.lua" } do
			if fs.isFile(fsPath .. "/" .. init) then
				node.source = fsPath .. "/" .. init
			end
		end

		for _, entry in fs.readDir(fsPath) do
			local entryPath = fsPath .. "/" .. entry
			if fs.isDir(entryPath) then
				node.children[entry] = buildNode(entry, entryPath, node)
			elseif entry ~= "init.lua" and entry ~= "init.luau" then
				local base = stripExtension(entry)
				if base then
					node.children[base] = { name = base, parent = node, children = {}, source = entryPath }
				elseif string.sub(entry, -5) == ".json" and not string.find(entry, "project") then
					local base = string.sub(entry, 1, -6)
					node.children[base] = { name = base, parent = node, children = {}, json = entryPath }
				elseif string.sub(entry, -4) == ".txt" then
					local base = string.sub(entry, 1, -5)
					node.children[base] = { name = base, parent = node, children = {}, value = fs.readFile(entryPath) }
				end
			end
		end
	else
		node.source = fsPath
	end

	return node
end

local function newMachine(machineName: string, userId: number)
	local rojo = { name = "Rojo", children = {} }
	rojo.children.Plugin = buildNode("Plugin", "plugin/src", rojo)
	local packages = buildNode("Packages", "plugin/Packages", rojo)
	for name, path in { Log = "plugin/log", Http = "plugin/http", Fmt = "plugin/fmt", RbxDom = "plugin/rbx_dom_lua" } do
		packages.children[name] = buildNode(name, path, packages)
	end
	rojo.children.Packages = packages
	rojo.children.Version = { name = "Version", parent = rojo, children = {}, value = fs.readFile("plugin/Version.txt") }

	local settings = {}
	local pluginStub = {
		GetSetting = function(_, key)
			return settings[key]
		end,
		SetSetting = function(_, key, value)
			-- Plugin settings round-trip through JSON in Studio.
			settings[key] = if type(value) == "table" then serde.decode("json", serde.encode("json", value)) else value
		end,
	}

	local proxies = {}
	local loaded = {}
	local proxyOf

	local function requireNode(node)
		if loaded[node] ~= nil then
			return loaded[node]
		end
		if node.json then
			loaded[node] = serde.decode("json", fs.readFile(node.json))
			return loaded[node]
		end
		assert(node.source, "not a module: " .. node.name)

		-- Lune replaces the environment's metatable when it injects its own
		-- globals, so Roblox globals are copied in directly.
		local env = {}
		for key, value in roblox do
			env[key] = value
		end
		env.script = proxyOf(node)
		env.plugin = pluginStub
		env.game = _G.__place
		env.workspace = _G.__place:GetService("Workspace")
		env.task = task
		env.require = function(target)
			return requireNode(rawget(target, "__node"))
		end

		local chunk = luau.load(fs.readFile(node.source), { debugName = machineName .. ":" .. node.source, environment = env })
		loaded[node] = chunk()
		return loaded[node]
	end

	function proxyOf(node)
		if proxies[node] then
			return proxies[node]
		end
		local proxy = setmetatable({ __node = node }, {
			__index = function(_, key)
				if key == "Parent" then
					return node.parent and proxyOf(node.parent)
				elseif key == "Name" then
					return node.name
				elseif key == "Value" then
					return node.value
				elseif key == "FindFirstAncestor" then
					return function(_, name)
						local current = node.parent
						while current do
							if current.name == name then
								return proxyOf(current)
							end
							current = current.parent
						end
						return nil
					end
				elseif key == "FindFirstAncestorWhichIsA" then
					return function()
						return nil
					end
				elseif key == "FindFirstChild" then
					return function(_, name)
						return node.children[name] and proxyOf(node.children[name])
					end
				end
				local child = node.children[key]
				if child then
					return proxyOf(child)
				end
				error(string.format("%s is not a valid member of %s", tostring(key), node.name), 2)
			end,
		})
		proxies[node] = proxy
		return proxy
	end

	local Plugin = rojo.children.Plugin.children
	local TeamSync = requireNode(Plugin.TeamSync)
	local InstanceMap = requireNode(Plugin.InstanceMap)
	local Reconciler = requireNode(Plugin.Reconciler)
	local PatchSet = requireNode(Plugin.PatchSet)

	-- Lune instances have no change signals; the reconciler doesn't need them here.
	InstanceMap.__connectSignals = function() end

	return {
		name = machineName,
		userId = userId,
		TeamSync = TeamSync,
		InstanceMap = InstanceMap,
		Reconciler = Reconciler,
		PatchSet = PatchSet,
		settings = settings,
	}
end

--[[ A fake Rojo server: a flat list of scripts under ServerScriptService. ]]

local idCounter = 0
local function newId()
	idCounter += 1
	return string.format("%032x", idCounter)
end

local function newServer(scripts: { [string]: string })
	local server = { ids = { root = newId(), sss = newId() }, scripts = {} }
	for name, source in scripts do
		server.scripts[name] = source
		server.ids[name] = newId()
	end
	return server
end

local function virtualTree(server)
	local instances = {}
	local sssChildren = {}
	for name, source in server.scripts do
		local id = server.ids[name]
		table.insert(sssChildren, id)
		instances[id] = {
			Id = id,
			Parent = server.ids.sss,
			Name = name,
			ClassName = "ModuleScript",
			Properties = { Source = { String = source } },
			Children = {},
			Metadata = { ignoreUnknownInstances = false },
		}
	end
	instances[server.ids.sss] = {
		Id = server.ids.sss,
		Parent = server.ids.root,
		Name = "ServerScriptService",
		ClassName = "ServerScriptService",
		Properties = {},
		Children = sssChildren,
		Metadata = { ignoreUnknownInstances = false },
	}
	instances[server.ids.root] = {
		Id = server.ids.root,
		Parent = "00000000000000000000000000000000",
		Name = "Place",
		ClassName = "DataModel",
		Properties = {},
		Children = { server.ids.sss },
		Metadata = { ignoreUnknownInstances = true },
	}
	return instances
end

--[[ A connected plugin: mirrors ServeSession's team sync flow. ]]

local function connect(machine, server)
	currentUser = machine.userId
	local instanceMap = machine.InstanceMap.new(nil)
	local reconciler = machine.Reconciler.new(instanceMap)
	local tree = virtualTree(server)

	reconciler:hydrate(tree, server.ids.root, _G.__place)
	local ok, catchUp = reconciler:diff(tree, server.ids.root)
	assert(ok, "diff failed")

	-- The fake server doesn't send the root's name; ignore DataModel updates.
	for index = #catchUp.updated, 1, -1 do
		if instanceMap.fromIds[catchUp.updated[index].id] == _G.__place then
			table.remove(catchUp.updated, index)
		end
	end

	machine.TeamSync.protectStore(catchUp)
	local session = machine.TeamSync.newSession(instanceMap, reconciler)
	local toApply, changes, newlyHeld = session:filter(catchUp, true)
	reconciler:applyPatch(toApply)
	session:record(changes)

	return {
		machine = machine,
		server = server,
		session = session,
		instanceMap = instanceMap,
		reconciler = reconciler,
		lastHeld = newlyHeld,
	}
end

-- What the server would send when a file changes, is added, or is deleted.
local function editFile(conn, name, source)
	currentUser = conn.machine.userId
	local server = conn.server
	local patch = conn.machine.PatchSet.newEmpty()

	if source == nil then
		server.scripts[name] = nil
		table.insert(patch.removed, server.ids[name])
	elseif server.scripts[name] == nil then
		server.scripts[name] = source
		server.ids[name] = server.ids[name] or newId()
		local id = server.ids[name]
		patch.added[id] = {
			Id = id,
			Parent = server.ids.sss,
			Name = name,
			ClassName = "ModuleScript",
			Properties = { Source = { String = source } },
			Children = {},
			Metadata = { ignoreUnknownInstances = false },
		}
	else
		server.scripts[name] = source
		table.insert(patch.updated, {
			id = server.ids[name],
			changedProperties = { Source = { String = source } },
		})
	end

	local toApply, changes, newlyHeld = conn.session:filter(patch, false)
	conn.reconciler:applyPatch(toApply)
	conn.session:record(changes)
	conn.lastHeld = newlyHeld
	return newlyHeld
end

local function syncAnyway(conn)
	currentUser = conn.machine.userId
	local tree = virtualTree(conn.server)
	conn.reconciler:hydrate(tree, conn.server.ids.root, _G.__place)
	local _, patch = conn.reconciler:diff(tree, conn.server.ids.root)
	conn.machine.TeamSync.protectStore(patch)
	local selected, changes = conn.session:takeHeld(patch)
	conn.reconciler:applyPatch(selected)
	conn.session:record(changes, true)
end

local function placeScripts()
	local result = {}
	for _, child in _G.__place:GetService("ServerScriptService"):GetChildren() do
		result[child.Name] = (result[child.Name] or 0) + 1
	end
	return result
end

local function sourceOf(name)
	local child = _G.__place:GetService("ServerScriptService"):FindFirstChild(name)
	return child and child.Source
end

--[[ Tests ]]

local passes, failures = 0, 0

local function test(name, body)
	idCounter = 0
	_G.__place = roblox.Instance.new("DataModel")
	-- Studio places always have their services; Lune creates them on demand.
	_G.__place:GetService("ServerScriptService")
	_G.__place:GetService("ServerStorage")
	local ok, err = pcall(body)
	if ok then
		passes += 1
	else
		failures += 1
		print("FAIL " .. name .. "\n  " .. tostring(err))
	end
end

local function expectEqual(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
	end
end

local base = { Shop = "shop v1", Inventory = "inv v1" }

local function twoPeople()
	local alexMachine = newMachine("alex", 101)
	local samMachine = newMachine("sam", 202)
	local alex = connect(alexMachine, newServer(table.clone(base)))
	local sam = connect(samMachine, newServer(table.clone(base)))
	return alex, sam
end

test("both people connect to the same place without anything held", function()
	local alex, sam = twoPeople()
	expectEqual(#alex.lastHeld, 0, "alex held")
	expectEqual(#sam.lastHeld, 0, "sam held")
	expectEqual(sourceOf("Shop"), "shop v1", "shop")
end)

test("edits to different scripts both sync live", function()
	local alex, sam = twoPeople()
	expectEqual(#editFile(alex, "Shop", "shop by alex"), 0, "alex held")
	expectEqual(#editFile(sam, "Inventory", "inv by sam"), 0, "sam held")
	expectEqual(sourceOf("Shop"), "shop by alex", "shop")
	expectEqual(sourceOf("Inventory"), "inv by sam", "inventory")
end)

test("a stale copy of someone else's script is held, not synced over them", function()
	local alex, sam = twoPeople()
	editFile(alex, "Shop", "shop by alex")
	local held = editFile(sam, "Shop", "shop by sam without alex's change")
	expectEqual(#held, 1, "held")
	expectEqual(held[1].name, "user101", "who")
	expectEqual(sourceOf("Shop"), "shop by alex", "alex's version survives")
end)

test("pulling their change catches up, then your own edits sync again", function()
	local alex, sam = twoPeople()
	editFile(alex, "Shop", "shop by alex")
	editFile(sam, "Shop", "shop by sam without alex's change")
	-- Sam pulls Alex's change: the file now matches the place.
	expectEqual(#editFile(sam, "Shop", "shop by alex"), 0, "held after pull")
	expectEqual(#sam.session:heldChanges(), 0, "still held")
	expectEqual(#editFile(sam, "Shop", "shop by alex, then sam"), 0, "held after own edit")
	expectEqual(sourceOf("Shop"), "shop by alex, then sam", "shop")
end)

test("the other person is held too once you've changed their script", function()
	local alex, sam = twoPeople()
	editFile(alex, "Shop", "shop by alex")
	editFile(sam, "Shop", "shop by alex")
	editFile(sam, "Shop", "shop by alex, then sam")
	-- Alex hasn't pulled Sam's edit yet.
	expectEqual(#editFile(alex, "Shop", "shop by alex again"), 1, "alex held")
	expectEqual(sourceOf("Shop"), "shop by alex, then sam", "sam's version survives")
end)

test("reconnecting holds a stale copy instead of reverting their change", function()
	local alexMachine = newMachine("alex", 101)
	local samMachine = newMachine("sam", 202)
	local alex = connect(alexMachine, newServer(table.clone(base)))
	editFile(alex, "Shop", "shop by alex")
	local sam = connect(samMachine, newServer(table.clone(base)))
	expectEqual(#sam.lastHeld, 1, "held on connect")
	expectEqual(sourceOf("Shop"), "shop by alex", "shop")
end)

test("reconnecting after pulling their change holds nothing", function()
	local alexMachine = newMachine("alex", 101)
	local samMachine = newMachine("sam", 202)
	local alex = connect(alexMachine, newServer(table.clone(base)))
	editFile(alex, "Shop", "shop by alex")
	local sam = connect(samMachine, newServer({ Shop = "shop by alex", Inventory = "inv v1" }))
	expectEqual(#sam.lastHeld, 0, "held")
	expectEqual(#editFile(sam, "Shop", "shop by alex, then sam"), 0, "later edit held")
end)

test("a script someone else added isn't deleted by your stale files", function()
	local alexMachine = newMachine("alex", 101)
	local samMachine = newMachine("sam", 202)
	local alex = connect(alexMachine, newServer(table.clone(base)))
	editFile(alex, "Crafting", "new crafting")
	local sam = connect(samMachine, newServer(table.clone(base)))
	expectEqual(#sam.lastHeld, 1, "held")
	expectEqual(placeScripts().Crafting, 1, "crafting still there")
end)

test("pulling a script someone else added doesn't make a duplicate", function()
	local alex, sam = twoPeople()
	editFile(alex, "Crafting", "new crafting")
	expectEqual(#editFile(sam, "Crafting", "new crafting"), 0, "held")
	expectEqual(placeScripts().Crafting, 1, "copies of Crafting")
	-- Sam can now edit it like any other script.
	expectEqual(#editFile(sam, "Crafting", "crafting by sam"), 0, "later edit held")
	expectEqual(sourceOf("Crafting"), "crafting by sam", "crafting")
end)

test("deleting a script someone else just changed is held", function()
	local alex, sam = twoPeople()
	editFile(alex, "Shop", "shop by alex")
	expectEqual(#editFile(sam, "Shop", nil), 1, "held")
	expectEqual(sourceOf("Shop"), "shop by alex", "shop still there")
end)

test("sync anyway overwrites, and the other person is then held", function()
	local alex, sam = twoPeople()
	editFile(alex, "Shop", "shop by alex")
	editFile(sam, "Shop", "merged by sam")
	syncAnyway(sam)
	expectEqual(sourceOf("Shop"), "merged by sam", "shop")
	expectEqual(#sam.session:heldChanges(), 0, "sam still holding")
	expectEqual(#editFile(sam, "Shop", "merged by sam, edited"), 0, "sam's next edit held")
	expectEqual(#editFile(alex, "Shop", "alex again"), 1, "alex held")
end)

test("each person's log is separate, so both survive simultaneous syncs", function()
	local alex, sam = twoPeople()
	editFile(alex, "Shop", "shop by alex")
	editFile(sam, "Inventory", "inv by sam")
	local store = _G.__place:GetService("ServerStorage"):FindFirstChild("RojoTeamSync")
	expectEqual(#store:GetChildren(), 2, "machine logs")
end)

test("a place from the old single-log format is replaced, not misread", function()
	local old = roblox.Instance.new("StringValue")
	old.Name = "RojoTeamSync"
	old.Value = '{"version":1,"entries":[]}'
	old.Parent = _G.__place:GetService("ServerStorage")
	local alex = connect(newMachine("alex", 101), newServer(table.clone(base)))
	editFile(alex, "Shop", "shop by alex")
	local store = _G.__place:GetService("ServerStorage"):FindFirstChild("RojoTeamSync")
	expectEqual(store.ClassName, "Folder", "store")
end)

test("undoing a sync can't make someone else's later change look caught up", function()
	local alex, sam = twoPeople()
	local store = _G.__place:GetService("ServerStorage"):FindFirstChild("RojoTeamSync")
	local function alexLog()
		for _, child in store:GetChildren() do
			if child.Name == alex.machine.settings.Rojo_teamSyncMachine then
				return child
			end
		end
		return nil
	end

	editFile(alex, "Inventory", "inv by alex")
	local beforeShop = alexLog().Value
	editFile(alex, "Shop", "shop by alex")
	-- Sam pulls Alex's Shop, so Sam is caught up on it.
	editFile(sam, "Shop", "shop by alex")

	-- Alex undoes the Shop sync, which rolls back Alex's log, then syncs Shop again.
	alexLog().Value = beforeShop
	editFile(alex, "Shop", "shop by alex, second try")

	expectEqual(#editFile(sam, "Shop", "shop by alex, then sam"), 1, "sam held")
	expectEqual(sourceOf("Shop"), "shop by alex, second try", "alex's version survives")
end)

test("an old-format log written alongside the new one doesn't hide it", function()
	local alex, sam = twoPeople()
	editFile(alex, "Shop", "shop by alex")
	-- Someone still on the old version writes its single-value log.
	local old = roblox.Instance.new("StringValue")
	old.Name = "RojoTeamSync"
	old.Value = '{"version":1,"entries":[]}'
	old.Parent = _G.__place:GetService("ServerStorage")

	expectEqual(#editFile(sam, "Shop", "stale shop"), 1, "held")
	editFile(sam, "Inventory", "inv by sam")
	local stores = 0
	for _, child in _G.__place:GetService("ServerStorage"):GetChildren() do
		if child.Name == "RojoTeamSync" then
			stores += 1
			expectEqual(child.ClassName, "Folder", "store")
		end
	end
	expectEqual(stores, 1, "stores")
end)

print(string.format("%d passed, %d failed", passes, failures))
process.exit(if failures > 0 then 1 else 0)
