local _, ns = ...

-- World map and minimap pins through HereBeDragons-Pins (docs/SPEC.md §7.1-7.2).
-- Only the entries of the shown continent (world map) or the player's zone
-- (minimap) get pin frames, so a large atlas stays cheap.
local FS, L = ns.FS, ns.L
local Query, Icons = ns.Query, ns.Icons

local HBDPins = LibStub("HereBeDragons-Pins-2.0")
local REF = "FrontierScout"
local WORLD_SIZE, MINI_SIZE = 16, 12

local pins = { world = {}, mini = {} }  -- entry id -> pin frame
local free = { world = {}, mini = {} }  -- released frames
local shownKey = { world = nil, mini = nil } -- what the current pins were built for

-- Context menu --------------------------------------------------------------------

function FS:EntryMenu(owner, e)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		self:Waypoint(e)
		return
	end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(e.title)
		root:CreateButton(L["Waypoint"], function() self:Waypoint(e) end)
		root:CreateButton(L["Show in browser"], function() self:SelectEntry(e.id) end)
		if self:Can("edit", e) then
			root:CreateButton(L["Edit"], function() self:OpenEditor(e.id) end)
		end
		if self:Can("delete", e) then
			root:CreateButton(L["Delete"], function()
				StaticPopup_Show("FRONTIERSCOUT_DELETE", e.title, nil, e.id)
			end)
		end
	end)
end

-- Pin frames ----------------------------------------------------------------------

local function onEnter(pin)
	GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
	FS:EntryTooltip(GameTooltip, pin.entry)
end

local function onClick(pin, button)
	local e = pin.entry
	if button == "RightButton" then
		FS:EntryMenu(pin, e)
	elseif IsShiftKeyDown() then
		FS:Waypoint(e)
	elseif pin.kind == "world" and FS.ShowInPanel then
		FS:ShowInPanel(e.id)
	else
		FS:SelectEntry(e.id)
	end
end

local function acquire(kind)
	local pin = table.remove(free[kind])
	if pin then return pin end
	pin = CreateFrame("Button", nil, kind == "world" and WorldMapFrame or Minimap)
	pin.kind = kind
	pin.icon = pin:CreateTexture(nil, "ARTWORK")
	pin.icon:SetAllPoints()
	pin.glow = pin:CreateTexture(nil, "OVERLAY")
	pin.glow:SetPoint("CENTER")
	pin.glow:SetTexture("Interface\\Cooldown\\star4")
	pin.glow:SetBlendMode("ADD")
	pin.glow:Hide()
	pin:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	pin:SetScript("OnEnter", onEnter)
	pin:SetScript("OnLeave", GameTooltip_Hide)
	pin:SetScript("OnClick", onClick)
	return pin
end

local function clear(kind)
	if kind == "world" then
		HBDPins:RemoveAllWorldMapIcons(REF)
	else
		HBDPins:RemoveAllMinimapIcons(REF)
	end
	for id, pin in pairs(pins[kind]) do
		pin:Hide()
		pin.glow:Hide()
		pin.entry = nil
		free[kind][#free[kind] + 1] = pin
		pins[kind][id] = nil
	end
end

local function build(kind, entries, settings)
	local size = (kind == "world" and WORLD_SIZE or MINI_SIZE) * (settings.scale or 1)
	for _, e in ipairs(entries) do
		local pin = acquire(kind)
		pin.entry = e
		pin:SetSize(size, size)
		pin.glow:SetSize(size * 2.2, size * 2.2)
		Icons.Apply(pin.icon, e.sub)
		if kind == "world" then
			HBDPins:AddWorldMapIconMap(REF, pin, e.map, e.x, e.y, HBD_PINS_WORLDMAP_SHOW_CONTINENT)
		else
			HBDPins:AddMinimapIconMap(REF, pin, e.map, e.x, e.y, true, settings.edge)
		end
		pins[kind][e.id] = pin
	end
end

-- Rebuilds pins of `kind` when the map, the data or the settings changed
-- (or always, with `force`).
local function refresh(kind, map, force)
	local settings = FS.db.profile[kind == "world" and "worldmap" or "minimap"]
	local store = FS.store
	local scope = kind == "world" and "continent" or "zone"
	local area = map and (scope == "continent" and ns.Maps.Continent(map) or ns.Maps.Zone(map))
	if area == 0 then area = ns.Maps.Zone(map) end
	local key = store and settings.enabled and area and (FS.guildKey .. ":" .. area)
	if key == shownKey[kind] and not force then return end
	shownKey[kind] = key
	clear(kind)
	if key then
		build(kind, Query.PinsFor(store:All(), settings.cats, ns.Maps, map, scope), settings)
	end
end

function FS:RefreshWorldPins(force)
	if not WorldMapFrame then return end
	refresh("world", WorldMapFrame:GetMapID(), force)
end

function FS:RefreshMinimapPins(force)
	refresh("mini", C_Map.GetBestMapForUnit("player"), force)
end

function FS:RefreshPins()
	self:RefreshWorldPins(true)
	self:RefreshMinimapPins(true)
end

-- Pulses an entry's world map pin (hovering it in the side panel).
function FS:HighlightPin(id, on)
	local pin = pins.world[id]
	if pin then pin.glow:SetShown(on) end
end

-- Test hook: current pins by kind.
FS.pinFrames = pins

-- Ctrl + right-click on the world map: add a discovery at the cursor.
local function onMapMouseDown(container, button)
	if button ~= "RightButton" or not IsControlKeyDown() then return end
	if not FS:GetStore() or not FS:CheckCan("create") then return end
	local x, y = container:GetNormalizedCursorPosition()
	local map = WorldMapFrame:GetMapID()
	if not (map and x and x >= 0 and x <= 1 and y >= 0 and y <= 1) then return end
	FS:OpenEditor(nil, { cat = "location", sub = "treasure", map = map, x = x, y = y })
end

-- Wiring --------------------------------------------------------------------------

local function hookWorldMap()
	if FS.worldMapHooked or not WorldMapFrame then return end
	FS.worldMapHooked = true
	hooksecurefunc(WorldMapFrame, "OnMapChanged", function() FS:RefreshWorldPins() end)
	WorldMapFrame.ScrollContainer:HookScript("OnMouseDown", onMapMouseDown)
	if FS.OnWorldMapReady then FS:OnWorldMapReady() end
end

FS:OnEnableHook(function()
	hookWorldMap()
	FS:RefreshPins()
end)
FS:ListenEvent("ADDON_LOADED", function(name)
	if name == "Blizzard_WorldMap" then hookWorldMap() end
end)
FS:ListenEvent("ZONE_CHANGED_NEW_AREA", function() FS:RefreshMinimapPins() end)
FS:ListenEvent("PLAYER_ENTERING_WORLD", function() FS:RefreshMinimapPins() end)
FS:Listen("FRONTIERSCOUT_ENTRIES_CHANGED", function() FS:RefreshPins() end)
FS:Listen("FRONTIERSCOUT_GUILD_CHANGED", function() FS:RefreshPins() end)
FS:Listen("FRONTIERSCOUT_DISPLAY_CHANGED", function() FS:RefreshPins() end)
