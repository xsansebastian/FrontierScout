local _, ns = ...

-- Discoveries browser (docs/SPEC.md §7.4, Discoveries tab): zones on the left,
-- matching entries in the middle, the selected entry on the right.
local FS, L = ns.FS, ns.L
local Categories, Query, Icons, Widgets = ns.Categories, ns.Query, ns.Icons, ns.Widgets

local browser -- the frame, created on first open
local state = { zone = nil, selected = nil, filter = { text = "", cats = {} } }
for _, cat in ipairs(Categories.order) do state.filter.cats[cat] = true end

local resolver = ns.Maps

-- Rows ---------------------------------------------------------------------------

local refresh, showDetail

local function zoneRowInit(row, data)
	Widgets.SetupRow(row, function(self)
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
	Widgets.SetupRow(row, function(self)
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
		d.report:Disable()
		return
	end
	d.icon:Show()
	Icons.Apply(d.icon, e.sub)
	d.title:SetText(e.title)
	d.text:SetText(Widgets.DetailText(e))
	d.waypoint:Enable()
	Widgets.Gate(d.edit, FS:Can("edit", e))
	Widgets.Gate(d.delete, FS:Can("delete", e))
	Widgets.Gate(d.report, FS:Can("report", e))
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
	for _, tab in ipairs(browser.tabs) do
		local p = browser.pages[tab.key]
		if p then
			tab:SetShown(p.page.visible())
			tab:SetText(p.page.label())
		end
		if tab.key == browser.tab then tab:LockHighlight() else tab:UnlockHighlight() end
	end
	local active = browser.pages[browser.tab]
	if active then
		if active.page.visible() then active.page.refresh(active.frame) else FS:ShowBrowserTab("discoveries") end
	end
	Widgets.Gate(browser.new, FS:Can("create"))
	browser.banner:SetShown(not FS.aclConfigured and CanEditGuildInfo())
end

-- Construction -------------------------------------------------------------------

local function buildDetail(parent)
	local d = CreateFrame("Frame", nil, parent)
	d.icon = d:CreateTexture(nil, "ARTWORK")
	d.icon:SetSize(24, 24)
	d.icon:SetPoint("TOPLEFT", 4, -4)
	d.title = d:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	d.title:SetPoint("LEFT", d.icon, "RIGHT", 6, 0)
	d.title:SetPoint("RIGHT", -4, 0)
	d.title:SetJustifyH("LEFT")

	d.waypoint = Widgets.Button(d, L["Waypoint"], 90, function() FS:Waypoint(d.entry) end)
	d.waypoint:SetPoint("BOTTOMLEFT", 4, 4)
	d.edit = Widgets.Button(d, L["Edit"], 70, function() FS:OpenEditor(d.entry.id) end)
	d.edit:SetPoint("LEFT", d.waypoint, "RIGHT", 4, 0)
	d.delete = Widgets.Button(d, L["Delete"], 70, function()
		StaticPopup_Show("FRONTIERSCOUT_DELETE", d.entry.title, nil, d.entry.id)
	end)
	d.delete:SetPoint("LEFT", d.edit, "RIGHT", 4, 0)
	d.report = Widgets.Button(d, L["Report outdated"], 120, function()
		StaticPopup_Show("FRONTIERSCOUT_REPORT", d.entry.title, nil, d.entry.id)
	end)
	d.report:SetPoint("LEFT", d.delete, "RIGHT", 4, 0)

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
	local top = CreateFrame("Frame", nil, f)
	top:SetPoint("TOPLEFT", 0, -24)
	top:SetPoint("TOPRIGHT", 0, -24)
	top:SetHeight(30)
	f.top = top
	local search = CreateFrame("EditBox", nil, top, "SearchBoxTemplate")
	search:SetSize(200, 20)
	search:SetPoint("TOPLEFT", 16, -6)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function(box)
		state.filter.text = box:GetText()
		refresh()
	end)

	local anchor = search
	for _, cat in ipairs(Categories.order) do
		local check = CreateFrame("CheckButton", nil, top, "UICheckButtonTemplate")
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

	local new = Widgets.Button(top, L["New"], 80, function() FS:OnSlashCommand("add") end)
	new:SetPoint("TOPRIGHT", -12, -4)
	f.new = new

	-- Shown to leadership until the guild has a FrontierScout tag.
	f.banner = top:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.banner:SetPoint("BOTTOMRIGHT", new, "BOTTOMLEFT", -8, 4)
	f.banner:SetText(L["Not set up for this guild yet: only the Guild Master can write. See /fs config."])
	f.banner:Hide()
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

	local zones, zoneBar, zoneView = Widgets.NewList(inset)
	zones:SetPoint("TOPLEFT", 6, -6)
	zones:SetPoint("BOTTOMLEFT", 6, 6)
	zones:SetWidth(200)
	zoneView:SetElementInitializer("Button", zoneRowInit)
	ScrollUtil.InitScrollBoxListWithScrollBar(zones, zoneBar, zoneView)
	f.zones = zones

	local entries, entryBar, entryView = Widgets.NewList(inset)
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

	-- Tabs: Discoveries plus the pages other files register in ns.BrowserPages.
	f.pages, f.tabs = {}, {}
	local function addTab(key, label)
		local tab = Widgets.Button(f, label, 130, function() FS:ShowBrowserTab(key) end)
		local prev = f.tabs[#f.tabs]
		if prev then
			tab:SetPoint("LEFT", prev, "RIGHT", 4, 0)
		else
			tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 8, -2)
		end
		tab.key = key
		f.tabs[#f.tabs + 1] = tab
		return tab
	end
	addTab("discoveries", L["Discoveries"])
	for _, page in ipairs(ns.BrowserPages) do
		local frame = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
		frame:SetPoint("TOPLEFT", 8, -30)
		frame:SetPoint("BOTTOMRIGHT", -8, 8)
		frame:Hide()
		page.build(frame)
		f.pages[page.key] = { page = page, frame = frame, tab = addTab(page.key, page.label()) }
	end
	f.tab = "discoveries"

	return f
end

-- Switches the browser to tab `key` ("discoveries" or a registered page).
function FS:ShowBrowserTab(key)
	if not browser then return end
	local page = browser.pages[key]
	if page and not page.page.visible() then key = "discoveries" end
	browser.tab = key
	browser.top:SetShown(key == "discoveries")
	browser.Inset:SetShown(key == "discoveries")
	for k, p in pairs(browser.pages) do p.frame:SetShown(k == key) end
	refresh()
end

-- Prints the outcome of a write that may have become a proposal.
function FS:ReportWrite(result, err, title)
	if result and result.pid then
		self:Print(L["Submitted for review: %s"]:format(title))
	elseif not result and err == "denied" then
		self:Print(L["Your guild rank can't do that. Guild leadership sets this up in /fs config."])
	end
end

StaticPopupDialogs.FRONTIERSCOUT_DELETE = {
	text = L["Delete \"%s\"?"],
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, id)
		local e = FS.store and FS.store:Get(id)
		local result, err = FS:DeleteEntry(id)
		FS:ReportWrite(result, err, e and e.title or "?")
	end,
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

FS:Listen("FRONTIERSCOUT_ENTRIES_CHANGED", function() refresh() end)
FS:Listen("FRONTIERSCOUT_ROSTER_UPDATED", function() refresh() end)
FS:Listen("FRONTIERSCOUT_PROPOSALS_CHANGED", function() refresh() end)
FS:Listen("FRONTIERSCOUT_QUEUE_CHANGED", function() refresh() end)
FS:Listen("FRONTIERSCOUT_SYNC_DONE", function() refresh() end)
FS:Listen("FRONTIERSCOUT_GUILD_CHANGED", function()
	state.zone, state.selected = nil, nil
	if browser then browser:Hide() end
end)
-- Item links in the detail pane fill in once the client has the item data.
FS:ListenEvent("GET_ITEM_INFO_RECEIVED", function()
	local e = browser and browser:IsShown() and browser.detail.entry
	if e and e.items then showDetail() end
end)

-- Key binding (Bindings.xml).
function FrontierScout_ToggleBinding()
	FS:ToggleBrowser()
end

-- Popup text boxes moved between client versions.
local function popupText(popup)
	local box = (popup.GetEditBox and popup:GetEditBox()) or popup.editBox or popup.EditBox
	return box and box:GetText() or ""
end
ns.PopupText = popupText

StaticPopupDialogs.FRONTIERSCOUT_REPORT = {
	text = L["Report \"%s\" as outdated? What changed?"],
	button1 = L["Report"],
	button2 = CANCEL,
	hasEditBox = true,
	maxLetters = 200,
	OnAccept = function(popup, id)
		if FS:Report(id, popupText(popup)) then FS:Print(L["Thanks! The archivists will take a look."]) end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
