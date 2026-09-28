local _, ns = ...

-- Waypoints through TomTom or Blizzard's user waypoint (docs/SPEC.md §8).
local FS = ns.FS

local HBD = LibStub("HereBeDragons-2.0")

local function hasTomTom()
	return TomTom ~= nil and type(TomTom.AddWaypoint) == "function"
end

-- Sets the native user waypoint, climbing to parent maps when the entry's own
-- map doesn't allow one (e.g. some micro maps).
local function setNative(map, x, y)
	for _ = 1, 10 do
		if C_Map.CanSetUserWaypointOnMap(map) then
			C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(map, x, y))
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
			return true
		end
		local info = C_Map.GetMapInfo(map)
		local parent = info and info.parentMapID
		if not parent or parent == 0 then return false end
		local px, py = HBD:TranslateZoneCoordinates(x, y, map, parent)
		if not px then return false end
		map, x, y = parent, px, py
	end
	return false
end

-- Returns true and "tomtom" | "native", or false and "notomtom" | "nomap".
function FS:SetWaypoint(entry)
	local mode = self.db.profile.waypointMode
	if mode == "tomtom" or (mode == "auto" and hasTomTom()) then
		if not hasTomTom() then return false, "notomtom" end
		TomTom:AddWaypoint(entry.map, entry.x, entry.y, {
			title = entry.title,
			from = "FrontierScout",
			persistent = false,
			minimap = true,
			world = true,
		})
		return true, "tomtom"
	end
	if setNative(entry.map, entry.x, entry.y) then return true, "native" end
	return false, "nomap"
end

-- SetWaypoint plus chat feedback.
function FS:Waypoint(entry)
	local L = ns.L
	local ok, how = self:SetWaypoint(entry)
	if ok then
		self:Print(L["Waypoint set: %s"]:format(entry.title))
	elseif how == "notomtom" then
		self:Print(L["TomTom is not loaded. Use /fs waypoints auto or native."])
	else
		self:Print(L["This map does not allow waypoints."])
	end
	return ok
end

FS.WAYPOINT_MODES = { auto = true, native = true, tomtom = true }
