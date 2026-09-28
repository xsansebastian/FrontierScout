local _, ns = ...

-- Building blocks shared by the browser and the map side panel.
local L = ns.L
local Categories, Format = ns.Categories, ns.Format

local Widgets = {}
ns.Widgets = Widgets

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

function Widgets.Button(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

-- Full description of an entry for a detail pane.
function Widgets.DetailText(e)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	add(("|cffffd100%s|r  %s (%s)"):format(Categories.Label(e.sub), ns.Maps.Name(e.map) or "?", Format.Coords(e.x, e.y)))
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
			local label = Widgets.ItemLink(item.id) or ("item:" .. item.id)
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
