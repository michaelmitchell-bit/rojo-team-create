return function()
	local Policy = require(script.Parent.Policy)

	local function change(path, tree)
		return { path = path, tree = tree == true }
	end

	local function machineLog(machine, name, writes, extra)
		local log = Policy.newMachineLog(machine, #name, name)
		local counter = 0
		for path, write in writes do
			log.writes[path] = { c = write.c, tree = write.tree == true, at = 1000 }
			counter = math.max(counter, write.c)
		end
		log.counter = counter
		for key, value in extra or {} do
			log[key] = value
		end
		return log
	end

	local function conflicts(target, logs, acks)
		return Policy.conflictsFor(target, logs, "me", acks or {})
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

	describe("conflictsFor", function()
		it("finds nothing when nobody else has synced", function()
			expect(#conflicts(change("A"), {})).to.equal(0)
		end)

		it("ignores our own machine's writes", function()
			local mine = machineLog("me", "Me", { A = { c = 1 } })
			expect(#conflicts(change("A"), { mine })).to.equal(0)
		end)

		it("flags another machine's write we haven't caught up on", function()
			local theirs = machineLog("alex", "Alex", { A = { c = 1 } })
			local found = conflicts(change("A"), { theirs })
			expect(#found).to.equal(1)
			expect(found[1].name).to.equal("Alex")
			expect(found[1].path).to.equal("A")
		end)

		it("leaves other instances alone", function()
			local theirs = machineLog("alex", "Alex", { A = { c = 1 } })
			expect(#conflicts(change("B"), { theirs })).to.equal(0)
		end)

		it("stops flagging a write once we've caught up on it", function()
			local theirs = machineLog("alex", "Alex", { A = { c = 1 } })
			local acks = { alex = { all = 0, paths = { A = 1 } } }
			expect(#conflicts(change("A"), { theirs }, acks)).to.equal(0)
		end)

		it("flags it again when they change it after we caught up", function()
			local theirs = machineLog("alex", "Alex", { A = { c = 2 } })
			local acks = { alex = { all = 0, paths = { A = 1 } } }
			expect(#conflicts(change("A"), { theirs }, acks)).to.equal(1)
		end)

		it("flags deleting a folder someone else changed something inside", function()
			local theirs = machineLog("alex", "Alex", { ["A.B.C"] = { c = 1 } })
			expect(#conflicts(change("A.B", true), { theirs })).to.equal(1)
		end)

		it("flags editing inside a folder someone else added", function()
			local theirs = machineLog("alex", "Alex", { ["A.B"] = { c = 1, tree = true } })
			expect(#conflicts(change("A.B.Script"), { theirs })).to.equal(1)
		end)

		it("treats dropped history we never caught up on as a conflict", function()
			local theirs = machineLog("alex", "Alex", {}, { counter = 5, floor = 3 })
			local found = conflicts(change("Anything"), { theirs })
			expect(#found).to.equal(1)
			expect(found[1].unknown).to.equal(true)
		end)
	end)

	describe("catchUpOn", function()
		it("clears conflicts for the overlapping writes only", function()
			local theirs = machineLog("alex", "Alex", { A = { c = 1 }, B = { c = 2 } })
			local acks = Policy.catchUpOn({}, { theirs }, "me", change("A"))
			expect(#conflicts(change("A"), { theirs }, acks)).to.equal(0)
			expect(#conflicts(change("B"), { theirs }, acks)).to.equal(1)
		end)

		it("collapses to a single number once everything is caught up", function()
			local theirs = machineLog("alex", "Alex", { A = { c = 1 }, B = { c = 2 } })
			local acks = Policy.catchUpOn({}, { theirs }, "me", change("A"))
			acks = Policy.catchUpOn(acks, { theirs }, "me", change("B"))
			expect(acks.alex.all).to.equal(2)
			expect(next(acks.alex.paths)).never.to.be.ok()
		end)
	end)

	describe("catchUpExcept", function()
		it("catches up on everything that isn't held", function()
			local theirs = machineLog("alex", "Alex", { A = { c = 1 }, B = { c = 2 } })
			local acks = Policy.catchUpExcept({}, { theirs }, "me", { change("B") })
			expect(#conflicts(change("A"), { theirs }, acks)).to.equal(0)
			expect(#conflicts(change("B"), { theirs }, acks)).to.equal(1)
		end)

		it("clears dropped history when nothing at all is held", function()
			local theirs = machineLog("alex", "Alex", {}, { counter = 5, floor = 3 })
			local acks = Policy.catchUpExcept({}, { theirs }, "me", {})
			expect(#conflicts(change("Anything"), { theirs }, acks)).to.equal(0)
		end)

		it("keeps dropped history unknown while something is held", function()
			local theirs = machineLog("alex", "Alex", {}, { counter = 5, floor = 3 })
			local acks = Policy.catchUpExcept({}, { theirs }, "me", { change("X") })
			expect(#conflicts(change("Anything"), { theirs }, acks)).to.equal(1)
		end)
	end)

	describe("recordWrites", function()
		it("stamps each batch with the next counter", function()
			local log = Policy.newMachineLog("me", 1, "Me")
			log = Policy.recordWrites(log, { change("A") }, 2000)
			log = Policy.recordWrites(log, { change("B"), change("A") }, 2001)
			expect(log.counter).to.equal(2)
			expect(log.writes.A.c).to.equal(2)
			expect(log.writes.B.c).to.equal(2)
		end)

		it("does nothing for an empty batch", function()
			local log = Policy.newMachineLog("me", 1, "Me")
			expect(Policy.recordWrites(log, {}, 2000).counter).to.equal(0)
		end)

		it("drops the oldest writes past the limit and raises the floor", function()
			local log = Policy.newMachineLog("me", 1, "Me")
			for index = 1, Policy.MAX_WRITES + 2 do
				log = Policy.recordWrites(log, { change("Path" .. index) }, 2000)
			end

			local count = 0
			for _ in log.writes do
				count += 1
			end
			expect(count).to.equal(Policy.MAX_WRITES)
			expect(log.writes.Path1).never.to.be.ok()
			expect(log.floor).to.equal(2)
		end)
	end)

	describe("two people connected at once", function()
		it("holds only what overlaps, and catches up when files match", function()
			-- Alex syncs a change to Shop while we're both connected.
			local alex = Policy.recordWrites(Policy.newMachineLog("alex", 2, "Alex"), { change("Shop") }, 1000)
			local logs = { alex }
			local acks = {}

			-- Our unrelated edit goes straight through.
			expect(#Policy.conflictsFor(change("Inventory"), logs, "me", acks)).to.equal(0)

			-- Our stale copy of Shop would overwrite Alex, so it's held.
			expect(#Policy.conflictsFor(change("Shop"), logs, "me", acks)).to.equal(1)

			-- We pull Alex's change; our Shop now matches the place.
			acks = Policy.catchUpOn(acks, logs, "me", change("Shop"))

			-- From here our own Shop edits sync normally...
			expect(#Policy.conflictsFor(change("Shop"), logs, "me", acks)).to.equal(0)

			-- ...until Alex changes Shop again.
			logs = { Policy.recordWrites(alex, { change("Shop") }, 1100) }
			expect(#Policy.conflictsFor(change("Shop"), logs, "me", acks)).to.equal(1)
		end)
	end)

	describe("describe", function()
		it("lists each held path once, with who changed it", function()
			local text = Policy.describe({
				{ path = "Shop", machine = "alex", name = "Alex", at = 1000 },
				{ path = "Shop", machine = "alex", name = "Alex", at = 1000 },
			}, 1060)
			local _, lines = string.gsub(text, "Shop", "")
			expect(lines).to.equal(1)
			expect(string.find(text, "Alex", 1, true)).to.be.ok()
		end)
	end)
end
