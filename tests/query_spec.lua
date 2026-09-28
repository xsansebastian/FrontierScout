local wow = require("tests.helpers.wow")

local Query
setup(function()
	local _, _, ns = wow.boot()
	Query = ns.Query
end)

-- Continent 12 > zones 1 (Durotar) and 7 (Mulgore); micro map 100 (a cave in
-- Durotar); zone 50 has no continent.
local MAPS = {
	[947] = { name = "Azeroth", mapType = 1, parentMapID = 0 },
	[12] = { name = "Kalimdor", mapType = 2, parentMapID = 947 },
	[1] = { name = "Durotar", mapType = 3, parentMapID = 12 },
	[7] = { name = "Mulgore", mapType = 3, parentMapID = 12 },
	[100] = { name = "Dustwind Cave", mapType = 5, parentMapID = 1 },
	[50] = { name = "Somewhere", mapType = 3, parentMapID = 0 },
}

local function resolver()
	return Query.NewMapResolver(function(map) return MAPS[map] end)
end

local function entry(id, title, map, extra)
	local e = { id = id, title = title, map = map, cat = "location", sub = "treasure" }
	for k, v in pairs(extra or {}) do e[k] = v end
	return e
end

describe("Query map resolver", function()
	it("groups micro maps under their zone and finds continents", function()
		local r = resolver()
		assert.equals(1, r.Zone(100))
		assert.equals(1, r.Zone(1))
		assert.equals(12, r.Continent(100))
		assert.equals(0, r.Continent(50))
		assert.equals(999, r.Zone(999)) -- unknown map
		assert.equals("Durotar", r.Name(1))
		assert.is_nil(r.Name(0))
	end)
end)

describe("Query.Matches / Filter", function()
	local r = resolver()
	local entries = {
		entry("a", "Zeta chest", 1),
		entry("b", "alpha rare", 7, { cat = "npc", sub = "rare", npcID = 3056, tags = { "elite" } }),
		entry("c", "Cave loot", 100, { desc = "Behind the |cffff0000waterfall|r", items = { { id = 19019 } } }),
	}

	it("searches title, description, tags, npc and item IDs, ignoring case", function()
		local function ids(text)
			local out = {}
			for _, e in ipairs(Query.Filter(entries, { text = text }, r)) do out[#out + 1] = e.id end
			return out
		end
		assert.same({ "b" }, ids("ALPHA"))
		assert.same({ "c" }, ids("waterfall"))
		assert.same({ "b" }, ids("elite"))
		assert.same({ "b" }, ids("3056"))
		assert.same({ "c" }, ids("19019"))
		assert.same({ "b", "c", "a" }, ids("  "))
	end)

	it("filters by category and zone (including micro maps)", function()
		assert.same({ entries[2] }, Query.Filter(entries, { cats = { npc = true } }, r))
		assert.same({ entries[3], entries[1] }, Query.Filter(entries, { zone = 1 }, r))
	end)
end)

describe("Query.ZoneTree", function()
	it("lists continents with their zones and counts", function()
		local r = resolver()
		local rows = Query.ZoneTree({
			entry("a", "A", 1), entry("b", "B", 100), entry("c", "C", 7), entry("d", "D", 50),
		}, r, "Other")
		local flat = {}
		for _, row in ipairs(rows) do
			flat[#flat + 1] = ("%s:%s:%d"):format(row.kind, row.name, row.count)
		end
		assert.same({
			"continent:Kalimdor:3",
			"zone:Durotar:2",
			"zone:Mulgore:1",
			"continent:Other:1",
			"zone:Somewhere:1",
		}, flat)
	end)

	it("is empty without entries", function()
		assert.same({}, Query.ZoneTree({}, resolver(), "Other"))
	end)
end)
