local _, ns = ...

-- Icon per subtype (docs/SPEC.md §7.1). Blizzard atlases are used when the
-- client has them; long-standing icon files are the fallback (SPEC §12 q5).
local Icons = {}
ns.Icons = Icons

local byKey = {
	rare = { atlas = "VignetteKill", file = "Interface\\Icons\\Ability_Hunter_MarkedForDeath" },
	vendor = { file = "Interface\\GossipFrame\\VendorGossipIcon" },
	trainer = { file = "Interface\\GossipFrame\\TrainerGossipIcon" },
	notable = { file = "Interface\\GossipFrame\\GossipGossipIcon" },
	treasure = { atlas = "VignetteLoot", file = "Interface\\Icons\\INV_Box_01" },
	cave = { file = "Interface\\Icons\\INV_Misc_Map_01" },
	secret = { file = "Interface\\Icons\\INV_Misc_QuestionMark" },
	lore = { file = "Interface\\Icons\\INV_Misc_Book_09" },
	hotspot = { file = "Interface\\Icons\\INV_Misc_Map_01" },
	drop = { file = "Interface\\Icons\\INV_Misc_Bag_10" },
	["quest-item"] = { file = "Interface\\GossipFrame\\AvailableQuestIcon" },
	curiosity = { file = "Interface\\Icons\\INV_Misc_Orb_01" },
	["world-event"] = { atlas = "VignetteEvent", file = "Interface\\Icons\\INV_Misc_Horn_01" },
	["timed-spawn"] = { atlas = "VignetteEvent", file = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
}
local fallback = { file = "Interface\\Icons\\INV_Misc_QuestionMark" }

local function hasAtlas(name)
	return name and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- Sets `texture` to the icon of a subtype (or category).
function Icons.Apply(texture, sub)
	local icon = byKey[sub] or fallback
	if hasAtlas(icon.atlas) then
		texture:SetAtlas(icon.atlas)
		texture:SetTexCoord(0, 1, 0, 1)
	else
		texture:SetTexture(icon.file)
		-- Trim the border of Interface\Icons textures.
		if icon.file:find("\\Icons\\", 1, true) then
			texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		else
			texture:SetTexCoord(0, 1, 0, 1)
		end
	end
end

-- Inline "|T...|t" string for chat and font strings.
function Icons.Inline(sub, size)
	local icon = byKey[sub] or fallback
	size = size or 14
	if hasAtlas(icon.atlas) then
		return ("|A:%s:%d:%d|a"):format(icon.atlas, size, size)
	end
	return ("|T%s:%d:%d|t"):format(icon.file, size, size)
end
