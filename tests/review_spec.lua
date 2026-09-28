local wow = require("tests.helpers.wow")
local Net = require("tests.helpers.net")

local function data(title, map)
	return { cat = "location", sub = "treasure", title = title, map = map or 1, x = 0.5, y = 0.5 }
end

local function titles(client)
	local out = {}
	for _, e in ipairs(client.FS.store:All()) do out[#out + 1] = e.title end
	table.sort(out)
	return out
end

local function mine(client, pid) return client.FS.store.bucket.mine[pid] end

describe("Review (pure)", function()
	local Review
	setup(function()
		local _, _, ns = wow.boot()
		Review = ns.Review
	end)

	local function prop(over)
		local p = { pid = "P-1", op = "create", eid = "E-1", author = "Mem-Realm", at = 5, data = data("Chest") }
		for k, v in pairs(over or {}) do p[k] = v end
		return p
	end

	it("validates proposals", function()
		assert.equals("Chest", Review.ValidateProposal(prop()).data.title)
		assert.same({ nil, "invalid" }, { Review.ValidateProposal(prop({ op = "steal" })) })
		assert.same({ nil, "invalid" }, { Review.ValidateProposal(prop({ author = "NoRealm" })) })
		assert.same({ nil, "invalid" }, { Review.ValidateProposal(prop({ pid = 7 })) })
		assert.same({ nil, "title" }, { Review.ValidateProposal(prop({ data = data("") })) })
		local d = Review.ValidateProposal(prop({ op = "delete", data = "ignored", reason = "|cffff0000gone|r" }))
		assert.is_nil(d.data)
		assert.equals("gone", d.reason)
	end)

	it("diffs entry versions", function()
		local old = { cat = "npc", sub = "rare", title = "A", map = 1, x = 0.1, y = 0.1, tags = { "x" } }
		local new = { cat = "npc", sub = "rare", title = "B", map = 1, x = 0.1, y = 0.1, desc = "d" }
		assert.same({ { "title", "A", "B" }, { "description", nil, "d" }, { "tags", "x", nil } }, Review.Diff(old, new))
	end)
end)

-- SPEC §11 M5 exit criterion: submit -> approve -> all members see it.
describe("Curation over the guild network", function()
	local function network(extra)
		local members = { { name = "Arch", rank = 1, archivist = true }, { name = "Mem", rank = 2 }, { name = "Mem2", rank = 2 } }
		for _, m in ipairs(extra or {}) do members[#members + 1] = m end
		local net = Net.new(members)
		net:Tick()
		return net
	end

	it("submit, approve, and every member sees it", function()
		local net = network()
		local arch, mem, mem2 = net:Client("Arch"), net:Client("Mem"), net:Client("Mem2")
		local p = mem.FS:SaveEntry(nil, data("Hidden chest"))
		assert.equals("waiting", mine(mem, p.pid).status)
		net:Flush()
		assert.equals("queued", mine(mem, p.pid).status)
		assert.is_nil(mem.FS.store.bucket.outbox[p.pid])
		assert.equals(1, #arch.FS:QueueList())

		local e = arch.FS:Approve(p.pid)
		assert.equals("Mem-Realm", e.author)
		assert.equals("Arch-Realm", e.approvedBy)
		net:Flush()
		for _, c in ipairs({ arch, mem, mem2 }) do assert.same({ "Hidden chest" }, titles(c)) end
		assert.equals("approved", mine(mem, p.pid).status)
		assert.matches("was approved", mem.state.printed[#mem.state.printed], 1, true)
		assert.equals(0, #arch.FS:QueueList())
	end)

	it("rejects with a reason the author sees, even after being offline", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		local p = mem.FS:SaveEntry(nil, data("Duplicate"))
		net:Flush()
		mem.offline = true
		arch.FS:Reject(p.pid, "We already have this one")
		net:Flush()
		assert.equals("queued", mine(mem, p.pid).status)
		mem.offline = false
		mem.FS:SayHello(true)
		net:Flush()
		assert.equals("rejected", mine(mem, p.pid).status)
		assert.equals("We already have this one", mine(mem, p.pid).reason)
		assert.same({}, titles(mem))
	end)

	it("keeps submissions until an archivist comes online", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		mem.state.roster[1].online = false -- Arch is first in the roster
		wow.fire(mem.state, "GUILD_ROSTER_UPDATE")
		local p = mem.FS:SaveEntry(nil, data("Patient"))
		net:Flush()
		assert.equals("waiting", mine(mem, p.pid).status)
		assert.equals(0, #arch.FS:QueueList())
		mem.state.roster[1].online = true
		wow.fire(mem.state, "GUILD_ROSTER_UPDATE")
		net:Flush()
		assert.equals("queued", mine(mem, p.pid).status)
	end)

	it("archivists drop forged and unauthorized proposals", function()
		local net = network({ { name = "Low", rank = 3 } })
		local arch, mem, low = net:Client("Arch"), net:Client("Mem"), net:Client("Low")
		-- Mem submits in Mem2's name.
		mem.FS:Send("PROP", { p = { pid = "P-f", op = "create", eid = "E-f", author = "Mem2-Realm", at = 1, data = data("Forged") } },
			"WHISPER", "Arch-Realm")
		-- Low's rank may not submit (s=2).
		low.FS:Send("PROP", { p = { pid = "P-l", op = "create", eid = "E-l", author = "Low-Realm", at = 1, data = data("Low") } },
			"WHISPER", "Arch-Realm")
		-- Mem proposes deleting an archivist's entry (da=1).
		local e = arch.FS:SaveEntry(nil, data("Keep"))
		net:Flush()
		mem.FS:Send("PROP", { p = { pid = "P-d", op = "delete", eid = e.id, author = "Mem-Realm", at = 1 } }, "WHISPER", "Arch-Realm")
		net:Flush()
		assert.equals(0, #arch.FS:QueueList())
	end)

	it("deletes and edits through proposals", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		local p = mem.FS:SaveEntry(nil, data("Mine"))
		net:Flush()
		arch.FS:Approve(p.pid)
		net:Flush()
		local id = mem.FS.store:All()[1].id
		local edit = mem.FS:SaveEntry(id, data("Mine, better"))
		net:Flush()
		arch.FS:Approve(edit.pid)
		net:Flush()
		assert.same({ "Mine, better" }, titles(mem))
		assert.equals(2, mem.FS.store:Get(id).rev)
		local del = mem.FS:DeleteEntry(id, "moved")
		net:Flush()
		arch.FS:Approve(del.pid)
		net:Flush()
		assert.same({}, titles(mem))
		assert.same({}, titles(net:Client("Mem2")))
	end)

	it("rejects proposals that no longer apply", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		local e = arch.FS:SaveEntry(nil, data("Report me"))
		net:Flush()
		local mineEntry = mem.FS.store:Get(e.id)
		assert.is_not_nil(mineEntry)
		local p = mem.FS:Report(e.id, "It's gone")
		net:Flush()
		arch.FS:DeleteEntry(e.id)
		assert.same({ nil, "missing" }, { arch.FS:Approve(p.pid) })
		net:Flush()
		assert.equals("rejected", mine(mem, p.pid).status)
	end)

	it("reports reach the queue and can be dismissed", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		local e = arch.FS:SaveEntry(nil, data("Maybe gone"))
		net:Flush()
		local p = mem.FS:Report(e.id, "Not there any more")
		net:Flush()
		local q = arch.FS:QueueList()[1]
		assert.equals("report", q.op)
		assert.equals("Not there any more", q.reason)
		arch.FS:Reject(p.pid, "Still there at night")
		net:Flush()
		assert.equals("rejected", mine(mem, p.pid).status)
		assert.same({ "Maybe gone" }, titles(mem))
	end)

	it("keeps archivists' queues in step", function()
		local net = network({ { name = "Arch2", rank = 1, archivist = true } })
		local arch, arch2, mem = net:Client("Arch"), net:Client("Arch2"), net:Client("Mem")
		arch2.offline = true
		local p1 = mem.FS:SaveEntry(nil, data("One"))
		local p2 = mem.FS:SaveEntry(nil, data("Two"))
		net:Flush()
		arch.FS:Approve(p1.pid)
		net:Flush()
		arch2.offline = false
		arch2.FS:SayHello(true)
		net:Flush()
		local queue = arch2.FS:QueueList()
		assert.equals(1, #queue)
		assert.equals(p2.pid, queue[1].pid)
		assert.same({ "One" }, titles(arch2))
		arch2.FS:Approve(p2.pid)
		net:Flush()
		assert.equals(0, #arch.FS:QueueList())
		assert.same({ "One", "Two" }, titles(arch))
	end)

	it("an archivist's own report goes straight to its queue", function()
		local net = network()
		local arch = net:Client("Arch")
		local e = arch.FS:SaveEntry(nil, data("Mine"))
		arch.FS:Report(e.id, "check")
		assert.equals(1, #arch.FS:QueueList())
	end)

	it("officers are warned about untagged officer-rank players serving data", function()
		local net = Net.new({ { name = "Arch", rank = 1, archivist = true }, { name = "Sneaky", rank = 1 }, { name = "Off", rank = 1 } })
		net:Tick()
		local sneaky, off = net:Client("Sneaky"), net:Client("Off")
		-- Officers see notes, so Sneaky isn't an archivist for them; for members the rank gate would pass.
		sneaky.FS:Send("APPR", { e = { id = "E-s", cat = "location", sub = "cave", title = "Sneaky", map = 1, x = 0.1, y = 0.1,
			rev = 1, approvedAt = 1, approvedBy = "Sneaky-Realm" } }, "GUILD")
		net:Flush()
		assert.same({}, titles(off))
		assert.matches("Sneaky sent APPR", off.FS:Warnings()[1], 1, true)
	end)
end)
