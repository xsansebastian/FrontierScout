local _, ns = ...

-- Pre-fills discoveries from the game: player position, target NPC and the
-- open merchant (docs/SPEC.md §5.2, §5.5). Open world only, never in combat,
-- and never reads a secret value.
local Format, Store = ns.Format, ns.Store

local Capture = {}
ns.Capture = Capture

local function isSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

-- Creature-0-<server>-<instance>-<zoneUID>-<npcID>-<spawnUID>
function Capture.NpcIdFromGUID(guid)
	if type(guid) ~= "string" then return nil end
	local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-%x+$")
	if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

-- nil when capture is allowed, otherwise a reason code: "combat", "instance".
function Capture.Blocked()
	if InCombatLockdown() then return "combat" end
	if IsInInstance() then return "instance" end
end

-- uiMapID, x, y of the player, or nil.
function Capture.PlayerPosition()
	local map = C_Map.GetBestMapForUnit("player")
	if not map or isSecret(map) then return nil end
	local pos = C_Map.GetPlayerMapPosition(map, "player")
	if not pos then return nil end
	local x, y = pos:GetXY()
	if not x or isSecret(x) or isSecret(y) then return nil end
	return map, x, y
end

local function npcUnit(unit)
	if not UnitExists(unit) or UnitIsPlayer(unit) then return nil end
	local guid, name = UnitGUID(unit), UnitName(unit)
	if isSecret(guid) or isSecret(name) then return nil end
	local npcID = Capture.NpcIdFromGUID(guid)
	if npcID then return npcID, name end
end

-- npcID, name of the targeted NPC, or nil.
function Capture.Target()
	return npcUnit("target")
end

local function itemPrice(i)
	if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
		local info = C_MerchantFrame.GetItemInfo(i)
		if info then return info.price, info.hasExtendedCost, info.stackCount end
	elseif GetMerchantItemInfo then
		local _, _, price, quantity, _, _, _, extendedCost = GetMerchantItemInfo(i)
		return price, extendedCost, quantity
	end
end

-- Human-readable cost of merchant slot i: "1g 20s", "5 Honor", "2 [Linen Cloth]", ...
function Capture.MerchantCost(i)
	local price, extended, stack = itemPrice(i)
	local parts = {}
	if price and price > 0 then parts[1] = Format.Money(price) end
	if extended and GetMerchantItemCostInfo then
		for j = 1, GetMerchantItemCostInfo(i) or 0 do
			local _, value, link, currency = GetMerchantItemCostItem(i, j)
			local what = currency or (link and link:match("%[(.-)%]"))
			if value and what then parts[#parts + 1] = value .. " " .. what end
		end
	end
	local cost = table.concat(parts, ", ")
	if cost ~= "" and stack and stack > 1 then cost = cost .. " (x" .. stack .. ")" end
	return cost ~= "" and Format.Truncate(cost, Store.MAX_COST) or nil
end

-- { npcID, name, items = { {id, cost}, ... } } for the open merchant, or nil.
function Capture.Merchant()
	if not (MerchantFrame and MerchantFrame:IsShown()) then return nil end
	local npcID, name = npcUnit("npc")
	local items = {}
	for i = 1, math.min(GetMerchantNumItems() or 0, Store.MAX_ITEMS) do
		local id = Format.ItemIdFromLink(GetMerchantItemLink(i))
		if id then items[#items + 1] = { id = id, cost = Capture.MerchantCost(i) } end
	end
	return { npcID = npcID, name = name, items = items }
end

-- A draft entry for the edit dialog, from whatever context is available:
-- open merchant > targeted NPC > player position.
function Capture.Draft()
	local draft = { cat = "location", sub = "treasure" }
	local map, x, y = Capture.PlayerPosition()
	draft.map, draft.x, draft.y = map, x, y

	local merchant = Capture.Merchant()
	if merchant then
		draft.cat, draft.sub = "npc", "vendor"
		draft.title, draft.npcID, draft.items = merchant.name, merchant.npcID, merchant.items
		return draft
	end

	local npcID, name = Capture.Target()
	if npcID then
		local class = UnitClassification("target")
		local rare = not isSecret(class) and (class == "rare" or class == "rareelite")
		draft.cat, draft.sub = "npc", rare and "rare" or "notable"
		draft.title, draft.npcID = name, npcID
	end
	return draft
end
