return function()
	local Policy = require(script.Parent.Policy)

	local function change(path, tree)
		return { path = path, tree = tree == true }
	end

	local function entry(id, name, changes, extra)
		local value = { id = id, userId = #name, name = name, at = 1000, changes = changes }
		for key, field in extra or {} do
			value[key] = field
		end
		return value
	end

	local function log(entries, truncated)
		return { version = Policy.VERSION, logId = "log", truncated = truncated == true, entries = entries }
	end

	local function evaluate(options)
		return Policy.evaluate({
			teamSync = if options.teamSync == nil then true else options.teamSync,
			log = options.log,
			baseId = options.baseId,
			changes = options.changes or {},
			force = options.force == true,
			now = 1060,
		})
	end

	describe("overlaps", function()
		it("matches the same instance", function()
			expect(Policy.overlaps(change("A.B"), change("A.B"))).to.equal(true)
			expect(Policy.overlaps(change("A.B"), change("A.C"))).to.equal(false)
		end)

		it("matches anything inside a subtree change", function()
			expect(Policy.overlaps(change("A", true), change("A.B.C"))).to.equal(true)
			expect(Policy.overlaps(change("A.B.C"), change("A", true))).to.equal(true)
		end)

		it("doesn't treat a property change as covering descendants", function()
			expect(Policy.overlaps(change("A"), change("A.B"))).to.equal(false)
		end)

		it("doesn't confuse siblings that share a name prefix", function()
			expect(Policy.overlaps(change("A.Foo", true), change("A.FooBar"))).to.equal(false)
		end)
	end)

	describe("evaluate", function()
		it("allows a place with no sync log", function()
			expect(evaluate({ changes = { change("A") } }).allowed).to.equal(true)
		end)

		it("allows when nobody synced since our last sync", function()
			local decision = evaluate({
				log = log({ entry("mine", "Me", { change("A") }) }),
				baseId = "mine",
				changes = { change("A") },
			})
			expect(decision.allowed).to.equal(true)
		end)

		it("allows our own changes to instances nobody else touched", function()
			local decision = evaluate({
				log = log({ entry("mine", "Me", {}), entry("theirs", "Alex", { change("A") }) }),
				baseId = "mine",
				changes = { change("B") },
			})
			expect(decision.allowed).to.equal(true)
		end)

		it("blocks overwriting an instance someone else changed since our last sync", function()
			local decision = evaluate({
				log = log({ entry("mine", "Me", {}), entry("theirs", "Alex", { change("A") }) }),
				baseId = "mine",
				changes = { change("A"), change("B") },
			})
			expect(decision.allowed).to.equal(false)
			expect(decision.canForce).to.equal(true)
			expect(#decision.conflicts).to.equal(1)
			expect(decision.conflicts[1].path).to.equal("A")
			expect(decision.conflicts[1].entry.name).to.equal("Alex")
			expect(string.find(decision.reason, "Alex", 1, true)).to.be.ok()
		end)

		it("ignores entries from before our last sync", function()
			local decision = evaluate({
				log = log({ entry("theirs", "Alex", { change("A") }), entry("mine", "Me", {}) }),
				baseId = "mine",
				changes = { change("A") },
			})
			expect(decision.allowed).to.equal(true)
		end)

		it("blocks deleting a folder someone else changed something inside", function()
			local decision = evaluate({
				log = log({ entry("mine", "Me", {}), entry("theirs", "Alex", { change("A.B.C") }) }),
				baseId = "mine",
				changes = { change("A.B", true) },
			})
			expect(decision.allowed).to.equal(false)
		end)

		it("treats an entry that changed too much to list as changing everything", function()
			local decision = evaluate({
				log = log({ entry("mine", "Me", {}), entry("theirs", "Alex", {}, { all = true }) }),
				baseId = "mine",
				changes = { change("Z") },
			})
			expect(decision.allowed).to.equal(false)
		end)

		it("checks every entry when we've never synced this place", function()
			local decision = evaluate({
				log = log({ entry("theirs", "Alex", { change("A") }) }),
				changes = { change("A") },
			})
			expect(decision.allowed).to.equal(false)

			local unrelated = evaluate({
				log = log({ entry("theirs", "Alex", { change("A") }) }),
				changes = { change("B") },
			})
			expect(unrelated.allowed).to.equal(true)
		end)

		it("treats every change as a conflict when our base was trimmed away", function()
			local decision = evaluate({
				log = log({ entry("theirs", "Alex", { change("A") }) }, true),
				baseId = "long-gone",
				changes = { change("B") },
			})
			expect(decision.allowed).to.equal(false)
			expect(decision.conflicts[1].entry).never.to.be.ok()
		end)

		it("allows a trimmed log when our patch changes nothing", function()
			local decision = evaluate({
				log = log({ entry("theirs", "Alex", { change("A") }) }, true),
				changes = {},
			})
			expect(decision.allowed).to.equal(true)
		end)

		it("lets the user override a conflict", function()
			local decision = evaluate({
				log = log({ entry("mine", "Me", {}), entry("theirs", "Alex", { change("A") }) }),
				baseId = "mine",
				changes = { change("A") },
				force = true,
			})
			expect(decision.allowed).to.equal(true)
			expect(decision.forced).to.equal(true)
		end)

		it("refuses a project without team sync on a team sync place, with no override", function()
			local decision = evaluate({
				teamSync = false,
				log = log({ entry("theirs", "Alex", { change("A") }) }),
				changes = {},
				force = true,
			})
			expect(decision.allowed).to.equal(false)
			expect(decision.canForce).to.equal(false)
		end)

		it("leaves places without a sync log alone when team sync is off", function()
			expect(evaluate({ teamSync = false, changes = { change("A") } }).allowed).to.equal(true)
		end)
	end)

	describe("recordChanges", function()
		it("dedupes and folds descendants into subtree changes", function()
			local recorded = Policy.recordChanges(entry("mine", "Me", { change("A.B"), change("C") }), {
				change("A", true),
				change("C"),
			}, 2000)

			expect(#recorded.changes).to.equal(2)
			expect(recorded.at).to.equal(2000)
		end)

		it("stops listing paths past the limit", function()
			local many = {}
			for index = 1, Policy.MAX_CHANGES + 1 do
				table.insert(many, change("Path" .. index))
			end

			local recorded = Policy.recordChanges(entry("mine", "Me", {}), many, 2000)
			expect(recorded.all).to.equal(true)
			expect(#recorded.changes).to.equal(0)
		end)
	end)

	describe("withEntry", function()
		it("replaces our entry while it's the latest", function()
			local updated = Policy.withEntry(log({ entry("mine", "Me", {}) }), entry("mine", "Me", { change("A") }))
			expect(#updated.entries).to.equal(1)
			expect(#updated.entries[1].changes).to.equal(1)
		end)

		it("trims the oldest entries and marks the log truncated", function()
			local current = log({})
			for index = 1, Policy.MAX_ENTRIES + 1 do
				current = Policy.withEntry(current, entry("e" .. index, "Me", {}))
			end

			expect(#current.entries).to.equal(Policy.MAX_ENTRIES)
			expect(current.entries[1].id).to.equal("e2")
			expect(current.truncated).to.equal(true)
		end)
	end)

	describe("supersededBy", function()
		it("returns the entry written after ours", function()
			local current = log({ entry("mine", "Me", {}), entry("theirs", "Alex", {}) })
			expect(Policy.supersededBy(current, "mine").name).to.equal("Alex")
			expect(Policy.supersededBy(current, "theirs")).never.to.be.ok()
		end)

		it("treats a log that lost our entry as superseded", function()
			local current = log({ entry("theirs", "Alex", {}) })
			expect(Policy.supersededBy(current, "mine").name).to.equal("Alex")
		end)
	end)

	describe("fitToLength", function()
		it("drops the oldest entries until the encoding fits", function()
			local current = log({ entry("a", "Me", {}), entry("b", "Me", {}), entry("c", "Me", {}) })
			local fitted, encoded = Policy.fitToLength(current, 2, function(value)
				return string.rep("x", #value.entries)
			end)

			expect(#fitted.entries).to.equal(2)
			expect(fitted.entries[1].id).to.equal("b")
			expect(fitted.truncated).to.equal(true)
			expect(encoded).to.equal("xx")
		end)
	end)
end
