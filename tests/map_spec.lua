local wow = require("tests.helpers.wow")
local frames = require("tests.helpers.frames")

-- M2 surfaces on fake frames: world map and minimap pins, the side panel,
-- tooltips and options.

local MAPS = {
	[12] = { name = "Kalimdor", mapType = 2, parentMapID = 0 },
	[1] = { name = "Durotar", mapType = 3, parentMapID = 12 },
	[7] = { name = "Mulgore", mapType = 3, parentMapID = 12 },
	[50] = { name = "Elsewhere", mapType = 3, parentMapID = 0 },
}

local function boot()
	local state, FS = wow.boot({ guild = "Wardens", ui = true })
	state.env.C_Map = {
		GetMapInfo = function(map) return MAPS[map] end,
		GetBestMapForUnit = function() return 1 end,
	}
	FS:OnEnable()
	local rare = FS:SaveEntry(nil, { cat = "npc", sub = "rare", title = "Grizzlegut", map = 1, x = 0.5, y = 0.5, npcID = 3056 })
	local vendor = FS:SaveEntry(nil, { cat = "npc", sub = "vendor", title = "Jo", map = 7, x = 0.2, y = 0.2,
		npcID = 777, items = { { id = 100, cost = "5s" } } })
	local cave = FS:SaveEntry(nil, { cat = "location", sub = "cave", title = "Far cave", map = 50, x = 0.1, y = 0.1 })
	return state, FS, { rare = rare, vendor = vendor, cave = cave }
end

local function showMap(state, map)
	state.mapID = map
	state.env.WorldMapFrame:OnMapChanged()
end

local function titles(list)
	local out = {}
	for _, p in ipairs(list) do out[#out + 1] = p.icon.entry.title end
	table.sort(out)
	return out
end

describe("World map pins", function()
	it("pin the shown continent's discoveries", function()
		local state = boot()
		showMap(state, 1)
		assert.same({ "Grizzlegut", "Jo" }, titles(state.pins.world))
		assert.equals(2, state.pins.world[1].flag)
		showMap(state, 50)
		assert.same({ "Far cave" }, titles(state.pins.world))
	end)

	it("follow the category filter and the enable setting", function()
		local state, FS = boot()
		showMap(state, 12)
		FS.db.profile.worldmap.cats.npc = false
		FS:SendMessage("FRONTIERSCOUT_DISPLAY_CHANGED")
		assert.same({}, titles(state.pins.world))
		FS.db.profile.worldmap.cats.npc = true
		FS.db.profile.worldmap.enabled = false
		FS:SendMessage("FRONTIERSCOUT_DISPLAY_CHANGED")
		assert.same({}, titles(state.pins.world))
	end)

	it("update when discoveries change", function()
		local state, FS, e = boot()
		showMap(state, 1)
		FS:DeleteEntry(e.rare.id)
		assert.same({ "Jo" }, titles(state.pins.world))
	end)

	it("click: panel, shift-click: waypoint, right-click: menu", function()
		local state, FS, e = boot()
		showMap(state, 1)
		local pin = FS.pinFrames.world[e.rare.id]
		pin:Click("LeftButton")
		local panel = state.frames.FrontierScoutMapPanel
		assert.equals("Grizzlegut", panel.detail.title:GetText())

		local target
		FS.SetWaypoint = function(_, entry) target = entry return true, "native" end
		state.shift = true
		pin:Click("LeftButton")
		assert.equals(e.rare, target)
		state.shift = false

		pin:Click("RightButton")
		local menu = state.menus[1]
		assert.is_function(menu.buttons.Waypoint)
		assert.is_function(menu.buttons.Edit)
		menu.buttons.Delete()
		assert.same({ "FRONTIERSCOUT_DELETE", "Grizzlegut", nil, e.rare.id }, state.popups[1])
	end)

	it("ctrl-right-click adds a discovery at the cursor", function()
		local state, FS = boot()
		showMap(state, 7)
		local container = state.env.WorldMapFrame.ScrollContainer
		container.scripts.OnMouseDown(container, "RightButton")
		assert.is_nil(FS.editor) -- needs ctrl
		state.ctrl = true
		container.scripts.OnMouseDown(container, "RightButton")
		assert.equals("25.00, 75.00", frames.find(FS.editor, "Coordinates"):GetText())
		assert.equals("Zone: Mulgore", frames.find(FS.editor, "Zone: Mulgore").text)
	end)
end)

describe("Minimap pins", function()
	it("pin the player's zone only, with the edge setting", function()
		local state, FS = boot()
		wow.fire(state, "ZONE_CHANGED_NEW_AREA")
		assert.same({ "Grizzlegut" }, titles(state.pins.mini))
		assert.is_false(state.pins.mini[1].edge)
		FS.db.profile.minimap.edge = true
		FS:SendMessage("FRONTIERSCOUT_DISPLAY_CHANGED")
		assert.is_true(state.pins.mini[1].edge)
		state.env.C_Map.GetBestMapForUnit = function() return 7 end
		wow.fire(state, "ZONE_CHANGED_NEW_AREA")
		assert.same({ "Jo" }, titles(state.pins.mini))
	end)
end)

describe("Map side panel", function()
	local function rowTexts(panel)
		local out = {}
		for _, row in ipairs(panel.list.rows) do out[#out + 1] = row.label:GetText() end
		return out
	end

	it("lists the shown map's discoveries by category and searches", function()
		local state = boot()
		showMap(state, 12)
		local panel = state.frames.FrontierScoutMapPanel
		assert.same({ "NPC", "Grizzlegut", "Jo" }, rowTexts(panel))
		showMap(state, 7)
		assert.same({ "NPC", "Jo" }, rowTexts(panel))
		showMap(state, 12)
		panel.search:SetText("grizz")
		panel.search.scripts.OnTextChanged(panel.search)
		assert.same({ "NPC", "Grizzlegut" }, rowTexts(panel))
	end)

	it("pulses the pin of a hovered row", function()
		local state, FS, e = boot()
		showMap(state, 1)
		local row = state.frames.FrontierScoutMapPanel.list.rows[2]
		row.scripts.OnEnter(row)
		assert.is_true(FS.pinFrames.world[e.rare.id].glow.shown)
		row.scripts.OnLeave(row)
		assert.is_false(FS.pinFrames.world[e.rare.id].glow.shown)
	end)

	it("toggles and remembers its state", function()
		local state, FS = boot()
		local toggle = state.frames.FrontierScoutMapToggle
		toggle:Click()
		assert.is_false(FS.db.profile.panel.shown)
		assert.is_false(state.frames.FrontierScoutMapPanel:IsShown())
		toggle:Click()
		assert.is_true(FS.db.profile.panel.shown)
	end)

	it("shows details and goes back", function()
		local state, FS, e = boot()
		showMap(state, 1)
		FS:ShowInPanel(e.rare.id)
		local panel = state.frames.FrontierScoutMapPanel
		assert.is_true(panel.detail:IsShown())
		assert.is_false(panel.list:IsShown())
		panel.detail.back:Click()
		assert.is_false(panel.detail:IsShown())
	end)
end)

describe("Tooltips", function()
	local function tooltip()
		return { lines = {}, AddLine = function(self, text) self.lines[#self.lines + 1] = text end }
	end

	it("mark NPCs with discoveries", function()
		local state = boot()
		local tt = tooltip()
		state.tooltipCalls[2](tt, { guid = "Creature-0-1-0-1-3056-0000000001" })
		assert.same({ "|cff33ccffFrontierScout:|r Grizzlegut (Rare)" }, tt.lines)
		tt = tooltip()
		state.tooltipCalls[2](tt, { guid = "Creature-0-1-0-1-9999-0000000001" })
		assert.same({}, tt.lines)
	end)

	it("say where an item is sold", function()
		local state = boot()
		local tt = tooltip()
		state.tooltipCalls[0](tt, { id = 100 })
		assert.same({ "|cff33ccffFrontierScout:|r Jo (sold at Mulgore)" }, tt.lines)
	end)

	it("skip secret values and respect the setting", function()
		local state, FS = boot()
		state.env.issecretvalue = function() return true end
		local tt = tooltip()
		state.tooltipCalls[2](tt, { guid = "Creature-0-1-0-1-3056-0000000001" })
		assert.same({}, tt.lines)
		state.env.issecretvalue = nil
		FS.db.profile.tooltips = false
		state.tooltipCalls[2](tt, { guid = "Creature-0-1-0-1-3056-0000000001" })
		assert.same({}, tt.lines)
	end)

	it("summarize an entry for pins", function()
		local _, FS, e = boot()
		local tt = tooltip()
		tt.SetText = function(self, text) self.title = text end
		tt.Show = function() end
		FS:EntryTooltip(tt, e.vendor)
		assert.matches("Jo", tt.title, 1, true)
		assert.matches("Vendor · Mulgore (20.0, 20.0)", tt.lines[1], 1, true)
		assert.matches("1 items", table.concat(tt.lines, "\n"), 1, true)
	end)
end)

describe("Options", function()
	it("registers a table whose settings update the map", function()
		local state, FS = boot()
		showMap(state, 1)
		local opts = state.options.FrontierScout()
		local enabled = opts.args.worldmap.args.enabled
		enabled.set(nil, false)
		assert.is_false(FS.db.profile.worldmap.enabled)
		assert.same({}, state.pins.world)
		local cats = opts.args.minimap.args.cats
		cats.set(nil, "npc", false)
		assert.is_false(cats.get(nil, "npc"))
	end)

	it("opens with /fs config", function()
		local state = boot()
		wow.slash(state, "config")
		assert.equals("FrontierScout", state.optionsOpened)
	end)
end)
