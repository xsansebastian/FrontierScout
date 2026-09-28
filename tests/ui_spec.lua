local wow = require("tests.helpers.wow")
local frames = require("tests.helpers.frames")

-- Smoke tests: drive the browser and the edit dialog on fake frames. They
-- catch logic errors in the UI code, not wrong Blizzard API usage.

local MAPS = {
	[12] = { name = "Kalimdor", mapType = 2, parentMapID = 0 },
	[1] = { name = "Durotar", mapType = 3, parentMapID = 12 },
	[7] = { name = "Mulgore", mapType = 3, parentMapID = 12 },
}

local function boot()
	local state, FS, ns = wow.boot({ guild = "Wardens", ui = true })
	state.env.C_Map = {
		GetMapInfo = function(map) return MAPS[map] end,
		GetBestMapForUnit = function() return 1 end,
		GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.25 end } end,
	}
	state.env.UnitExists = function() return false end
	FS:OnEnable()
	return state, FS, ns
end

local RARE = { cat = "npc", sub = "rare", title = "Grizzlegut", map = 1, x = 0.5, y = 0.25, npcID = 3056 }

local function save(editor)
	frames.find(editor, "Save"):Fire("OnClick")
end

describe("Edit dialog", function()
	it("pre-fills a draft and saves it", function()
		local state, FS = boot()
		FS:OpenBrowser()
		FS:OpenEditor(nil, RARE)
		local editor = FS.editor
		assert.equals("Grizzlegut", frames.find(editor, "Title"):GetText())
		assert.equals("50.00, 25.00", frames.find(editor, "Coordinates"):GetText())
		assert.equals("3056", frames.find(editor, "NPC ID"):GetText())
		frames.find(editor, "Tags (comma-separated, up to 5)"):SetText("elite, cave")

		save(editor)
		assert.is_nil(FS.editor)
		local all = FS.store:All()
		assert.equals(1, #all)
		assert.same({ "elite", "cave" }, all[1].tags)
		assert.equals(3056, all[1].npcID)
		-- Saving shows the new entry in the open browser.
		local browser = state.frames.FrontierScoutBrowser
		assert.equals("Grizzlegut", browser.detail.title:GetText())
	end)

	it("does not open the browser after saving", function()
		local state, FS = boot()
		FS:OpenEditor(nil, RARE)
		save(FS.editor)
		assert.equals(1, FS.store:Count())
		assert.is_nil(state.frames.FrontierScoutBrowser)
	end)

	it("shows validation errors and keeps the dialog open", function()
		local _, FS = boot()
		FS:OpenEditor(nil, { cat = "location", sub = "cave", title = "Cave" })
		save(FS.editor)
		assert.matches("No position yet", FS.editor.status, 1, true)
		frames.find(FS.editor, "Use my position"):Fire("OnClick")
		frames.find(FS.editor, "Title"):SetText("")
		save(FS.editor)
		assert.matches("A title is required.", FS.editor.status, 1, true)
		assert.equals(0, FS.store:Count())
	end)

	it("changes fields with the category and keeps typed text", function()
		local _, FS = boot()
		FS:OpenEditor(nil, RARE)
		frames.find(FS.editor, "Title"):SetText("Typed")
		frames.find(FS.editor, "Category"):Fire("OnValueChanged", "event")
		assert.is_nil(frames.find(FS.editor, "NPC ID"))
		assert.is_not_nil(frames.find(FS.editor, "Respawn (minutes)"))
		assert.equals("Typed", frames.find(FS.editor, "Title"):GetText())
		assert.equals("world-event", frames.find(FS.editor, "Type").value)
		save(FS.editor)
		local e = FS.store:All()[1]
		assert.equals("event", e.cat)
		assert.is_nil(e.npcID) -- dropped: events have no NPC
	end)

	it("edits an existing entry", function()
		local _, FS = boot()
		local e = FS:SaveEntry(nil, RARE)
		FS:OpenEditor(e.id)
		assert.equals("Grizzlegut", frames.find(FS.editor, "Title"):GetText())
		frames.find(FS.editor, "Title"):SetText("Renamed")
		save(FS.editor)
		assert.equals("Renamed", FS.store:Get(e.id).title)
		assert.equals(2, FS.store:Get(e.id).rev)
	end)

	it("inserts shift-clicked links into the focused field", function()
		local state, FS = boot()
		FS:OpenEditor(nil, RARE)
		local items = frames.find(FS.editor, "Items (one per line: item link or ID = cost)")
		items.editBox.focus = true
		state.env.ChatFrameUtil.InsertLink("[link]")
		assert.equals("[link]", items.editBox:GetText())
	end)

	it("adds a Scout button to the merchant window", function()
		local state, FS = boot()
		state.env.MerchantFrame = frames.fake("MerchantFrame")
		state.env.GetMerchantNumItems = function() return 0 end
		wow.fire(state, "MERCHANT_SHOW")
		FS.scoutButton:Click()
		assert.equals("vendor", frames.find(FS.editor, "Type").value)
	end)
end)

describe("Browser", function()
	it("lists zones and entries, selects and deletes", function()
		local state, FS = boot()
		local a = FS:SaveEntry(nil, RARE)
		FS:SaveEntry(nil, { cat = "location", sub = "treasure", title = "Chest", map = 7, x = 0.1, y = 0.1 })
		FS:OpenBrowser()
		local browser = state.frames.FrontierScoutBrowser

		-- Starts on the player's zone (Durotar) because it has entries.
		local zoneNames = {}
		for _, row in ipairs(browser.zones.rows) do zoneNames[#zoneNames + 1] = row.label:GetText() end
		assert.same({ "All zones", "Kalimdor", "Durotar", "Mulgore" }, zoneNames)
		assert.equals(1, #browser.entries.rows)

		browser.zones.rows[1]:Click() -- All zones
		assert.equals(2, #browser.entries.rows)


		browser.search:SetText("chest")
		browser.search.scripts.OnTextChanged(browser.search)
		assert.equals(1, #browser.entries.rows)
		assert.equals("Chest", browser.entries.rows[1].label:GetText())
		browser.search:SetText("")
		browser.search.scripts.OnTextChanged(browser.search)
		browser.zones.rows[3]:Click() -- back to Durotar
		assert.equals(1, #browser.entries.rows)

		local row
		for _, r in ipairs(browser.entries.rows) do if r.data.id == a.id then row = r end end
		row:Click()
		assert.equals("Grizzlegut", browser.detail.title:GetText())
		assert.matches("NPC ID: 3056", browser.detail.text:GetText(), 1, true)
		assert.is_true(browser.detail.delete.enabled)

		browser.detail.delete:Click()
		assert.same({ "FRONTIERSCOUT_DELETE", "Grizzlegut", nil, a.id }, state.popups[1])
		-- Deleting Durotar's only entry drops the zone and falls back to all zones.
		state.env.StaticPopupDialogs.FRONTIERSCOUT_DELETE.OnAccept(nil, a.id)
		assert.equals(1, #browser.entries.rows)
		assert.equals("Chest", browser.entries.rows[1].label:GetText())
		assert.same({ "All zones", "Kalimdor", "Mulgore" }, (function()
			local names = {}
			for _, r in ipairs(browser.zones.rows) do names[#names + 1] = r.label:GetText() end
			return names
		end)())
		assert.equals("Select a discovery", browser.detail.title:GetText())
		assert.is_false(browser.detail.delete.enabled)
	end)

	it("shows vendor stock in the detail pane", function()
		local state, FS = boot()
		local e = FS:SaveEntry(nil, { cat = "npc", sub = "vendor", title = "Jo", map = 1, x = 0.1, y = 0.1,
			items = { { id = 5, cost = "1g" }, { id = 6 } } })
		FS:SelectEntry(e.id)
		local text = state.frames.FrontierScoutBrowser.detail.text:GetText()
		assert.matches("[Item 5]  |cffaaaaaa1g|r", text, 1, true)
		assert.matches("[Item 6]", text, 1, true)
	end)

	it("sets a waypoint from the detail pane", function()
		local state, FS = boot()
		local e = FS:SaveEntry(nil, RARE)
		local target
		FS.SetWaypoint = function(_, entry) target = entry return true, "native" end
		FS:SelectEntry(e.id)
		state.frames.FrontierScoutBrowser.detail.waypoint:Click()
		assert.equals(e, target)
	end)

	it("does not open without a guild", function()
		local state, FS = wow.boot({ ui = true })
		FS:OnEnable()
		FS:OpenBrowser()
		assert.is_nil(state.frames.FrontierScoutBrowser)
	end)
end)
