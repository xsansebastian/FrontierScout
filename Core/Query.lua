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

	-- True when `map` is `root` or lies inside it (e.g. a zone inside a continent).
	function r.IsWithin(map, root)
		local seen, cur = 0, map
		while cur and cur > 0 and seen < 20 do
			if cur == root then return true end
			local info = getMapInfo(cur)
			cur, seen = info and info.parentMapID, seen + 1
		end
		return false
	end

	function r.Type(map)
		local info = map and map > 0 and getMapInfo(map) or nil
		return info and info.mapType or nil
	end

	function r.Name(map)
		local info = map and map > 0 and getMapInfo(map) or nil
		return info and info.name or nil
	end

	return r
end

-- Lower-cased search text per entry. Entries are replaced, never mutated, on
-- change, so the cache (weak keys) stays valid.
local hayCache = setmetatable({}, { __mode = "k" })

local function haystack(e)
	local cached = hayCache[e]
	if cached then return cached end
	local parts = { e.title, Format.PlainText(e.desc), e.npcID and tostring(e.npcID) or "" }
	for _, tag in ipairs(e.tags or {}) do parts[#parts + 1] = tag end
	for _, item in ipairs(e.items or {}) do parts[#parts + 1] = tostring(item.id) end
	cached = table.concat(parts, "\n"):lower()
	hayCache[e] = cached
	return cached
end

-- filter = { text = "search", cats = { npc = true, ... } (nil = all), zone = mapID (nil = all),
--            newSince = serverTime (nil = all) }
function Query.Matches(e, filter, resolver)
	if filter.cats and not filter.cats[e.cat] then return false end
	if filter.newSince and (e.approvedAt or 0) <= filter.newSince then return false end
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

-- Entries to pin while `map` is shown, in enabled categories (`cats`).
-- scope "continent": everything on the same continent (the world map shows
-- pins on their map and its parents); scope "zone": the same zone only
-- (the minimap). Maps without a continent fall back to the zone.
function Query.PinsFor(entries, cats, resolver, map, scope)
	local list = {}
	if not map then return list end
	local zone = resolver.Zone(map)
	local continent = scope == "continent" and resolver.Continent(map) or 0
	for _, e in ipairs(entries) do
		if cats[e.cat] then
			local ok
			if continent ~= 0 then
				ok = resolver.Continent(e.map) == continent
			else
				ok = resolver.Zone(e.map) == zone
			end
			if ok then list[#list + 1] = e end
		end
	end
	return list
end

-- Entries on `map` or inside it, sorted by category order then title.
function Query.Within(entries, resolver, map, text, catOrder)
	local rank = {}
	for i, cat in ipairs(catOrder) do rank[cat] = i end
	local list = {}
	for _, e in ipairs(entries) do
		if rank[e.cat] and resolver.IsWithin(e.map, map) and Query.Matches(e, { text = text }, resolver) then
			list[#list + 1] = e
		end
	end
	table.sort(list, function(a, b)
		if a.cat ~= b.cat then return rank[a.cat] < rank[b.cat] end
		return byTitle(a, b)
	end)
	return list
end

-- Lookup tables for tooltips: npc[npcID] and item[itemID] -> list of entries.
-- Items index notable-item entries and vendors that sell the item.
function Query.BuildIndex(entries)
	local index = { npc = {}, item = {} }
	local function add(t, key, e)
		local list = t[key]
		if not list then
			list = {}
			t[key] = list
		end
		list[#list + 1] = e
	end
	for _, e in ipairs(entries) do
		if e.npcID then add(index.npc, e.npcID, e) end
		if e.cat == "item" or e.sub == "vendor" then
			for _, item in ipairs(e.items or {}) do add(index.item, item.id, e) end
		end
	end
	for _, t in pairs(index) do
		for _, list in pairs(t) do table.sort(list, byTitle) end
	end
	return index
end

-- Shared resolver over the game's map data.
ns.Maps = Query.NewMapResolver(function(map) return C_Map.GetMapInfo(map) end)
