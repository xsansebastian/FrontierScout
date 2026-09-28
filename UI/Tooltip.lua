local _, ns = ...

-- Entry tooltips for pins and rows, and FrontierScout lines on unit and item
-- tooltips (docs/SPEC.md §7.6).
local FS, L = ns.FS, ns.L
local Categories, Format, Query, Icons, Capture = ns.Categories, ns.Format, ns.Query, ns.Icons, ns.Capture

local EXCERPT = 160
local MAX_LINES = 3

local function isSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

-- Fills `tooltip` (owned by the caller) with an entry's summary.
function FS:EntryTooltip(tooltip, e)
	tooltip:SetText(Icons.Inline(e.sub, 16) .. " " .. e.title, 1, 0.82, 0)
	tooltip:AddLine(("%s · %s (%s)"):format(Categories.Label(e.sub), ns.Maps.Name(e.map) or "?", Format.Coords(e.x, e.y)), 1, 1, 1)
	if e.desc then
		local plain = Format.PlainText(e.desc):gsub("\n+", " ")
		if #plain > EXCERPT then plain = Format.Truncate(plain, EXCERPT) .. "..." end
		tooltip:AddLine(plain, 0.9, 0.9, 0.9, true)
	end
	local s = e.schedule
	if s and s.respawnMin then tooltip:AddLine(L["Respawn: %d min"]:format(s.respawnMin), 0.6, 0.8, 1) end
	if s and s.window then tooltip:AddLine(L["Window: %s"]:format(s.window), 0.6, 0.8, 1) end
	if e.items then tooltip:AddLine(L["%d items"]:format(#e.items), 0.6, 0.8, 1) end
	tooltip:AddLine(L["Added by %s"]:format(Ambiguate(e.author, "none")), 0.5, 0.5, 0.5)
	if e.approvedBy and e.approvedBy ~= e.author then
		tooltip:AddLine(L["Approved by %s"]:format(Ambiguate(e.approvedBy, "none")), 0.5, 0.5, 0.5)
	end
	tooltip:AddLine(L["Shift-click: waypoint · Right-click: menu"], 0.5, 0.5, 0.5)
	tooltip:Show()
end

-- NPC / item lookup, rebuilt lazily after changes.
local index
FS:Listen("FRONTIERSCOUT_ENTRIES_CHANGED", function() index = nil end)
FS:Listen("FRONTIERSCOUT_GUILD_CHANGED", function() index = nil end)

function FS:GetIndex()
	if not index then
		index = Query.BuildIndex(self.store and self.store:All() or {})
	end
	return index
end

local function addLines(tooltip, list, label)
	for i, e in ipairs(list) do
		if i > MAX_LINES then
			tooltip:AddLine(L["...and %d more"]:format(#list - MAX_LINES), 0.5, 0.5, 0.5)
			break
		end
		tooltip:AddLine(("|cff33ccffFrontierScout:|r %s (%s)"):format(e.title, label(e)), 1, 1, 1)
	end
end

local function onUnit(tooltip, data)
	if not FS.db.profile.tooltips or not FS.store then return end
	local guid = data and data.guid
	if not guid or isSecret(guid) then return end
	local list = FS:GetIndex().npc[Capture.NpcIdFromGUID(guid)]
	if list then addLines(tooltip, list, function(e) return Categories.Label(e.sub) end) end
end

local function onItem(tooltip, data)
	if not FS.db.profile.tooltips or not FS.store then return end
	local id = data and data.id
	if not id or isSecret(id) then return end
	local list = FS:GetIndex().item[id]
	if list then
		addLines(tooltip, list, function(e)
			if e.sub == "vendor" then return L["sold at %s"]:format(ns.Maps.Name(e.map) or "?") end
			return Categories.Label(e.sub)
		end)
	end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, onUnit)
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onItem)
end
