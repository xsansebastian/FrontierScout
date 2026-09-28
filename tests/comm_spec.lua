local wow = require("tests.helpers.wow")

describe("Comm codec", function()
	local Comm
	setup(function()
		local _, _, ns = wow.boot()
		Comm = ns.Comm
	end)

	it("round-trips tables through the addon-channel encoding", function()
		local msg = { v = 1, g = "club:1", t = "ENT", e = { { id = "E-1", title = "Hé", x = 0.1234 } } }
		local text = Comm.Encode(msg)
		assert.is_nil(text:find("[%z\n]"))
		assert.same(msg, Comm.Decode(text))
	end)

	it("rejects malformed or oversized input", function()
		assert.is_nil(Comm.Decode("garbage"))
		assert.is_nil(Comm.Decode(nil))
		assert.is_nil(Comm.Decode(("a"):rep(Comm.MAX_TEXT + 1)))
	end)

	it("rate-limits per sender within a window", function()
		local allow = Comm.NewRateLimiter(2, 60)
		assert.is_true(allow("a", 0))
		assert.is_true(allow("a", 1))
		assert.is_false(allow("a", 2))
		assert.is_true(allow("b", 2))
		assert.is_true(allow("a", 61))
	end)
end)

describe("Comm isolation", function()
	local function boot()
		local state, FS, ns = wow.boot({ guild = "Wardens", roster = { { name = "Friend-Realm", rankIndex = 2 } } })
		FS:OnEnable()
		local got = {}
		FS:OnMessageType("TEST", function(_, msg, sender, dist) got[#got + 1] = { msg.x, sender, dist } end)
		return state, FS, ns.Comm, got
	end

	local function deliver(FS, Comm, msg, dist, sender)
		FS:OnCommReceived(Comm.PREFIX, Comm.Encode(msg), dist, sender)
	end

	it("accepts guild messages for this guild only", function()
		local _, FS, Comm, got = boot()
		deliver(FS, Comm, { v = 1, g = FS.guildKey, t = "TEST", x = 1 }, "GUILD", "Friend")
		deliver(FS, Comm, { v = 1, g = "name:Realm:Other", t = "TEST", x = 2 }, "GUILD", "Friend")
		deliver(FS, Comm, { v = 2, g = FS.guildKey, t = "TEST", x = 3 }, "GUILD", "Friend")
		deliver(FS, Comm, { v = 1, g = FS.guildKey, t = "TEST", x = 4 }, "PARTY", "Friend")
		assert.same({ { 1, "Friend-Realm", "GUILD" } }, got)
	end)

	it("accepts whispers only from guild members, and ignores itself", function()
		local _, FS, Comm, got = boot()
		deliver(FS, Comm, { v = 1, g = FS.guildKey, t = "TEST", x = 1 }, "WHISPER", "Stranger-Other")
		deliver(FS, Comm, { v = 1, g = FS.guildKey, t = "TEST", x = 2 }, "WHISPER", "Friend-Realm")
		deliver(FS, Comm, { v = 1, g = FS.guildKey, t = "TEST", x = 3 }, "GUILD", "Scout")
		assert.same({ { 2, "Friend-Realm", "WHISPER" } }, got)
	end)

	it("drops floods from one sender", function()
		local _, FS, Comm, got = boot()
		for i = 1, 40 do deliver(FS, Comm, { v = 1, g = FS.guildKey, t = "TEST", x = i }, "GUILD", "Friend") end
		assert.equals(Comm.RATE_LIMIT, #got)
	end)

	it("queues outgoing messages in combat and sends them afterwards", function()
		local state, FS = boot()
		state.env.InCombatLockdown = function() return true end
		assert.is_false(FS:Send("TEST", { x = 1 }, "GUILD"))
		assert.equals(0, #state.sent)
		state.env.InCombatLockdown = function() return false end
		wow.fire(state, "PLAYER_REGEN_ENABLED")
		assert.equals(1, #state.sent)
		assert.equals("GUILD", state.sent[1].distribution)
	end)
end)
