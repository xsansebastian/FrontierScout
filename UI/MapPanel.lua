local _, ns = ...

-- Collapsible side panel on the world map (docs/SPEC.md §7.3): discoveries on
-- the shown map (and its child zones), grouped by category, with a detail view.
-- The category toggles also filter the world map pins.
local FS, L = ns.FS, ns.L
local Categories, Query, Icons, Widgets = ns.Categories, ns.Query, ns.Icons, ns.Widgets

local WIDTH = 260
local LIST_TOP = -96 -- below the title, search box and two rows of toggles

local panel, toggle
local state = { text = "", selected = nil }

local refresh

local function rowInit(row, data)
	Widgets.SetupRow(row, function(self)
		if self.data.entry then FS:ShowInPanel(self.data.entry.id) end
	end)
	row.data = data
	row.bg:Hide()
	row.label:ClearAllPoints()
	row.label:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	local e = data.entry
	if e then
		row.icon:Show()
		Icons.Apply(row.icon, e.sub)
		row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		row.label:SetFontObject("GameFontHighlightSmall")
		row.label:SetText(e.title)
		row.count:SetText("")
		row:SetScript("OnEnter", function(self) FS:HighlightPin(self.data.entry.id, true) end)
		row:SetScript("OnLeave", function(self) FS:HighlightPin(self.data.entry.id, false) end)
	else
		row.icon:Hide()
		row.label:SetPoint("LEFT", 4, 0)
		row.label:SetFontObject("GameFontNormalSmall")
		row.label:SetText(Categories.Label(data.cat))
		row.count:SetText(data.count)
		row:SetScript("OnEnter", nil)
		row:SetScript("OnLeave", nil)
	end
end

local function showDetail(e)
	local d = panel.detail
	d.entry = e
	d:SetShown(e ~= nil)
	panel.list:SetShown(e == nil)
	if not e then return end
	Icons.Apply(d.icon, e.sub)
	d.title:SetText(e.title)
	d.text:SetText(Widgets.DetailText(e))
	Widgets.Gate(d.edit, FS:Can("edit", e))
end

function refresh()
	if not (panel and panel:IsShown()) then return end
	local store = FS.store
	local map = WorldMapFrame:GetMapID()
	local rows = {}
	if store and map then
		local cats = FS.db.profile.worldmap.cats
		local header
		for _, e in ipairs(Query.Within(store:All(), ns.Maps, map, state.text, Categories.order)) do
			if cats[e.cat] then
				if not header or header.cat ~= e.cat then
					header = { cat = e.cat, count = 0 }
					rows[#rows + 1] = header
				end
				header.count = header.count + 1
				rows[#rows + 1] = { entry = e }
			end
		end
	end
	panel.list:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants.RetainScrollPosition)
	panel.empty:SetShown(#rows == 0)
	Widgets.Gate(panel.new, FS:Can("create"))
	panel.empty:SetText(store and L["No discoveries on this map."] or L["Join a guild to use FrontierScout."])
	local e = store and state.selected and store:Get(state.selected)
	if not e then state.selected = nil end
	showDetail(e)
end

local function setShown(on)
	FS.db.profile.panel.shown = on
	panel:SetShown(on)
	toggle:ClearAllPoints()
	if on then
		toggle:SetPoint("TOPRIGHT", panel, "TOPLEFT", -2, 0)
		refresh()
	else
		toggle:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "TOPRIGHT", -4, -4)
	end
end

-- Category toggles in a 2 x 2 grid: four in a row don't fit the panel.
local function buildFilters(parent)
	for i, cat in ipairs(Categories.order) do
		local b = Widgets.CheckBox(parent, Categories.Label(cat), FS.db.profile.worldmap.cats[cat], function(btn)
			FS.db.profile.worldmap.cats[cat] = btn:GetChecked() and true or false
			FS:SendMessage("FRONTIERSCOUT_DISPLAY_CHANGED")
		end)
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		b:SetPoint("TOPLEFT", 6 + col * (WIDTH / 2), -48 - row * 22)
	end
end

local function build()
	local container = WorldMapFrame.ScrollContainer
	panel = CreateFrame("Frame", "FrontierScoutMapPanel", WorldMapFrame)
	panel:SetFrameStrata("DIALOG")
	panel:SetWidth(WIDTH)
	panel:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
	panel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
	panel:EnableMouse(true)
	local bg = panel:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.05, 0.85)

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOPLEFT", 8, -8)
	title:SetText("FrontierScout")

	local search = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
	search:SetSize(WIDTH - 20, 20)
	search:SetPoint("TOPLEFT", 12, -26)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function(box)
		state.text = box:GetText()
		refresh()
	end)
	panel.search = search

	buildFilters(panel)

	local list, bar, view = Widgets.NewList(panel)
	list:SetPoint("TOPLEFT", 4, LIST_TOP)
	list:SetPoint("BOTTOMRIGHT", -20, 34)
	view:SetElementInitializer("Button", rowInit)
	ScrollUtil.InitScrollBoxListWithScrollBar(list, bar, view)
	panel.list = list

	panel.empty = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	panel.empty:SetPoint("TOP", list, "TOP", 0, -20)
	panel.empty:SetWidth(WIDTH - 20)

	local new = Widgets.Button(panel, L["New"], 70, function() FS:OnSlashCommand("add") end)
	new:SetPoint("BOTTOMLEFT", 6, 6)
	panel.new = new
	local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("LEFT", new, "RIGHT", 6, 0)
	hint:SetPoint("RIGHT", -6, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText(L["Ctrl-right-click the map to add a discovery there."])

	-- Detail view, in place of the list.
	local d = CreateFrame("Frame", nil, panel)
	d:SetPoint("TOPLEFT", 4, LIST_TOP)
	d:SetPoint("BOTTOMRIGHT", -4, 34)
	d.icon = d:CreateTexture(nil, "ARTWORK")
	d.icon:SetSize(20, 20)
	d.icon:SetPoint("TOPLEFT", 2, -2)
	d.title = d:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	d.title:SetPoint("LEFT", d.icon, "RIGHT", 4, 0)
	d.title:SetPoint("RIGHT", -2, 0)
	d.title:SetJustifyH("LEFT")
	d.text = d:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	d.text:SetPoint("TOPLEFT", d.icon, "BOTTOMLEFT", 0, -6)
	d.text:SetPoint("BOTTOMRIGHT", 0, 30)
	d.text:SetJustifyH("LEFT")
	d.text:SetJustifyV("TOP")
	d.back = Widgets.Button(d, L["Back"], 60, function()
		state.selected = nil
		refresh()
	end)
	d.back:SetPoint("BOTTOMLEFT", 2, 2)
	d.waypoint = Widgets.Button(d, L["Waypoint"], 80, function() FS:Waypoint(d.entry) end)
	d.waypoint:SetPoint("LEFT", d.back, "RIGHT", 4, 0)
	d.edit = Widgets.Button(d, L["Edit"], 60, function() FS:OpenEditor(d.entry.id) end)
	d.edit:SetPoint("LEFT", d.waypoint, "RIGHT", 4, 0)
	d:Hide()
	panel.detail = d

	toggle = CreateFrame("Button", "FrontierScoutMapToggle", WorldMapFrame, "UIPanelButtonTemplate")
	toggle:SetFrameStrata("DIALOG")
	toggle:SetSize(28, 22)
	toggle:SetText("FS")
	toggle:SetScript("OnClick", function() setShown(not panel:IsShown()) end)
	toggle:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
		GameTooltip:SetText(L["Show or hide FrontierScout discoveries"])
		GameTooltip:Show()
	end)
	toggle:SetScript("OnLeave", GameTooltip_Hide)

	setShown(FS.db.profile.panel.shown)
end

-- Called by MapPins once the world map exists.
function FS:OnWorldMapReady()
	build()
	hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
		state.selected = nil
		refresh()
	end)
	WorldMapFrame:HookScript("OnShow", function() refresh() end)
end

-- Opens the panel on an entry (clicking its pin).
function FS:ShowInPanel(id)
	if not panel then return end
	state.selected = id
	if panel:IsShown() then refresh() else setShown(true) end
end

FS:Listen("FRONTIERSCOUT_ENTRIES_CHANGED", function() refresh() end)
FS:Listen("FRONTIERSCOUT_GUILD_CHANGED", function()
	state.selected = nil
	refresh()
end)
FS:Listen("FRONTIERSCOUT_DISPLAY_CHANGED", function() refresh() end)
FS:Listen("FRONTIERSCOUT_ROSTER_UPDATED", function() refresh() end)
