local _, ns = ...

-- Add / edit dialog (docs/SPEC.md §7.5), built with AceGUI.
local FS, L = ns.FS, ns.L
local Categories, Format, Capture, Store = ns.Categories, ns.Format, ns.Capture, ns.Store

local AceGUI = LibStub("AceGUI-3.0")

local ERRORS = {
	category = L["Choose a category and type."],
	title = L["A title is required."],
	map = L["No position yet: stand on the spot and click \"Use my position\"."],
	position = L["Coordinates must look like 45.2, 67.8."],
	npcID = L["The NPC ID must be a number."],
	full = L["This guild has reached the discovery limit."],
	missing = L["This discovery no longer exists."],
}

local function mapName(map)
	local info = map and C_Map.GetMapInfo(map)
	return info and info.name or L["unknown"]
end

local function itemLink(id)
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local _, link = getInfo(id)
	return link
end

-- Draft <-> entry ------------------------------------------------------------

local function draftFrom(e)
	local s = e.schedule or {}
	return {
		cat = e.cat or "location",
		sub = e.sub,
		title = e.title or "",
		desc = e.desc or "",
		map = e.map,
		coords = (e.x and e.y) and Format.Coords(e.x, e.y, 2) or "",
		npcID = e.npcID and tostring(e.npcID) or "",
		items = Format.Items(e.items, itemLink),
		respawn = s.respawnMin and tostring(s.respawnMin) or "",
		window = s.window or "",
		note = s.note or "",
		tags = Format.Tags(e.tags),
	}
end

-- Returns entry data for Store, or nil and an error code.
local function dataFrom(d)
	if not d.map then return nil, "map" end
	local x, y = Format.ParseCoords(d.coords)
	if not x then return nil, "position" end
	local fields = Categories.fields[d.cat] or {}
	return {
		cat = d.cat,
		sub = d.sub,
		title = d.title,
		desc = d.desc,
		map = d.map,
		x = x,
		y = y,
		npcID = fields.npcID and d.npcID or nil,
		items = fields.items and Format.ParseItems(d.items) or nil,
		schedule = fields.schedule and { respawnMin = d.respawn, window = d.window, note = d.note } or nil,
		tags = Format.ParseTags(d.tags),
	}
end

-- Shift-clicked item links go into whichever dialog field has focus.
local linkTargets = {}
local function insertLink(link)
	for _, box in ipairs(linkTargets) do
		if box:HasFocus() then
			box:Insert(link)
			return
		end
	end
end
local linkHooked
local function hookLinks()
	if linkHooked then return end
	linkHooked = true
	if ChatFrameUtil and ChatFrameUtil.InsertLink then
		hooksecurefunc(ChatFrameUtil, "InsertLink", insertLink)
	elseif ChatEdit_InsertLink then
		hooksecurefunc("ChatEdit_InsertLink", insertLink)
	end
end

-- Dialog -----------------------------------------------------------------------

local function editBox(parent, label, text, width, maxLetters)
	local w = AceGUI:Create("EditBox")
	w:SetLabel(label)
	w:SetText(text)
	w:DisableButton(true)
	if maxLetters then w:SetMaxLetters(maxLetters) end
	w:SetRelativeWidth(width)
	parent:AddChild(w)
	return w
end

local function multiLine(parent, label, text, lines, maxLetters)
	local w = AceGUI:Create("MultiLineEditBox")
	w:SetLabel(label)
	w:SetText(text)
	w:SetNumLines(lines)
	w:DisableButton(true)
	if maxLetters then w:SetMaxLetters(maxLetters) end
	w:SetFullWidth(true)
	parent:AddChild(w)
	return w
end

local function button(parent, text, width, onClick)
	local w = AceGUI:Create("Button")
	w:SetText(text)
	w:SetRelativeWidth(width)
	w:SetCallback("OnClick", onClick)
	parent:AddChild(w)
	return w
end

local function dropdown(parent, label, keys, value, width, onChange)
	local list = {}
	for _, key in ipairs(keys) do list[key] = Categories.Label(key) end
	local w = AceGUI:Create("Dropdown")
	w:SetLabel(label)
	w:SetList(list, keys)
	w:SetValue(value)
	w:SetRelativeWidth(width)
	w:SetCallback("OnValueChanged", function(_, _, key) onChange(key) end)
	parent:AddChild(w)
	return w
end

-- Opens the dialog for entry `id`, or for a new entry pre-filled from `draft`.
function FS:OpenEditor(id, draft)
	local store = self:GetStore()
	if not store then return end
	local entry = id and store:Get(id)
	if id and not entry then return end
	hookLinks()
	if self.editor then self.editor:Hide() end -- OnClose releases it

	local d = draftFrom(entry or draft or {})
	d.sub = Categories.IsValid(d.cat, d.sub) and d.sub or Categories.DefaultSubtype(d.cat)

	local frame = AceGUI:Create("Frame")
	frame:SetTitle(entry and L["Edit discovery"] or L["New discovery"])
	frame:SetStatusText(L["Shift-click items to insert their links."])
	frame:SetWidth(480)
	frame:SetHeight(600)
	frame:SetLayout("Fill")
	frame:SetCallback("OnClose", function(w)
		AceGUI:Release(w)
		if self.editor == w then self.editor = nil end
	end)
	self.editor = frame

	local scroll = AceGUI:Create("ScrollFrame")
	scroll:SetLayout("Flow")
	frame:AddChild(scroll)

	local widgets, build = {}, nil

	-- Copies widget contents back into the draft.
	local function collect()
		for key, w in pairs(widgets) do d[key] = w:GetText() end
	end

	local function save()
		collect()
		local data, err = dataFrom(d)
		local saved
		if data then saved, err = self:SaveEntry(entry and entry.id, data) end
		if not saved then
			frame:SetStatusText("|cffff5555" .. (ERRORS[err] or err) .. "|r")
			return
		end
		self:Print(L["Saved: %s"]:format(saved.title))
		frame:Hide()
		if self.SelectEntry then self:SelectEntry(saved.id, false) end
	end

	function build()
		scroll:ReleaseChildren()
		wipe(widgets)
		wipe(linkTargets)
		local fields = Categories.fields[d.cat] or {}

		dropdown(scroll, L["Category"], Categories.order, d.cat, 0.5, function(cat)
			collect()
			d.cat, d.sub = cat, Categories.DefaultSubtype(cat)
			build()
		end)
		dropdown(scroll, L["Type"], Categories.subtypes[d.cat], d.sub, 0.5, function(sub)
			d.sub = sub
		end)

		widgets.title = editBox(scroll, L["Title"], d.title, 1, Store.MAX_TITLE)
		widgets.desc = multiLine(scroll, L["Description"], d.desc, 5, Store.MAX_DESC)
		linkTargets[#linkTargets + 1] = widgets.desc.editBox

		local where = AceGUI:Create("Label")
		where:SetText(L["Zone: %s"]:format(mapName(d.map)))
		where:SetFullWidth(true)
		scroll:AddChild(where)
		widgets.coords = editBox(scroll, L["Coordinates"], d.coords, 0.5)
		button(scroll, L["Use my position"], 0.5, function()
			local map, x, y = Capture.PlayerPosition()
			if not map then return end
			collect()
			d.map, d.coords = map, Format.Coords(x, y, 2)
			build()
		end)

		if fields.npcID then
			widgets.npcID = editBox(scroll, L["NPC ID"], d.npcID, 0.5)
			button(scroll, L["Use target"], 0.5, function()
				local npcID, name = Capture.Target()
				if not npcID then return end
				collect()
				d.npcID = tostring(npcID)
				if d.title == "" then d.title = name end
				build()
			end)
		end

		if fields.items then
			widgets.items = multiLine(scroll, L["Items (one per line: item link or ID = cost)"], d.items, 5)
			linkTargets[#linkTargets + 1] = widgets.items.editBox
		end

		if fields.schedule then
			widgets.respawn = editBox(scroll, L["Respawn (minutes)"], d.respawn, 0.33)
			widgets.window = editBox(scroll, L["Window"], d.window, 0.33, Store.MAX_WINDOW)
			widgets.note = editBox(scroll, L["Schedule note"], d.note, 0.34, Store.MAX_NOTE)
		end

		widgets.tags = editBox(scroll, L["Tags (comma-separated, up to 5)"], d.tags, 1)

		button(scroll, L["Save"], 0.5, save)
		button(scroll, L["Cancel"], 0.5, function() frame:Hide() end)
	end

	build()
end

-- "Scout" button on the merchant window ---------------------------------------

function FS:AddScoutButton()
	if self.scoutButton or not MerchantFrame then return end
	local b = CreateFrame("Button", nil, MerchantFrame, "UIPanelButtonTemplate")
	b:SetSize(64, 20)
	b:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -28, -1)
	b:SetText(L["Scout"])
	b:SetScript("OnClick", function() self:OnSlashCommand("add") end)
	b:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
		GameTooltip:SetText(L["Record this vendor and its stock in FrontierScout"])
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	self.scoutButton = b
end
FS:ListenEvent("MERCHANT_SHOW", function() FS:AddScoutButton() end)

-- Key binding (Bindings.xml).
function FrontierScout_AddBinding()
	FS:OnSlashCommand("add")
end
