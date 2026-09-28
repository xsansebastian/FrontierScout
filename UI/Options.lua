local ADDON_NAME, ns = ...

-- Options (docs/SPEC.md §7.8), shown in the game's AddOns settings and with
-- /fs config. Guild Setup arrives with the ACL (M3).
local FS, L = ns.FS, ns.L
local Categories = ns.Categories

local function catValues()
	local values = {}
	for _, cat in ipairs(Categories.order) do values[cat] = Categories.Label(cat) end
	return values
end

local function changed()
	FS:SendMessage("FRONTIERSCOUT_DISPLAY_CHANGED")
end

-- Getter/setter pair for profile[section][key].
local function setting(section, key)
	return function() return FS.db.profile[section][key] end,
		function(_, value)
			FS.db.profile[section][key] = value
			changed()
		end
end

local function cats(section)
	return function(_, cat) return FS.db.profile[section].cats[cat] end,
		function(_, cat, on)
			FS.db.profile[section].cats[cat] = on
			changed()
		end
end

local function pinGroup(section, name, order, extra)
	local get, set = setting(section, "enabled")
	local scaleGet, scaleSet = setting(section, "scale")
	local catGet, catSet = cats(section)
	local args = {
		enabled = { type = "toggle", order = 1, name = L["Show pins"], get = get, set = set },
		scale = { type = "range", order = 2, name = L["Icon size"], min = 0.5, max = 2, step = 0.1, get = scaleGet, set = scaleSet },
		cats = { type = "multiselect", order = 3, name = L["Categories"], values = catValues, get = catGet, set = catSet },
	}
	for k, v in pairs(extra or {}) do args[k] = v end
	return { type = "group", inline = true, order = order, name = name, args = args }
end

function FS:GetOptionsTable()
	local edgeGet, edgeSet = setting("minimap", "edge")
	return {
		type = "group",
		name = "FrontierScout",
		args = {
			worldmap = pinGroup("worldmap", L["World map"], 1),
			minimap = pinGroup("minimap", L["Minimap"], 2, {
				edge = { type = "toggle", order = 4, name = L["Keep distant pins on the minimap edge"], get = edgeGet, set = edgeSet },
			}),
			general = {
				type = "group",
				inline = true,
				order = 3,
				name = L["General"],
				args = {
					tooltips = {
						type = "toggle",
						order = 1,
						name = L["Show discoveries in NPC and item tooltips"],
						width = "full",
						get = function() return FS.db.profile.tooltips end,
						set = function(_, v) FS.db.profile.tooltips = v end,
					},
					waypointMode = {
						type = "select",
						order = 2,
						name = L["Waypoints"],
						values = {
							auto = L["TomTom if installed, else the map pin"],
							native = L["Map pin only"],
							tomtom = L["TomTom only"],
						},
						get = function() return FS.db.profile.waypointMode end,
						set = function(_, v) FS.db.profile.waypointMode = v end,
					},
				},
			},
		},
	}
end

function FS:OpenOptions()
	LibStub("AceConfigDialog-3.0"):Open(ADDON_NAME)
end

FS:OnEnableHook(function()
	LibStub("AceConfig-3.0"):RegisterOptionsTable(ADDON_NAME, function() return FS:GetOptionsTable() end)
	LibStub("AceConfigDialog-3.0"):AddToBlizOptions(ADDON_NAME, "FrontierScout")
end)
