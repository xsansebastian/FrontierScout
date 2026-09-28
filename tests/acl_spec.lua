local wow = require("tests.helpers.wow")

local ACL
setup(function()
	local _, _, ns = wow.boot()
	ACL = ns.ACL
end)

describe("ACL tag", function()
	it("defaults to Guild-Master-only writes without a tag", function()
		local t, found = ACL.Parse("Welcome to the guild!")
		assert.is_false(found)
		assert.same({ s = 0, eo = 0, ea = 0, ["do"] = 0, da = 0, r = 9, ar = 0 }, t)
		assert.is_false(select(2, ACL.Parse(nil)))
	end)

	it("parses the tag anywhere in Guild Info", function()
		local t, found = ACL.Parse("Raids Tue/Thu\n[FS1 s=5 eo=5 ea=1 do=5 da=1 r=9 ar=1]\nBe nice")
		assert.is_true(found)
		assert.same({ s = 5, eo = 5, ea = 1, ["do"] = 5, da = 1, r = 9, ar = 1 }, t)
	end)

	it("keeps defaults for missing, unknown or out-of-range keys", function()
		local t = ACL.Parse("[FS1 s=3 zz=1 ar=12]")
		assert.equals(3, t.s)
		assert.equals(0, t.ar)
		assert.is_nil(t.zz)
	end)

	it("formats in a fixed order", function()
		assert.equals("[FS1 s=5 eo=5 ea=1 do=5 da=1 r=9 ar=1]",
			ACL.Format({ s = 5, eo = 5, ea = 1, ["do"] = 5, da = 1, r = 9, ar = 1 }))
	end)

	it("tells whether Guild Info has the wanted settings", function()
		local t = { s = 2, eo = 2, ea = 1, ["do"] = 2, da = 1, r = 9, ar = 1 }
		assert.equals("applied", ACL.SetupStatus("Hi\n" .. ACL.Format(t), t))
		-- Keys in another order or missing defaults still count as the same settings.
		assert.equals("applied", ACL.SetupStatus("[FS1 ar=1 s=2 eo=2 ea=1 do=2 da=1]", t))
		assert.same({ "differs", "[FS1 s=0]" }, { ACL.SetupStatus("A [FS1 s=0] B", t) })
		assert.equals("missing", ACL.SetupStatus("", t))
		assert.equals("missing", ACL.SetupStatus(nil, t))
		local status, over = ACL.SetupStatus(("x"):rep(480), t)
		assert.equals("toolong", status)
		assert.equals(480 + 1 + #ACL.Format(t) - 500, over)
	end)
end)

describe("ACL checks", function()
	local t
	before_each(function() t = ACL.Parse("[FS1 s=2 eo=2 ea=1 do=1 da=0 r=9 ar=1]") end)

	it("compares ranks to thresholds", function()
		assert.is_true(ACL.Can(t, "s", 2))
		assert.is_false(ACL.Can(t, "s", 3))
		assert.is_false(ACL.Can(t, "s", nil))
		assert.is_false(ACL.Can(t, "bogus", 0))
	end)

	it("picks own/any keys for proposals", function()
		assert.is_true(ACL.CanPropose(t, "create", 2, false))
		assert.is_true(ACL.CanPropose(t, "edit", 2, true))    -- eo
		assert.is_false(ACL.CanPropose(t, "edit", 2, false))  -- ea needs 1
		assert.is_true(ACL.CanPropose(t, "edit", 1, false))
		assert.is_false(ACL.CanPropose(t, "delete", 2, true)) -- do needs 1
		assert.is_true(ACL.CanPropose(t, "delete", 0, false))
		assert.is_true(ACL.CanPropose(t, "report", 7, false))
		assert.is_false(ACL.CanPropose(t, "fly", 0, false))
	end)

	it("lets 'any' rights cover own entries", function()
		local loose = ACL.Parse("[FS1 eo=0 ea=3]")
		assert.is_true(ACL.CanPropose(loose, "edit", 3, true))
	end)

	it("verifies archivists by rank, and by officer note for officers", function()
		local tagged = { rankIndex = 1, officerNoteHasTag = true }
		local untagged = { rankIndex = 1, officerNoteHasTag = false }
		local member = { rankIndex = 2, officerNoteHasTag = true }
		assert.is_true(ACL.IsArchivist(t, tagged, true))
		assert.is_false(ACL.IsArchivist(t, untagged, true))
		assert.is_true(ACL.IsArchivist(t, untagged, false)) -- rank gate only
		assert.is_false(ACL.IsArchivist(t, member, false))
		assert.is_false(ACL.IsArchivist(t, nil, false))
		assert.is_true(ACL.NoteHasTag("alt of Bob {FS:A}"))
		assert.is_false(ACL.NoteHasTag("{FS:B}"))
	end)
end)

-- SPEC §11 M3 exit criterion: the ACL gates a 3-rank guild correctly.
describe("A 3-rank test guild", function()
	local TAG = "[FS1 s=2 eo=2 ea=1 do=1 da=0 r=9 ar=1]"
	local ROSTER = {
		{ name = "Boss-Realm", rankIndex = 0, officerNote = "{FS:A}", online = true },
		{ name = "Olga", rankIndex = 1, officerNote = "{FS:A} raid lead", online = false },
		{ name = "Otto-Realm", rankIndex = 1, officerNote = "", online = true },
		{ name = "Scout-Realm", rankIndex = 2, officerNote = "{FS:A}", online = true },
	}
	local RARE = { cat = "npc", sub = "rare", title = "Rare", map = 1, x = 0.5, y = 0.5 }

	local function as(rank, opts)
		opts = opts or {}
		local state, FS = wow.boot({ guild = "Wardens", rank = rank, roster = ROSTER, guildInfo = TAG,
			canViewNotes = opts.notes })
		FS:OnEnable()
		return state, FS
	end

	it("reads roster, ranks and the tag", function()
		local state, FS = as(2)
		assert.is_true(FS.aclConfigured)
		assert.equals(1, FS.acl.ar)
		assert.equals("Officer", FS.rankNames[1])
		assert.same({ rankIndex = 1, officerNoteHasTag = true, online = false }, FS.roster["Olga-Realm"])
		assert.equals(1, state.rosterRequests)
	end)

	it("members propose new entries and edits to their own only", function()
		local _, FS = as(2)
		local p = FS:SaveEntry(nil, RARE)
		assert.equals("create", p.op) -- a proposal, not an entry: members aren't archivists
		local mine = FS.store:Create(RARE, { id = "E-mine", by = "Scout-Realm", now = 1 })
		assert.equals("edit", FS:SaveEntry(mine.id, RARE).op)
		assert.same({ nil, "denied" }, { FS:DeleteEntry(mine.id) })
		local theirs = FS.store:Create(RARE, { id = "E-x", by = "Olga-Realm", now = 1 })
		assert.same({ nil, "denied" }, { FS:SaveEntry(theirs.id, RARE) })
		assert.is_true(FS:Can("report", theirs))
	end)

	it("officers edit anything and delete their own", function()
		local _, FS = as(1)
		local theirs = FS.store:Create(RARE, { id = "E-x", by = "Nobody-Realm", now = 1 })
		assert.is_not_nil(FS:SaveEntry(theirs.id, RARE))
		assert.is_false(FS:Can("delete", theirs))
		local mine = FS.store:Create(RARE, { id = "E-y", by = "Scout-Realm", now = 1 })
		assert.is_true(FS:Can("delete", mine))
	end)

	it("the Guild Master can do everything", function()
		local _, FS = as(0)
		local theirs = FS.store:Create(RARE, { id = "E-x", by = "Nobody-Realm", now = 1 })
		assert.is_not_nil(FS:DeleteEntry(theirs.id))
	end)

	it("ranks below the submit threshold cannot write", function()
		local state, FS = wow.boot({ guild = "Wardens", rank = 3, guildInfo = TAG,
			ranks = { "GM", "Officer", "Member", "Initiate" } })
		FS:OnEnable()
		assert.same({ nil, "denied" }, { FS:SaveEntry(nil, RARE) })
		FS.OpenEditor = function() error("must not open") end
		wow.slash(state, "add")
		assert.matches("Your guild rank can't do that", table.concat(state.printed, "\n"), 1, true)
	end)

	it("sees archivists by rank, or by officer note when allowed to read notes", function()
		local _, member = as(2)
		assert.same({ "Boss-Realm", "Otto-Realm", "Olga-Realm" }, member:ListArchivists())
		local _, officer = as(1, { notes = true })
		assert.same({ "Boss-Realm", "Olga-Realm" }, officer:ListArchivists())
		assert.is_false(officer:IsArchivist("Scout-Realm")) -- tagged but rank too low
	end)

	it("updates when the roster changes", function()
		local state, FS = as(2)
		state.guildInfo = "[FS1 s=0]"
		wow.fire(state, "GUILD_ROSTER_UPDATE")
		assert.equals(0, FS.acl.s)
		assert.is_false(FS:Can("create"))
	end)

	it("status shows rank and role", function()
		local state = as(2)
		wow.slash(state, "status")
		assert.matches("Your rank: Member (2), archivist: no", table.concat(state.printed, "\n"), 1, true)
	end)

	it("uses the player's own rank before the roster has loaded", function()
		local state, FS = wow.boot({ guild = "Wardens", rank = 1, guildInfo = TAG })
		FS:OnEnable()
		assert.is_true(FS:AmArchivist())
		wow.slash(state, "status")
		assert.matches("archivist: yes", table.concat(state.printed, "\n"), 1, true)
	end)
end)

describe("Guild roster helpers", function()
	it("normalizes names", function()
		local _, _, ns = wow.boot()
		assert.equals("Bob-Realm", ns.Guild.FullName("Bob", "Realm"))
		assert.equals("Bob-Other", ns.Guild.FullName("Bob-Other", "Realm"))
		assert.is_nil(ns.Guild.FullName("", "Realm"))
	end)

	it("throttles roster requests to one per 15 seconds", function()
		local state, FS = wow.boot({ guild = "Wardens" })
		FS:RequestRoster()
		FS:RequestRoster()
		state.time = 1016
		FS:RequestRoster()
		assert.equals(2, state.rosterRequests)
	end)
end)
