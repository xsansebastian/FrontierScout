local Net = require("tests.helpers.net")

-- M4 exit criterion: clients converge from empty and after divergent edits.

local function data(title, map)
	return { cat = "location", sub = "treasure", title = title, map = map or 1, x = 0.5, y = 0.5 }
end

local function root(client) return client.FS.store.digest:Root() end

local function titles(client)
	local out = {}
	for _, e in ipairs(client.FS.store:All()) do out[#out + 1] = e.title end
	table.sort(out)
	return out
end

-- Archivists: rank 1 with the {FS:A} note. Members: rank 2.
local function network(extra)
	local members = { { name = "Arch", rank = 1, archivist = true }, { name = "Mem", rank = 2 } }
	for _, m in ipairs(extra or {}) do members[#members + 1] = m end
	return Net.new(members)
end

describe("Sync", function()
	it("a new member converges from empty", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		arch.state.bus = nil -- write offline first
		for i = 1, 45 do arch.FS:SaveEntry(nil, data("Spot " .. i)) end
		arch.FS:DeleteEntry(arch.FS.store:All()[1].id)
		arch.state.bus = net

		net:Tick() -- HELLO timers fire, ARCH answers, pull runs
		assert.equals(44, #mem.FS.store:All())
		assert.equals(root(arch), root(mem))
		assert.is_not_nil(mem.FS:SyncStatus().lastFullSync)
		assert.same({ "Arch-Realm" }, mem.FS:SyncStatus().archivists)
		assert.is_nil(mem.FS.syncPartner)
	end)

	it("archivists converge after divergent edits", function()
		local net = network({ { name = "Arch2", rank = 1, archivist = true } })
		local a, b = net:Client("Arch"), net:Client("Arch2")
		net:Tick()
		local shared = a.FS:SaveEntry(nil, data("Shared"))
		local doomed = a.FS:SaveEntry(nil, data("Doomed"))
		net:Flush()
		assert.equals(root(a), root(b))

		-- Both go offline and edit independently.
		a.offline, b.offline = true, true
		a.FS:SaveEntry(shared.id, data("Shared, edited by A"))
		a.FS:SaveEntry(nil, data("Only A"))
		b.FS:DeleteEntry(doomed.id)
		b.FS:SaveEntry(nil, data("Only B"))
		net:Flush()
		assert.are_not.equal(root(a), root(b))

		a.offline, b.offline = false, false
		b.FS:SayHello(true)
		net:Flush()
		assert.equals(root(a), root(b))
		assert.same({ "Only A", "Only B", "Shared, edited by A" }, titles(a))
		assert.same(titles(a), titles(b))
	end)

	it("pushes an archivist's new entries live", function()
		local net = network()
		net:Tick()
		net:Client("Arch").FS:SaveEntry(nil, data("Fresh"))
		net:Flush()
		assert.same({ "Fresh" }, titles(net:Client("Mem")))
	end)

	it("moves many entries in batches", function()
		local net = network()
		local arch = net:Client("Arch")
		arch.state.bus = nil
		for i = 1, 250 do arch.FS:SaveEntry(nil, data("E" .. i)) end
		arch.state.bus = net
		net:Tick()
		assert.equals(250, #net:Client("Mem").FS.store:All())
		local wants = 0
		for _, s in ipairs(net:Client("Mem").state.sent) do
			if s.distribution == "WHISPER" then wants = wants + 1 end
		end
		assert.is_true(wants >= 4) -- SYNCREQ + 3 WANT chunks
	end)

	it("ignores canonical data from non-archivists", function()
		local net = network({ { name = "Mem2", rank = 2 } })
		net:Tick()
		local mem, mem2 = net:Client("Mem"), net:Client("Mem2")
		-- A modified client broadcasts a fake approval.
		mem.FS:Send("APPR", { e = { id = "E-fake", cat = "npc", sub = "rare", title = "Fake", map = 1, x = 0.1, y = 0.1,
			rev = 1, approvedAt = 1, approvedBy = "Mem-Realm" } }, "GUILD")
		mem.FS:Send("ENT", { e = { { id = "E-fake2", deleted = true, rev = 1, approvedAt = 1 } }, done = true }, "WHISPER", "Mem2-Realm")
		net:Flush()
		assert.same({}, titles(mem2))
		assert.is_nil(mem2.FS.store:GetAny("E-fake2"))
		assert.same({}, titles(net:Client("Arch")))
	end)

	it("never applies member writes directly (they are proposals)", function()
		local net = network()
		net:Tick()
		net:Client("Mem").FS:SaveEntry(nil, data("Mine"))
		net:Flush()
		assert.same({}, titles(net:Client("Arch")))
		assert.same({}, titles(net:Client("Mem")))
		assert.equals(1, #net:Client("Arch").FS:QueueList())
	end)

	it("serves two members at a time and tells others it is busy", function()
		local net = network({ { name = "M2", rank = 2 }, { name = "M3", rank = 2 } })
		local arch = net:Client("Arch")
		arch.state.bus = nil
		for i = 1, 5 do arch.FS:SaveEntry(nil, data("E" .. i)) end
		arch.state.bus = net
		-- Three members ask at once; the archivist hasn't finished anyone yet.
		for _, name in ipairs({ "Mem", "M2", "M3" }) do
			local c = net:Client(name)
			c.FS.syncPartner = nil
			c.FS:Send("SYNCREQ", { b = c.FS.store.digest:Buckets() }, "WHISPER", "Arch-Realm")
		end
		local busy = 0
		local queued = net.queue
		net.queue = {}
		for _, item in ipairs(queued) do
			item.client.FS[item.client.state.commMethod](item.client.FS, item.prefix, item.text, item.distribution, item.sender)
		end
		for _, item in ipairs(net.queue) do
			local msg = item.client.ns.Comm.Decode(item.text)
			if msg.t == "BUSY" then busy = busy + 1 end
		end
		assert.equals(1, busy)
	end)

	it("drops stale entries whose deletion was already garbage-collected", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		net:Tick()
		-- The member still has an entry from long ago that the archivists no longer know.
		mem.FS.store:Apply({ id = "E-ancient", cat = "location", sub = "cave", title = "Ancient", map = 1, x = 0.1, y = 0.1,
			rev = 1, approvedAt = 1, approvedBy = "Arch-Realm" })
		arch.FS:SaveEntry(nil, data("New"))
		mem.FS:SayHello(true)
		net:Flush()
		assert.same({ "New" }, titles(mem))
		assert.equals(root(arch), root(mem))
	end)

	it("/fs sync says hello again", function()
		local net = network()
		local mem = net:Client("Mem")
		mem.FS:OnSlashCommand("sync")
		assert.matches("Looking for archivists", mem.state.printed[#mem.state.printed], 1, true)
	end)
end)
