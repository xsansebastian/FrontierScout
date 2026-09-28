local _, ns = ...

-- Searching, filtering and zone grouping for the browser. Pure Lua: map data
-- comes from an injected getMapInfo(mapID) -> { name, mapType, parentMapID }.
local Format = ns.Format

local Query = {}
ns.Query = Query

-- Enum.UIMapType values.
local CONTINENT, ZONE = 2, 3

-- Wraps getMapInfo with caches and parent walks.
function Query.NewMapResolver(getMapInfo)
	local zoneCache, continentCache = {}, {}
	local r = {}

	local function ancestor(map, mapType, fallback)
		local seen, cur = 0, map
		while cur and cur > 0 and seen < 20 do
			local info = getMapInfo(cur)
			if not info then break end
			if info.mapType == mapType then return cur end
			cur, seen = info.parentMapID, seen + 1
		end
		return fallback
	end

	-- The nearest Zone-type map at or above `map`, so caves and micro maps
	-- group under their zone. Falls back to the map itself.
	function r.Zone(map)
		local z = zoneCache[map]
		if not z then
			z = ancestor(map, ZONE, map)
			zoneCache[map] = z
		end
		return z
	end

	-- The Continent-type map above `map`, or 0 when there is none.
	function r.Continent(map)
		local c = continentCache[map]
		if not c then
			c = ancestor(map, CONTINENT, 0)
			continentCache[map] = c
		end
		return c
	end

	function r.Name(map)
		local info = map and map > 0 and getMapInfo(map) or nil
		return info and info.name or nil
	end

	return r
end

local function haystack(e)
	local parts = { e.title, Format.PlainText(e.desc), e.npcID and tostring(e.npcID) or "" }
	for _, tag in ipairs(e.tags or {}) do parts[#parts + 1] = tag end
	for _, item in ipairs(e.items or {}) do parts[#parts + 1] = tostring(item.id) end
	return table.concat(parts, "\n"):lower()
end

-- filter = { text = "search", cats = { npc = true, ... } (nil = all), zone = mapID (nil = all) }
function Query.Matches(e, filter, resolver)
	if filter.cats and not filter.cats[e.cat] then return false end
	if filter.zone and resolver.Zone(e.map) ~= filter.zone then return false end
	local text = filter.text and Format.Trim(filter.text) or ""
	if text ~= "" and not haystack(e):find(text:lower(), 1, true) then return false end
	return true
end

local function byTitle(a, b)
	local ta, tb = a.title:lower(), b.title:lower()
	if ta ~= tb then return ta < tb end
	return a.id < b.id
end

-- Matching entries sorted by title.
function Query.Filter(entries, filter, resolver)
	local list = {}
	for _, e in ipairs(entries) do
		if Query.Matches(e, filter, resolver) then list[#list + 1] = e end
	end
	table.sort(list, byTitle)
	return list
end

local function byName(a, b)
	if a.name ~= b.name then return a.name < b.name end
	return a.map < b.map
end

-- Continent -> zone rows with entry counts, sorted by name. Continent 0 holds
-- zones without a continent and is listed last, named `otherName`.
-- Rows: { kind = "continent" | "zone", map = , name = , count = }
function Query.ZoneTree(entries, resolver, otherName)
	local continents, byMap = {}, {}
	for _, e in ipairs(entries) do
		local zone = resolver.Zone(e.map)
		local node = byMap[zone]
		if not node then
			local cid = resolver.Continent(zone)
			local cont = continents[cid]
			if not cont then
				cont = { kind = "continent", map = cid, name = cid == 0 and otherName or resolver.Name(cid) or ("#" .. cid), count = 0, zones = {} }
				continents[cid] = cont
			end
			node = { kind = "zone", map = zone, name = resolver.Name(zone) or ("#" .. zone), count = 0, continent = cid }
			byMap[zone] = node
			cont.zones[#cont.zones + 1] = node
		end
		node.count = node.count + 1
		local cont = continents[node.continent]
		cont.count = cont.count + 1
	end

	local sorted = {}
	for cid, cont in pairs(continents) do
		if cid ~= 0 then sorted[#sorted + 1] = cont end
	end
	table.sort(sorted, byName)
	sorted[#sorted + 1] = continents[0]

	local rows = {}
	for _, cont in ipairs(sorted) do
		table.sort(cont.zones, byName)
		rows[#rows + 1] = cont
		for _, zone in ipairs(cont.zones) do rows[#rows + 1] = zone end
		cont.zones = nil
	end
	return rows
end
