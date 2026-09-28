local wow = require("tests.helpers.wow")

local RARE_GUID = "Creature-0-3767-0-1-3056-00002A1B2C"

-- Boots with a player at (0.5, 0.25) on map 1 and nothing targeted.
local function boot()
	local state, _, ns = wow.boot()
	local env = state.env
	env.C_Map = {
		GetBestMapForUnit = function() return 1 end,
		GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.25 end } end,
	}
	env.UnitExists = function() return false end
	env.UnitIsPlayer = function() return false end
	env.UnitName = function() return "Grizzlegut" end
	env.UnitClassification = function() return "rare" end
	return env, ns.Capture
end

local function withTarget(env, guid)
	env.UnitExists = function(unit) return unit == "target" end
	local base = env.UnitGUID
	env.UnitGUID = function(unit)
		if unit == "target" then return guid end
		return base(unit)
	end
end

local function withMerchant(env)
	env.MerchantFrame = { IsShown = function() return true end }
	env.UnitExists = function(unit) return unit == "npc" or unit == "target" end
	env.UnitGUID = function() return "Creature-0-1-0-1-777-0000000001" end
	env.UnitName = function() return "Trader Jo" end
	env.GetMerchantNumItems = function() return 3 end
	env.GetMerchantItemLink = function(i)
		if i == 3 then return nil end -- not cached yet
		return ("|cffffffff|Hitem:%d::::::::|h[Thing %d]|h|r"):format(100 + i, i)
	end
	env.C_MerchantFrame = {
		GetItemInfo = function(i)
			if i == 1 then return { price = 12345, stackCount = 1 } end
			return { price = 0, hasExtendedCost = true, stackCount = 5 }
		end,
	}
	env.GetMerchantItemCostInfo = function() return 1 end
	env.GetMerchantItemCostItem = function() return nil, 3, nil, "Honor" end
end

describe("Capture", function()
	it("reads NPC IDs from creature GUIDs only", function()
		local _, Capture = boot()
		assert.equals(3056, Capture.NpcIdFromGUID(RARE_GUID))
		assert.equals(12, Capture.NpcIdFromGUID("Vehicle-0-1-2-3-12-00AB"))
		assert.is_nil(Capture.NpcIdFromGUID("Player-1234-0ABCDEF0"))
		assert.is_nil(Capture.NpcIdFromGUID("Pet-0-1-2-3-12-00AB"))
		assert.is_nil(Capture.NpcIdFromGUID(nil))
	end)

	it("is blocked in combat and in instances", function()
		local env, Capture = boot()
		assert.is_nil(Capture.Blocked())
		env.IsInInstance = function() return true end
		assert.equals("instance", Capture.Blocked())
		env.InCombatLockdown = function() return true end
		assert.equals("combat", Capture.Blocked())
	end)

	it("reads the player position", function()
		local env, Capture = boot()
		assert.same({ 1, 0.5, 0.25 }, { Capture.PlayerPosition() })
		env.C_Map.GetPlayerMapPosition = function() return nil end
		assert.is_nil(Capture.PlayerPosition())
	end)

	it("never reads secret values", function()
		local env, Capture = boot()
		env.issecretvalue = function() return true end
		assert.is_nil(Capture.PlayerPosition())
		withTarget(env, RARE_GUID)
		assert.is_nil(Capture.Target())
	end)

	it("drafts a location from the player position", function()
		local _, Capture = boot()
		local d = Capture.Draft()
		assert.equals("location", d.cat)
		assert.same({ 1, 0.5, 0.25 }, { d.map, d.x, d.y })
	end)

	it("drafts a rare from the target", function()
		local env, Capture = boot()
		withTarget(env, RARE_GUID)
		local d = Capture.Draft()
		assert.equals("npc", d.cat)
		assert.equals("rare", d.sub)
		assert.equals(3056, d.npcID)
		assert.equals("Grizzlegut", d.title)
		env.UnitClassification = function() return "normal" end
		assert.equals("notable", Capture.Draft().sub)
	end)

	it("ignores targeted players", function()
		local env, Capture = boot()
		withTarget(env, RARE_GUID)
		env.UnitIsPlayer = function() return true end
		assert.equals("location", Capture.Draft().cat)
	end)

	it("drafts a vendor with its stock from the open merchant", function()
		local env, Capture = boot()
		withMerchant(env)
		local d = Capture.Draft()
		assert.equals("vendor", d.sub)
		assert.equals("Trader Jo", d.title)
		assert.equals(777, d.npcID)
		assert.same({ { id = 101, cost = "1g 23s 45c" }, { id = 102, cost = "3 Honor (x5)" } }, d.items)
		assert.same({ 1, 0.5, 0.25 }, { d.map, d.x, d.y })
	end)
end)
