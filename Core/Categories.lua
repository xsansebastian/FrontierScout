local ADDON_NAME, ns = ...

-- Discovery categories and subtypes (docs/SPEC.md §5.2). Pure data, no WoW API.
local L = LibStub("AceLocale-3.0"):GetLocale(ADDON_NAME)

local Categories = {}
ns.Categories = Categories

Categories.order = { "npc", "location", "item", "event" }

Categories.subtypes = {
	npc = { "rare", "vendor", "trainer", "notable" },
	location = { "treasure", "cave", "secret", "lore", "hotspot" },
	item = { "drop", "quest-item", "curiosity" },
	event = { "world-event", "timed-spawn" },
}

local labels = {
	npc = L["NPC"],
	location = L["Location"],
	item = L["Item"],
	event = L["Event"],
	rare = L["Rare"],
	vendor = L["Vendor"],
	trainer = L["Trainer"],
	notable = L["Notable NPC"],
	treasure = L["Treasure"],
	cave = L["Cave"],
	secret = L["Secret"],
	lore = L["Lore"],
	hotspot = L["Hotspot"],
	drop = L["Drop"],
	["quest-item"] = L["Quest item"],
	curiosity = L["Curiosity"],
	["world-event"] = L["World event"],
	["timed-spawn"] = L["Timed spawn"],
}

function Categories.Label(key)
	return labels[key] or key
end

function Categories.IsValid(cat, sub)
	local subs = Categories.subtypes[cat]
	if not subs then return false end
	for _, s in ipairs(subs) do
		if s == sub then return true end
	end
	return false
end

function Categories.DefaultSubtype(cat)
	local subs = Categories.subtypes[cat]
	return subs and subs[1]
end

-- Which optional fields the edit dialog shows for a category.
Categories.fields = {
	npc = { npcID = true, items = true, schedule = true },
	location = {},
	item = { items = true },
	event = { schedule = true },
}
