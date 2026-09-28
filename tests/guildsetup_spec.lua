local wow = require("tests.helpers.wow")

-- M3 in the UI: buttons gated by rank, the setup banner and Guild Setup options.

local TAG = "[FS1 s=2 eo=2 ea=1 do=1 da=0 r=9 ar=1]"
local MAPS = { [1] = { name = "Durotar", mapType = 3, parentMapID = 0 } }

local function boot(rank, guildInfo)
	local state, FS = wow.boot({ guild = "Wardens", ui = true, rank = rank, guildInfo = guildInfo or TAG,
		ranks = { "Guild Master", "Officer", "Member", "Initiate" } })
	state.env.C_Map = {
		GetMapInfo = function(map) return MAPS[map] end,
		GetBestMapForUnit = function() return 1 end,
	}
	FS:OnEnable()
	return state, FS
end

local function othersEntry(FS)
	return FS.store:Create({ cat = "npc", sub = "rare", title = "Rare", map = 1, x = 0.5, y = 0.5 },
		{ id = "E-x", by = "Nobody-Realm", now = 1 })
end

describe("Permission gating in the UI", function()
	it("disables what the rank can't do, with a reason", function()
		local state, FS = boot(2)
		local e = othersEntry(FS)
		FS:SelectEntry(e.id)
		local browser = state.frames.FrontierScoutBrowser
		assert.is_true(browser.new:IsEnabled())
		assert.is_false(browser.detail.edit:IsEnabled())
		assert.is_false(browser.detail.delete:IsEnabled())
		assert.matches("guild rank", browser.detail.edit.gateReason, 1, true)
		assert.is_true(browser.detail.waypoint:IsEnabled())
	end)

	it("disables New below the submit rank and refuses the editor", function()
		local state, FS = boot(3)
		FS:OpenBrowser()
		assert.is_false(state.frames.FrontierScoutBrowser.new:IsEnabled())
		FS:OpenEditor(nil, {})
		assert.is_nil(FS.editor)
	end)

	it("leaves Edit and Delete out of the pin menu when not allowed", function()
		local state, FS = boot(2)
		local e = othersEntry(FS)
		FS:EntryMenu({}, e)
		assert.is_nil(state.menus[1].buttons.Edit)
		assert.is_nil(state.menus[1].buttons.Delete)
		assert.is_function(state.menus[1].buttons.Waypoint)
	end)

	it("shows the setup banner to leadership until the guild is configured", function()
		local state, FS = boot(0, "Welcome!")
		FS:OpenBrowser()
		assert.is_true(state.frames.FrontierScoutBrowser.banner:IsShown())
		local state2, FS2 = boot(2, "Welcome!")
		FS2:OpenBrowser()
		assert.is_false(state2.frames.FrontierScoutBrowser.banner:IsShown())
	end)
end)

describe("Guild Setup options", function()
	local function setup(state)
		return state.options.FrontierScout().args.guild.args
	end

	it("shows the tag to copy, then confirms once it is pasted into Guild Info", function()
		local state, FS = boot(0, "Raid nights: Tue")
		local args = setup(state)
		assert.equals(0, args.s.get())
		assert.equals("Initiate and above", args.s.values()[3])
		assert.equals("Everyone", args.r.values()[9])
		args.s.set(nil, 3)
		args.ar.set(nil, 1)
		assert.equals("[FS1 s=3 eo=0 ea=0 do=0 da=0 r=9 ar=1]", args.tag.get())
		args.tag.set(nil, "typed over") -- read-only
		assert.equals("[FS1 s=3 eo=0 ea=0 do=0 da=0 r=9 ar=1]", args.tag.get())
		assert.matches("doesn't have the tag yet", args.status.name(), 1, true)

		-- The Guild Master pastes it into Guild Info in the game's own UI.
		state.guildInfo = "Raid nights: Tue\n[FS1 s=3 eo=0 ea=0 do=0 da=0 r=9 ar=1]"
		args.recheck.func()
		assert.matches("has these settings", args.status.name(), 1, true)
		assert.is_true(FS.aclConfigured)
		assert.equals(3, FS.acl.s)
	end)

	it("says when Guild Info has older settings", function()
		local state = boot(0, "[FS1 s=0]")
		local args = setup(state)
		args.s.set(nil, 2)
		assert.matches("other settings: [FS1 s=0]", args.status.name(), 1, true)
	end)

	it("says when Guild Info has no room for the tag", function()
		local state = boot(0, ("x"):rep(490))
		assert.matches("shorten it by", setup(state).status.name(), 1, true)
	end)

	it("never calls the protected SetGuildInfoText", function()
		local state = boot(0)
		state.env.SetGuildInfoText = function() error("protected: blocked in the game") end
		local args = setup(state)
		args.recheck.func()
		args.tag.get()
		args.status.name()
	end)

	it("lists archivists", function()
		local state = boot(0)
		state.roster = { { name = "Olga-Realm", rankIndex = 1, officerNote = "{FS:A}", online = true } }
		wow.fire(state, "GUILD_ROSTER_UPDATE")
		assert.matches("Archivists: |cff33ff33Olga", setup(state).archivists.name(), 1, true)
	end)
end)
