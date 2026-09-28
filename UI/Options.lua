local ADDON_NAME, ns = ...

-- Options (docs/SPEC.md §7.8), shown in the game's AddOns settings and with
-- /fs config.
local FS, L = ns.FS, ns.L
local Categories, ACL = ns.Categories, ns.ACL

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

-- Guild Setup (SPEC §4.3) -----------------------------------------------------------

local ACTION_LABELS = {
	s = L["Submit new discoveries"],
	eo = L["Edit their own discoveries"],
	ea = L["Edit anyone's discoveries"],
	["do"] = L["Delete their own discoveries"],
	da = L["Delete anyone's discoveries"],
	r = L["Report outdated discoveries"],
	ar = L["Archivists: minimum rank"],
}

local draft -- thresholds being edited; starts from the guild's current ones

local function currentDraft()
	if not draft then
		draft = {}
		for k, v in pairs(FS.acl) do draft[k] = v end
	end
	return draft
end

local function rankValues()
	local values = {}
	for i, name in pairs(FS.rankNames) do values[i] = L["%s and above"]:format(name) end
	values[9] = L["Everyone"]
	return values
end

-- Writes the draft thresholds into Guild Info. Returns true or false, reason.
function FS:WriteGuildSetup(t)
	if not CanEditGuildInfo() then return false, "denied" end
	local text, err = ACL.Apply(GetGuildInfoText(), t)
	if not text then
		self:Print(L["Guild Info is too long to add the FrontierScout tag. Shorten it and try again."])
		return false, err
	end
	SetGuildInfoText(text)
	self.acl, self.aclConfigured = ACL.Parse(text)
	self:Print(L["Guild permissions saved to Guild Info."])
	self:SendMessage("FRONTIERSCOUT_ROSTER_UPDATED")
	self:RequestRoster()
	return true
end

local function guildSetup()
	local args = {
		intro = {
			type = "description",
			order = 0,
			fontSize = "medium",
			name = function()
				if not FS.store then return L["Join a guild to use FrontierScout."] end
				local state = FS.aclConfigured and L["Current settings come from the guild's Guild Info."]
					or L["This guild has no FrontierScout settings yet, so only the Guild Master can write."]
				return state .. "\n" .. L["Everyone can see all discoveries. Choose the lowest rank allowed to do each action."]
			end,
		},
	}
	for i, key in ipairs(ACL.KEYS) do
		args[key] = {
			type = "select",
			order = i,
			width = "double",
			name = ACTION_LABELS[key],
			values = rankValues,
			get = function() return currentDraft()[key] end,
			set = function(_, v) currentDraft()[key] = v end,
			disabled = function() return not FS.store end,
		}
	end
	args.preview = {
		type = "description",
		order = 20,
		name = function() return L["Guild Info tag: %s"]:format(ACL.Format(currentDraft())) end,
	}
	args.write = {
		type = "execute",
		order = 21,
		width = "double",
		name = L["Write to Guild Info"],
		desc = L["Adds or updates the tag in Guild Info and leaves the rest of the text as it is."],
		disabled = function() return not (FS.store and CanEditGuildInfo()) end,
		func = function() FS:WriteGuildSetup(currentDraft()) end,
	}
	args.reset = {
		type = "execute",
		order = 22,
		name = L["Undo changes"],
		func = function() draft = nil end,
	}
	args.archivists = {
		type = "description",
		order = 30,
		fontSize = "medium",
		name = function()
			local help = L["Archivists approve discoveries and share them with the guild. To make someone an archivist, add {FS:A} to their officer note (Guild & Communities > Roster). Their rank must also meet the archivist rank above."]
			local names = FS:ListArchivists()
			for i, name in ipairs(names) do
				names[i] = (FS.roster[name].online and "|cff33ff33%s|r" or "%s"):format(Ambiguate(name, "guild"))
			end
			local list = #names > 0 and table.concat(names, ", ") or L["none yet"]
			return help .. "\n\n" .. L["Archivists: %s"]:format(list)
		end,
	}
	return { type = "group", order = 4, name = L["Guild Setup"], args = args }
end

FS:Listen("FRONTIERSCOUT_GUILD_CHANGED", function() draft = nil end)

-- Data (SPEC §7.8) ------------------------------------------------------------------

-- Removes the stored data of every guild except the current one.
function FS:PurgeOtherGuilds()
	local removed = 0
	for key in pairs(self.db.global.guilds) do
		if key ~= self.guildKey then
			self.db.global.guilds[key] = nil
			removed = removed + 1
		end
	end
	self:Print(L["Removed data of %d other guild(s)."]:format(removed))
	return removed
end

-- Drops this guild's discoveries (keeping your submissions) and syncs again.
function FS:ResetGuildData()
	if not self.store then return end
	local bucket = self.store.bucket
	bucket.entries, bucket.syncState, bucket.queue, bucket.decided = {}, {}, {}, {}
	self.store = ns.Store.New(bucket)
	self:SendMessage("FRONTIERSCOUT_ENTRIES_CHANGED")
	self:SendMessage("FRONTIERSCOUT_QUEUE_CHANGED")
	self:Print(L["Local data cleared. Syncing again..."])
	self:SayHello(true)
end

local function otherGuilds()
	local names = {}
	for key, bucket in pairs(FS.db.global.guilds) do
		if key ~= FS.guildKey then names[#names + 1] = (bucket.meta and bucket.meta.name) or key end
	end
	table.sort(names)
	return names
end

function FS:GetOptionsTable()
	local edgeGet, edgeSet = setting("minimap", "edge")
	local chatGet, chatSet = setting("notify", "chat")
	local toastGet, toastSet = setting("notify", "toast")
	return {
		type = "group",
		name = "FrontierScout",
		args = {
			worldmap = pinGroup("worldmap", L["World map"], 1),
			minimap = pinGroup("minimap", L["Minimap"], 2, {
				edge = { type = "toggle", order = 4, name = L["Keep distant pins on the minimap edge"], get = edgeGet, set = edgeSet },
			}),
			notify = {
				type = "group",
				inline = true,
				order = 3.5,
				name = L["Notifications"],
				args = {
					chat = { type = "toggle", order = 1, width = "full", name = L["Chat message when discoveries arrive in my zone"], get = chatGet, set = chatSet },
					toast = { type = "toggle", order = 2, width = "full", name = L["On-screen message when discoveries arrive in my zone"], get = toastGet, set = toastSet },
				},
			},
			data = {
				type = "group",
				order = 5,
				name = L["Data"],
				args = {
					others = {
						type = "description",
						order = 1,
						name = function()
							local names = otherGuilds()
							return L["Other guilds with stored data: %s"]:format(#names > 0 and table.concat(names, ", ") or L["none"])
						end,
					},
					purge = {
						type = "execute",
						order = 2,
						width = "double",
						name = L["Delete data of other guilds"],
						confirm = true,
						confirmText = L["Delete the discoveries stored for guilds you are not in?"],
						disabled = function() return #otherGuilds() == 0 end,
						func = function() FS:PurgeOtherGuilds() end,
					},
					reset = {
						type = "execute",
						order = 3,
						width = "double",
						name = L["Reset this guild's data and sync again"],
						confirm = true,
						confirmText = L["Clear this guild's local discoveries and download them again from an archivist? Your submissions are kept."],
						desc = L["Archivists can only reset while another archivist is online, so the guild's data isn't lost."],
						disabled = function() return not FS.store or (FS:AmArchivist() and #FS:OnlineArchivists() == 0) end,
						func = function() FS:ResetGuildData() end,
					},
				},
			},
			guild = guildSetup(),
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
