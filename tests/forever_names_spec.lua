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

describe("Tolerant roster lookup", function()
	local function bootLookup(opts)
		local state, FS, ns = wow.boot({ guild = "Wardens", rank = 2, canViewNotes = opts and opts.notes,
			guildInfo = "[FS1 s=9 ar=1]",
			roster = { { name = "Lakota Blackelk-Realm", rankIndex = 1, officerNote = "{FS:A}", online = true, guid = "Player-1234-0000000001" } } })
		FS:OnEnable()
		return state, FS, ns
	end

	it("finds members whatever form their name arrives in", function()
		local _, FS = bootLookup()
		for _, name in ipairs({ "Lakota Blackelk-Realm", "Lakota Blackelk", "lakota blackelk-Realm", "LakotaBlackelk" }) do
			local member, key = FS:Member(name)
			assert.is_not_nil(member, name)
			assert.equals("Lakota Blackelk-Realm", key)
		end
		assert.is_nil(FS:Member("Lakota Blackelk-OtherRealm"))
		assert.is_nil(FS:Member("Someone Else"))
	end)

	it("accepts archivist data from a name in another form", function()
		local _, FS, ns = bootLookup({ notes = true })
		local text = ns.Comm.Encode({ v = 1, g = FS.guildKey, t = "APPR", e = { id = "E-1", cat = "location", sub = "cave",
			title = "Approved", map = 1, x = 0.1, y = 0.1, rev = 1, approvedAt = 5, approvedBy = "Lakota Blackelk-Realm" } })
		FS:OnCommReceived(ns.Comm.PREFIX, text, "GUILD", "lakota blackelk")
		assert.equals("Approved", FS.store:Get("E-1").title)
	end)

	it("says in debug why archivist data was ignored", function()
		local state, FS, ns = bootLookup({ notes = true })
		FS.db.profile.debug = true
		state.roster[1].officerNote = "raid lead" -- readable, but without the tag
		wow.fire(state, "GUILD_ROSTER_UPDATE")
		local text = ns.Comm.Encode({ v = 1, g = FS.guildKey, t = "APPR", e = { id = "E-1", cat = "location", sub = "cave",
			title = "X", map = 1, x = 0.1, y = 0.1, rev = 1, approvedAt = 5 } })
		FS:OnCommReceived(ns.Comm.PREFIX, text, "GUILD", "Lakota Blackelk")
		local out = table.concat(state.printed, "\n")
		assert.matches("ignored APPR from Lakota Blackelk-Realm: not an archivist for this client", out, 1, true)
		assert.matches("{FS:A} seen: false, can read officer notes: true", out, 1, true)
	end)
end)

describe("Officer notes that can't be read", function()
	it("fall back to the rank gate instead of trusting nobody", function()
		local state, FS = wow.boot({ guild = "Wardens", rank = 0, canViewNotes = true, guildInfo = "[FS1 s=9 ar=1]",
			roster = { { name = "Lakota Blackelk-Realm", rankIndex = 1, officerNote = "", online = true, guid = "Player-1234-0000000001" } } })
		FS:OnEnable()
		assert.equals(0, FS.notesRead)
		assert.is_false(FS:CanViewOfficerNotes())
		assert.is_true(FS:IsArchivist("Lakota Blackelk-Realm"))
		-- Once notes are readable, the tag is required again.
		state.roster[1].officerNote = "raid lead"
		wow.fire(state, "GUILD_ROSTER_UPDATE")
		assert.is_true(FS:CanViewOfficerNotes())
		assert.is_false(FS:IsArchivist("Lakota Blackelk-Realm"))
	end)
end)
