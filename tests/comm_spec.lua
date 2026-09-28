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

	it("accepts addressed messages for this player only, and ignores itself and whispers", function()
		local _, FS, Comm, got = boot()
		local function addressed(to, x)
			local text = Comm.Address(to, Comm.Encode({ v = 1, g = FS.guildKey, t = "TEST", x = x }))
			FS:OnCommReceived(Comm.PREFIX_TO, text, "GUILD", "Friend")
		end
		addressed("Someone-Realm", 1)
		addressed("Scout-Realm", 2)
		addressed("Scout", 3)
		deliver(FS, Comm, { v = 1, g = FS.guildKey, t = "TEST", x = 4 }, "WHISPER", "Friend-Realm")
		deliver(FS, Comm, { v = 1, g = FS.guildKey, t = "TEST", x = 5 }, "GUILD", "Scout")
		FS:OnCommReceived(Comm.PREFIX_TO, "no separator", "GUILD", "Friend")
		assert.same({ { 2, "Friend-Realm", "WHISPER" }, { 3, "Friend-Realm", "WHISPER" } }, got)
	end)

	it("sends messages for one player over the guild channel with the recipient up front", function()
		local state, FS, Comm = boot()
		FS:Send("TEST", { x = 1 }, "WHISPER", "Friend-Realm")
		local sent = state.sent[#state.sent]
		assert.same({ Comm.PREFIX_TO, "GUILD" }, { sent.prefix, sent.distribution })
		assert.is_nil(sent.target)
		local msg, to = wow.decode(state.ns, sent)
		assert.equals("Friend-Realm", to)
		assert.equals(1, msg.x)
	end)

	it("doesn't count messages for others against the sender's rate limit", function()
		local _, FS, Comm, got = boot()
		for _ = 1, 40 do
			FS:OnCommReceived(Comm.PREFIX_TO, Comm.Address("Someone-Realm", Comm.Encode({ v = 1, g = FS.guildKey, t = "TEST" })),
				"GUILD", "Friend")
		end
		deliver(FS, Comm, { v = 1, g = FS.guildKey, t = "TEST", x = 1 }, "GUILD", "Friend")
		assert.same({ { 1, "Friend-Realm", "GUILD" } }, got)
	end)

	it("says in debug when the game refuses to send", function()
		local state, FS = boot()
		FS.db.profile.debug = true
		state.sendResult = 9
		FS:Send("TEST", {}, "GUILD")
		assert.matches("the game didn't send TEST (result 9)", table.concat(state.printed, "\n"), 1, true)
		state.printed, state.sendResult = {}, nil
		FS:Send("TEST", {}, "GUILD")
		assert.is_nil(table.concat(state.printed, "\n"):find("didn't send", 1, true))
	end)

	it("/fs whoami reports whether this client can send to the guild", function()
		local state = boot()
		state.env.UnitName = function() return "Scout" end
		wow.slash(state, "whoami")
		assert.matches("Sending: can speak in guild chat: true | in combat: false | in instance: false | test message: sent",
			table.concat(state.printed, "\n"), 1, true)
		state.printed, state.sendResult, state.canSpeak = {}, 9, false
		wow.slash(state, "whoami")
		assert.matches("can speak in guild chat: false | in combat: false | in instance: false | test message: refused (GeneralError)",
			table.concat(state.printed, "\n"), 1, true)
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
