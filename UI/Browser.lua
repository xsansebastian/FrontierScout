local _, ns = ...

-- Discoveries browser (docs/SPEC.md §7.4, Discoveries tab): zones on the left,
-- matching entries in the middle, the selected entry on the right.
local FS, L = ns.FS, ns.L
local Categories, Format, Query, Icons = ns.Categories, ns.Format, ns.Query, ns.Icons

local ROW_HEIGHT = 20
local MAX_ITEMS_SHOWN = 12

local browser -- the frame, created on first open
local state = { zone = nil, selected = nil, filter = { text = "", cats = {} } }
for _, cat in ipairs(Categories.order) do state.filter.cats[cat] = true end

local resolver = Query.NewMapResolver(function(map) return C_Map.GetMapInfo(map) end)

local function itemLink(id)
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local _, link = getInfo(id)
	return link
end

-- Lists --------------------------------------------------------------------------

local function newList(parent)
	local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
	local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	return box, bar, view
end

-- Creates the parts of a row button the first time it is used.
local function setupRow(row, onClick)
	if row.label then return end
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 0.82, 0, 0.18)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 4, 0)
	row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.label:SetJustifyH("LEFT")
	row.label:SetWordWrap(false)
	row.count = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	row.count:SetPoint("RIGHT", -4, 0)
	row.label:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	row:SetScript("OnClick", onClick)
end

local refresh, showDetail

local function zoneRowInit(row, data)
	setupRow(row, function(self)
		if self.data.kind == "continent" then return end
		state.zone = self.data.map
		refresh()
	end)
	row.data = data
	row.icon:Hide()
	row.count:SetText(data.count)
	row.label:ClearAllPoints()
	row.label:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	if data.kind == "continent" then
		row.label:SetPoint("LEFT", 4, 0)
		row.label:SetFontObject("GameFontNormalSmall")
		row.bg:Hide()
	else
		row.label:SetPoint("LEFT", data.kind == "zone" and 16 or 4, 0)
		row.label:SetFontObject("GameFontHighlightSmall")
		row.bg:SetShown(data.map == state.zone)
	end
	row.label:SetText(data.name)
end

local function entryRowInit(row, data)
	setupRow(row, function(self)
		state.selected = self.data.id
		refresh()
	end)
	row.data = data
	row.icon:Show()
	Icons.Apply(row.icon, data.sub)
	row.label:ClearAllPoints()
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
	row.label:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	row.label:SetText(data.title)
	row.count:SetText(Categories.Label(data.sub))
	row.bg:SetShown(data.id == state.selected)
end

-- Detail pane --------------------------------------------------------------------

local function detailText(e)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	add(("|cffffd100%s|r  %s (%s)"):format(Categories.Label(e.sub), resolver.Name(e.map) or "?", Format.Coords(e.x, e.y)))
	if e.npcID then add(L["NPC ID: %d"]:format(e.npcID)) end
	if e.desc then add("\n" .. e.desc) end
	if e.schedule then
		local s = e.schedule
		if s.respawnMin then add("\n" .. L["Respawn: %d min"]:format(s.respawnMin)) end
		if s.window then add(L["Window: %s"]:format(s.window)) end
		if s.note then add(s.note) end
	end
	if e.items then
		add("\n|cffffd100" .. L["Items"] .. "|r")
		for i, item in ipairs(e.items) do
			if i > MAX_ITEMS_SHOWN then
				add(L["...and %d more"]:format(#e.items - MAX_ITEMS_SHOWN))
				break
			end
			local label = itemLink(item.id) or ("item:" .. item.id)
			add(item.cost and (label .. "  |cffaaaaaa" .. item.cost .. "|r") or label)
		end
	end
	if e.tags then add("\n" .. L["Tags: %s"]:format(Format.Tags(e.tags))) end
	add("\n|cff888888" .. L["Added by %s on %s"]:format(Ambiguate(e.author, "none"), date("%Y-%m-%d", e.createdAt)))
	if e.rev > 1 then
		add(L["Edited by %s on %s (revision %d)"]:format(Ambiguate(e.editedBy, "none"), date("%Y-%m-%d", e.approvedAt), e.rev))
	end
	return table.concat(lines, "\n") .. "|r"
end

function showDetail()
	local d = browser.detail
	local store = FS:GetStore(true)
	local e = store and state.selected and store:Get(state.selected)
	d.entry = e
	if not e then
		d.title:SetText(L["Select a discovery"])
		d.icon:Hide()
		d.text:SetText("")
		d.waypoint:Disable()
		d.edit:Disable()
		d.delete:Disable()
		return
	end
	d.icon:Show()
	Icons.Apply(d.icon, e.sub)
	d.title:SetText(e.title)
	d.text:SetText(detailText(e))
	d.waypoint:Enable()
	d.edit:Enable()
	d.delete:Enable()
end

-- Refresh ------------------------------------------------------------------------

function refresh()
	if not (browser and browser:IsShown()) then return end
	local store = FS:GetStore(true)
	local all = store and store:All() or {}

	-- Zones count entries that pass the search and category filters.
	local zoneFilter = { text = state.filter.text, cats = state.filter.cats }
	local visible = Query.Filter(all, zoneFilter, resolver)
	local rows = Query.ZoneTree(visible, resolver, L["Other"])
	local zoneListed = false
	for _, row in ipairs(rows) do
		if row.kind == "zone" and row.map == state.zone then zoneListed = true end
	end
	if not zoneListed then state.zone = nil end -- e.g. its last entry was deleted
	table.insert(rows, 1, { kind = "all", name = L["All zones"], count = #visible })
	browser.zones:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants.RetainScrollPosition)

	state.filter.zone = state.zone
	local entries = Query.Filter(all, state.filter, resolver)
	browser.entries:SetDataProvider(CreateDataProvider(entries), ScrollBoxConstants.RetainScrollPosition)
	browser.empty:SetShown(#entries == 0)

	if state.selected and not (store and store:Get(state.selected)) then state.selected = nil end
	showDetail()
	browser:SetTitle(L["FrontierScout - %d discoveries"]:format(#all))
end

-- Construction -------------------------------------------------------------------

local function panelButton(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function buildDetail(parent)
	local d = CreateFrame("Frame", nil, parent)
	d.icon = d:CreateTexture(nil, "ARTWORK")
	d.icon:SetSize(24, 24)
	d.icon:SetPoint("TOPLEFT", 4, -4)
	d.title = d:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	d.title:SetPoint("LEFT", d.icon, "RIGHT", 6, 0)
	d.title:SetPoint("RIGHT", -4, 0)
	d.title:SetJustifyH("LEFT")

	d.waypoint = panelButton(d, L["Waypoint"], 90, function() FS:Waypoint(d.entry) end)
	d.waypoint:SetPoint("BOTTOMLEFT", 4, 4)
	d.edit = panelButton(d, L["Edit"], 70, function() FS:OpenEditor(d.entry.id) end)
	d.edit:SetPoint("LEFT", d.waypoint, "RIGHT", 4, 0)
	d.delete = panelButton(d, L["Delete"], 70, function()
		StaticPopup_Show("FRONTIERSCOUT_DELETE", d.entry.title, nil, d.entry.id)
	end)
	d.delete:SetPoint("LEFT", d.edit, "RIGHT", 4, 0)

	-- Long descriptions and vendor lists scroll.
	local scroll = CreateFrame("ScrollFrame", nil, d, "ScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", d.icon, "BOTTOMLEFT", 0, -8)
	scroll:SetPoint("BOTTOMRIGHT", -24, 32)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(1, 1)
	scroll:SetScrollChild(child)
	scroll:SetScript("OnSizeChanged", function(_, w) child:SetWidth(w) end)
	d.text = child:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	d.text:SetPoint("TOPLEFT")
	d.text:SetPoint("RIGHT", child, "RIGHT")
	d.text:SetJustifyH("LEFT")
	d.text:SetJustifyV("TOP")
	d.text:SetSpacing(2)
	hooksecurefunc(d.text, "SetText", function(fs) child:SetHeight(fs:GetStringHeight() + 8) end)
	return d
end

local function buildFilters(f)
	local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
	search:SetSize(200, 20)
	search:SetPoint("TOPLEFT", 16, -30)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function(box)
		state.filter.text = box:GetText()
		refresh()
	end)

	local anchor = search
	for _, cat in ipairs(Categories.order) do
		local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
		check:SetSize(24, 24)
		check:SetPoint("LEFT", anchor, "RIGHT", anchor == search and 12 or 70, 0)
		check:SetChecked(true)
		local label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		label:SetPoint("LEFT", check, "RIGHT", 0, 1)
		label:SetText(Categories.Label(cat))
		check:SetScript("OnClick", function(btn)
			state.filter.cats[cat] = btn:GetChecked() and true or nil
			refresh()
		end)
		anchor = check
	end

	f.search = search

	local new = panelButton(f, L["New"], 80, function() FS:OnSlashCommand("add") end)
	new:SetPoint("TOPRIGHT", -12, -28)
end

local function build()
	local f = CreateFrame("Frame", "FrontierScoutBrowser", UIParent, "ButtonFrameTemplate")
	ButtonFrameTemplate_HidePortrait(f)
	f:SetSize(860, 520)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetScript("OnShow", function() refresh() end)
	tinsert(UISpecialFrames, "FrontierScoutBrowser")

	buildFilters(f)

	local inset = f.Inset
	inset:ClearAllPoints()
	inset:SetPoint("TOPLEFT", 8, -60)
	inset:SetPoint("BOTTOMRIGHT", -8, 8)

	local zones, zoneBar, zoneView = newList(inset)
	zones:SetPoint("TOPLEFT", 6, -6)
	zones:SetPoint("BOTTOMLEFT", 6, 6)
	zones:SetWidth(200)
	zoneView:SetElementInitializer("Button", zoneRowInit)
	ScrollUtil.InitScrollBoxListWithScrollBar(zones, zoneBar, zoneView)
	f.zones = zones

	local entries, entryBar, entryView = newList(inset)
	entries:SetPoint("TOPLEFT", zones, "TOPRIGHT", 22, 0)
	entries:SetPoint("BOTTOMLEFT", zones, "BOTTOMRIGHT", 22, 0)
	entries:SetWidth(280)
	entryView:SetElementInitializer("Button", entryRowInit)
	ScrollUtil.InitScrollBoxListWithScrollBar(entries, entryBar, entryView)
	f.entries = entries

	f.empty = inset:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	f.empty:SetPoint("TOP", entries, "TOP", 0, -20)
	f.empty:SetText(L["No discoveries here yet.\nClick New or type /fs add."])

	f.detail = buildDetail(inset)
	f.detail:SetPoint("TOPLEFT", entries, "TOPRIGHT", 22, 0)
	f.detail:SetPoint("BOTTOMRIGHT", -6, 6)

	return f
end

StaticPopupDialogs.FRONTIERSCOUT_DELETE = {
	text = L["Delete \"%s\"?"],
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, id) FS:DeleteEntry(id) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- API ----------------------------------------------------------------------------

function FS:OpenBrowser()
	if not self:GetStore() then return end
	browser = browser or build()
	if not state.zone and not state.selected then
		local map = C_Map.GetBestMapForUnit("player")
		state.zone = map and resolver.Zone(map) or nil
		-- Start on "All zones" when there is nothing here.
		local here = Query.Filter(self.store:All(), { zone = state.zone }, resolver)
		if #here == 0 then state.zone = nil end
	end
	if browser:IsShown() then refresh() else browser:Show() end
end

-- Selects an entry in the browser. The browser opens unless `open` is false,
-- in which case only an already open browser shows it (e.g. after saving).
function FS:SelectEntry(id, open)
	local e = self.store and self.store:Get(id)
	if not e then return end
	state.selected = id
	if state.zone and resolver.Zone(e.map) ~= state.zone then state.zone = nil end
	if open ~= false or (browser and browser:IsShown()) then self:OpenBrowser() end
end

function FS:ToggleBrowser()
	if browser and browser:IsShown() then browser:Hide() else self:OpenBrowser() end
end

FS:RegisterMessage("FRONTIERSCOUT_ENTRIES_CHANGED", function() refresh() end)
FS:RegisterMessage("FRONTIERSCOUT_GUILD_CHANGED", function()
	state.zone, state.selected = nil, nil
	if browser then browser:Hide() end
end)
-- Item links in the detail pane fill in once the client has the item data.
FS:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
	local e = browser and browser:IsShown() and browser.detail.entry
	if e and e.items then showDetail() end
end)

-- Key binding (Bindings.xml).
function FrontierScout_ToggleBinding()
	FS:ToggleBrowser()
end
