local _, ns = ...

-- Building blocks shared by the browser and the map side panel.
local L = ns.L
local Categories, Format = ns.Categories, ns.Format

local Widgets = {}
ns.Widgets = Widgets

-- Browser tabs besides Discoveries: { key, label(), visible(), build(frame), refresh(frame) }.
ns.BrowserPages = {}

local ROW_HEIGHT = 20
local MAX_ITEMS_SHOWN = 12

function Widgets.ItemLink(id)
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local _, link = getInfo(id)
	return link
end

-- Scroll list: returns the ScrollBox, its scroll bar and a linear view.
function Widgets.NewList(parent)
	local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
	local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	return box, bar, view
end

-- Creates the parts of a row button the first time it is used.
function Widgets.SetupRow(row, onClick)
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

-- Widens a button to fit its text (never below `minWidth`). Call it again
-- after changing the text.
function Widgets.FitButton(b, minWidth)
	local fs = b:GetFontString()
	local textWidth = fs and fs:GetStringWidth() or 0
	b:SetWidth(math.max(minWidth or 0, textWidth + 24))
end

-- A panel button at least `width` wide, wider when its text needs it.
function Widgets.Button(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetHeight(22)
	b:SetText(text)
	Widgets.FitButton(b, width)
	b:SetScript("OnClick", onClick)
	return b
end

-- A checkbox with its label; `check.label` is the label font string.
function Widgets.CheckBox(parent, text, checked, onClick)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	check:SetSize(24, 24)
	check:SetChecked(checked)
	check.label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	check.label:SetPoint("LEFT", check, "RIGHT", 0, 1)
	check.label:SetText(text)
	check:SetScript("OnClick", onClick)
	return check
end

-- Places `check` after `prev`'s label, so the spacing follows the text length
-- (labels differ a lot between languages).
function Widgets.Follow(check, prev, gap)
	check:SetPoint("LEFT", prev.label, "RIGHT", gap or 12, -1)
end

-- Full description of an entry for a detail pane.
-- An entry's description in two parts, above and below its item list.
function Widgets.DetailParts(e)
	local top, bottom = {}, {}
	local function add(t, s) t[#t + 1] = s end
	add(top, ("|cffffd100%s|r  %s (%s)"):format(Categories.Label(e.sub), ns.Maps.Name(e.map) or "?", Format.Coords(e.x, e.y)))
	if e.npcID then add(top, L["NPC ID: %d"]:format(e.npcID)) end
	if e.desc then add(top, "\n" .. e.desc) end
	if e.schedule then
		local s = e.schedule
		if s.respawnMin then add(top, "\n" .. L["Respawn: %d min"]:format(s.respawnMin)) end
		if s.window then add(top, L["Window: %s"]:format(s.window)) end
		if s.note then add(top, s.note) end
	end
	if e.items then add(top, "\n|cffffd100" .. L["Items"] .. "|r") end
	if e.tags then add(bottom, L["Tags: %s"]:format(Format.Tags(e.tags))) end
	add(bottom, "|cff888888" .. L["Added by %s on %s"]:format(Ambiguate(e.author, "none"), date("%Y-%m-%d", e.createdAt)))
	if e.rev > 1 then
		add(bottom, L["Edited by %s on %s (revision %d)"]:format(Ambiguate(e.editedBy, "none"), date("%Y-%m-%d", e.approvedAt), e.rev))
	end
	return table.concat(top, "\n"), table.concat(bottom, "\n") .. "|r"
end

-- Full description of an entry as one text (items as plain lines).
function Widgets.DetailText(e)
	local top, bottom = Widgets.DetailParts(e)
	local lines = { top }
	for i, item in ipairs(e.items or {}) do
		if i > MAX_ITEMS_SHOWN then
			lines[#lines + 1] = L["...and %d more"]:format(#e.items - MAX_ITEMS_SHOWN)
			break
		end
		local label = Widgets.ItemLink(item.id) or ("item:" .. item.id)
		lines[#lines + 1] = item.cost and (label .. "  |cffaaaaaa" .. item.cost .. "|r") or label
	end
	lines[#lines + 1] = "\n" .. bottom
	return table.concat(lines, "\n")
end

-- Item rows ------------------------------------------------------------------------

local ITEM_ROW = 18

local function itemIcon(id)
	if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(id) end
	return GetItemIcon and GetItemIcon(id)
end

local function itemEnter(row)
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	if row.link then
		GameTooltip:SetHyperlink(row.link)
	else
		GameTooltip:SetItemByID(row.itemID)
	end
	GameTooltip:Show()
end

-- Like clicking an item link in chat: opens the item tooltip, shift-click
-- links it in chat, ctrl-click opens the dressing room.
local function itemClick(row, button)
	local link = row.link or Widgets.ItemLink(row.itemID)
	local itemString = link and link:match("|H(item:[^|]+)|h")
	if itemString then SetItemRef(itemString, link, button) end
end

local function newItemRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ITEM_ROW)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 2, 0)
	row.cost = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	row.cost:SetPoint("RIGHT", -2, 0)
	row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
	row.label:SetPoint("RIGHT", row.cost, "LEFT", -4, 0)
	row.label:SetJustifyH("LEFT")
	row.label:SetWordWrap(false)
	row:SetScript("OnEnter", itemEnter)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:SetScript("OnClick", itemClick)
	return row
end

-- A detail view: text, clickable item rows, footer text, stacked. Anchor it
-- by TOPLEFT and RIGHT; its height follows the content.
function Widgets.NewDetailView(parent, fontObject)
	local view = CreateFrame("Frame", nil, parent)
	view:SetHeight(1)
	view.rows = {}
	view.top = view:CreateFontString(nil, "ARTWORK", fontObject)
	view.top:SetPoint("TOPLEFT")
	view.top:SetPoint("RIGHT")
	view.top:SetJustifyH("LEFT")
	view.top:SetSpacing(2)
	view.items = CreateFrame("Frame", nil, view)
	view.items:SetPoint("TOPLEFT", view.top, "BOTTOMLEFT", 0, -4)
	view.items:SetPoint("RIGHT")
	view.items:SetHeight(1)
	view.more = view.items:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	view.more:SetJustifyH("LEFT")
	view.bottom = view:CreateFontString(nil, "ARTWORK", fontObject)
	view.bottom:SetPoint("TOPLEFT", view.items, "BOTTOMLEFT", 0, -10)
	view.bottom:SetPoint("RIGHT")
	view.bottom:SetJustifyH("LEFT")
	view.bottom:SetSpacing(2)

	-- Shows entry `e`, or clears the view when nil.
	function view.SetEntry(v, e)
		local top, bottom = "", ""
		if e then top, bottom = Widgets.DetailParts(e) end
		v.top:SetText(top)
		v.bottom:SetText(bottom)
		local items = e and e.items or {}
		local shown = math.min(#items, MAX_ITEMS_SHOWN)
		for i = 1, shown do
			local item = items[i]
			local row = v.rows[i]
			if not row then
				row = newItemRow(v.items)
				row:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_ROW)
				row:SetPoint("RIGHT")
				v.rows[i] = row
			end
			row.itemID = item.id
			row.link = Widgets.ItemLink(item.id)
			if not row.link and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(item.id) end
			row.icon:SetTexture(itemIcon(item.id) or "Interface\\Icons\\INV_Misc_QuestionMark")
			row.label:SetText(row.link or ("item:" .. item.id))
			row.cost:SetText(item.cost or "")
			row:Show()
		end
		for i = shown + 1, #v.rows do v.rows[i]:Hide() end
		local height = shown * ITEM_ROW
		if #items > MAX_ITEMS_SHOWN then
			v.more:ClearAllPoints()
			v.more:SetPoint("TOPLEFT", 22, -height)
			v.more:SetText(L["...and %d more"]:format(#items - MAX_ITEMS_SHOWN))
			v.more:Show()
			height = height + ITEM_ROW
		else
			v.more:Hide()
		end
		v.items:SetHeight(math.max(height, 1))
		v:SetHeight(v.top:GetStringHeight() + 4 + math.max(height, 1) + 10 + v.bottom:GetStringHeight())
	end

	return view
end

local function gateEnter(button)
	if button:IsEnabled() or not button.gateReason then return end
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	GameTooltip:SetText(button.gateReason, 1, 0.3, 0.3, 1, true)
	GameTooltip:Show()
end

-- Enables `button` when `allowed`; otherwise disables it and explains why on hover.
function Widgets.Gate(button, allowed)
	if not button.gated then
		button.gated = true
		button:SetMotionScriptsWhileDisabled(true)
		button:HookScript("OnEnter", gateEnter)
		button:HookScript("OnLeave", GameTooltip_Hide)
	end
	button.gateReason = not allowed and L["Your guild rank can't do that. Guild leadership sets this up in /fs config."] or nil
	if allowed then button:Enable() else button:Disable() end
end
