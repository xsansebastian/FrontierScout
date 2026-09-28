local wow = require("tests.helpers.wow")

-- WoW Forever: characters are "Name Surname" and are whispered without a
-- realm. The first in-game test showed an archivist not recognised as one
-- (the roster name didn't match UnitFullName) and whispers to
-- "Lakota Blackelk-ClassicBetaPvE2" failing with "No player named ...".

local ME = "Player-1234-0ABCDEF0" -- the stub's player GUID

local function boot(extra)
	local roster = {
		{ name = "Lakota Blackelk-Realm", rankIndex = 0, officerNote = "{FS:A}", online = true, guid = ME },
		{ name = "Naal Mistrunner-Realm", rankIndex = 2, officerNote = "", online = true, guid = "Player-1234-0000000002" },
	}
	for _, m in ipairs(extra or {}) do roster[#roster + 1] = m end
	local state, FS, ns = wow.boot({ guild = "Wardens", rank = 0, roster = roster, canViewNotes = true,
		guildInfo = "[FS1 s=9 eo=9 ea=1 do=9 da=1 r=2 ar=1]" })
	-- UnitFullName gives something else than the roster (here: first name only).
	state.env.UnitFullName = function() return "Lakota", "Realm" end
	FS:OnEnable()
	return state, FS, ns
end

describe("WoW Forever names", function()
	it("finds the player in the roster by GUID", function()
		local _, FS = boot()
		assert.equals("Lakota Blackelk-Realm", FS:PlayerName())
		assert.is_true(FS:AmArchivist())
	end)

	it("never counts the player among the archivists to send to", function()
		local _, FS = boot()
		assert.same({}, FS:OnlineArchivists())
	end)

	it("whispers 'Name Surname' without the realm", function()
		local state, FS = boot({ { name = "Other Archivist-Realm", rankIndex = 1, officerNote = "{FS:A}", online = true, guid = "Player-1234-0000000003" } })
		FS:Send("TEST", {}, "WHISPER", "Other Archivist-Realm")
		assert.equals("Other Archivist", state.sent[#state.sent].target)
		FS:Send("TEST", {}, "WHISPER", "Visitor-OtherRealm")
		assert.equals("Visitor-OtherRealm", state.sent[#state.sent].target) -- another realm keeps it
	end)

	it("accepts whispers from 'Name Surname' senders in the guild", function()
		local _, FS, ns = boot()
		local got
		FS:OnMessageType("TEST", function(_, _, sender) got = sender end)
		local text = ns.Comm.Encode({ v = 1, g = FS.guildKey, t = "TEST" })
		FS:OnCommReceived(ns.Comm.PREFIX, text, "WHISPER", "Naal Mistrunner")
		assert.equals("Naal Mistrunner-Realm", got)
	end)

	it("moves the archivist's own stuck proposals into their queue", function()
		local state, FS = boot()
		-- Submitted while the player wasn't recognised as an archivist.
		local b = FS.store.bucket
		b.outbox = { ["P-1"] = { pid = "P-1", op = "create", eid = "E-1", author = "Lakota-Realm", at = 1,
			data = { cat = "npc", sub = "notable", title = "Naal Mistrunner", map = 1, x = 0.5, y = 0.5 } } }
		b.mine = { ["P-1"] = { op = "create", eid = "E-1", at = 1, status = "waiting", title = "Naal Mistrunner" } }
		FS:FlushOutbox()
		assert.equals(1, #FS:QueueList())
		assert.equals("queued", b.mine["P-1"].status)
		assert.is_not_nil(FS:Approve("P-1"))
		assert.equals("Naal Mistrunner", FS.store:Get("E-1").title)
		assert.equals("Lakota Blackelk-Realm", FS.store:Get("E-1").author)
		assert.equals("approved", b.mine["P-1"].status)
		for _, m in ipairs(state.sent) do assert.are_not.equal("WHISPER", m.distribution) end
	end)

	it("hides 'player not found' errors caused by its own whispers", function()
		local state, FS, ns = boot({ { name = "Gone Away-Realm", rankIndex = 1, officerNote = "{FS:A}", online = true, guid = "Player-1234-0000000004" } })
		state.env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
		FS:Send("TEST", {}, "WHISPER", "Gone Away-Realm")
		assert.is_true(ns.Comm.FilterNotFound(nil, "CHAT_MSG_SYSTEM", "No player named 'Gone Away' is currently playing."))
		assert.is_false(ns.Comm.FilterNotFound(nil, "CHAT_MSG_SYSTEM", "No player named 'Someone Else' is currently playing."))
		-- From now on they are reached over the guild channel.
		FS:Send("TEST", {}, "WHISPER", "Gone Away-Realm")
		local last = state.sent[#state.sent]
		assert.equals("GUILD", last.distribution)
		assert.equals("Gone Away-Realm", ns.Comm.Decode(last.text).to)
	end)

	it("/fs whoami prints the names the game reports", function()
		local state = boot()
		state.env.UnitName = function() return "Lakota" end
		wow.slash(state, "whoami")
		local out = table.concat(state.printed, "\n")
		assert.matches("PlayerName: Lakota Blackelk-Realm", out, 1, true)
		assert.matches("Roster: Lakota Blackelk-Realm | rank 0 | officer note: {FS:A}", out, 1, true)
		assert.matches("archivist: true", out, 1, true)
	end)
end)
