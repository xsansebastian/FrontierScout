local wow = require("tests.helpers.wow")
local Net = require("tests.helpers.net")

-- WoW Forever: one player's guild addon messages never reached anyone while
-- everyone else's reached them. Clients also talk over a private channel.

local function data(title)
	return { cat = "location", sub = "treasure", title = title, map = 1, x = 0.5, y = 0.5 }
end

local function titles(client)
	local out = {}
	for _, e in ipairs(client.FS.store:All()) do out[#out + 1] = e.title end
	table.sort(out)
	return out
end

local function network(opts)
	return Net.new({ { name = "Arch", rank = 1, archivist = true, guildBroken = true }, { name = "Gm", rank = 0 },
		{ name = "Mem", rank = 2 } }, { channels = opts.channels, guildInfo = "[FS1 s=2 eo=2 ea=1 do=2 da=1 r=9 am=2]" })
end

describe("Private guild channel", function()
	it("names the channel after the guild", function()
		local _, _, ns = wow.boot()
		assert.equals("FS22965401", ns.Comm.ChannelName("club:22965401"))
		assert.matches("^FS%x%x%x%x%x%x%x%x$", ns.Comm.ChannelName("name:Realm:Wardens"))
		assert.is_nil(ns.Comm.ChannelName(nil))
	end)

	it("without it, an archivist whose guild messages are lost can't reach anyone", function()
		local net = network({ channels = false })
		net:Tick()
		local arch, gm = net:Client("Arch"), net:Client("Gm")
		local p = gm.FS:SaveEntry(nil, data("From the GM"))
		net:Flush()
		arch.FS:Approve(p.pid)
		net:Tick()
		assert.same({}, titles(gm))
	end)

	it("with it, submissions, approvals and syncs flow both ways", function()
		local net = network({ channels = true })
		net:Tick() -- join the channel, then HELLO
		local arch, gm, mem = net:Client("Arch"), net:Client("Gm"), net:Client("Mem")
		for _, c in ipairs({ arch, gm, mem }) do assert.equals(5, c.FS:CommChannel()) end
		local p = gm.FS:SaveEntry(nil, data("From the GM"))
		net:Flush()
		assert.equals("queued", gm.FS.store.bucket.mine[p.pid].status)
		arch.FS:Approve(p.pid)
		net:Flush()
		assert.same({ "From the GM" }, titles(gm))
		assert.same({ "From the GM" }, titles(mem))
		assert.equals("approved", gm.FS.store.bucket.mine[p.pid].status)
		-- A member who was offline catches up from the archivist.
		local late = net:Client("Mem")
		late.FS.store.bucket.entries = {}
		late.FS.store = late.ns.Store.New(late.FS.store.bucket)
		late.FS:SayHello(true)
		net:Flush()
		assert.same({ "From the GM" }, titles(late))
		for _, m in ipairs(arch.state.sent) do assert.equals("CHANNEL", m.distribution) end
	end)

	it("ignores channel messages from players outside the guild", function()
		local state, FS, ns = wow.boot({ guild = "Wardens", channels = true,
			roster = { { name = "Friend-Realm", rankIndex = 2 } } })
		FS:OnEnable()
		FS.db.profile.debug = true
		local got = {}
		FS:OnMessageType("TEST", function(_, msg) got[#got + 1] = msg.x end)
		local function deliver(x, sender)
			FS:OnCommReceived(ns.Comm.PREFIX, ns.Comm.Encode({ v = 1, g = FS.guildKey, t = "TEST", x = x }), "CHANNEL", sender)
		end
		deliver(1, "Stranger-Realm")
		deliver(2, "Friend")
		assert.same({ 2 }, got)
		assert.matches("ignored a channel message from Stranger-Realm: not in the guild roster",
			table.concat(state.printed, "\n"), 1, true)
	end)

	it("resends a message the game refuses on the channel over the guild channel", function()
		local net = network({ channels = true })
		net:Tick()
		local gm, arch = net:Client("Gm"), net:Client("Arch")
		gm.state.refuse = { CHANNEL = 8 } -- e.g. ChannelThrottle
		gm.FS.db.profile.debug = true
		local p = gm.FS:SaveEntry(nil, data("Throttled"))
		net:Flush()
		assert.equals(1, #arch.FS:QueueList())
		assert.equals("queued", gm.FS.store.bucket.mine[p.pid].status)
		local out = table.concat(gm.state.printed, "\n")
		assert.matches("the game didn't send PROP over CHANNEL (result 8)", out, 1, true)
		assert.matches("direct test over CHANNEL: refused (ChannelThrottle)", out, 1, true)
	end)

	it("keeps reading the channel when sending over the guild channel only", function()
		local net = network({ channels = true })
		local gm, arch = net:Client("Gm"), net:Client("Arch")
		gm.FS.db.profile.guildChannelOnly = true
		net:Tick()
		assert.is_not_nil(gm.state.channels[gm.ns.Comm.ChannelName(gm.FS.guildKey)]) -- joined, to listen
		local p = gm.FS:SaveEntry(nil, data("Via guild"))
		net:Flush()
		arch.FS:Approve(p.pid) -- the archivist's guild messages are lost; its channel ones arrive
		net:Flush()
		assert.same({ "Via guild" }, titles(gm))
	end)

	it("can be turned off in the options", function()
		local net = network({ channels = true })
		local arch = net:Client("Arch")
		arch.FS.db.profile.guildChannelOnly = true
		net:Tick()
		assert.is_nil(arch.FS:CommChannel())
		arch.FS:SayHello(true)
		assert.equals("GUILD", arch.state.sent[#arch.state.sent].distribution)
	end)
end)
