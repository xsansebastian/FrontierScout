local ADDON_NAME, ns = ...

local FS = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")
ns.FS = FS

local L = LibStub("AceLocale-3.0"):GetLocale(ADDON_NAME)
ns.L = L

FS.SCHEMA = 1

-- Key binding labels (Bindings.xml).
BINDING_HEADER_FRONTIERSCOUT = "FrontierScout"
BINDING_NAME_FRONTIERSCOUT_BROWSER = L["Open or close the discoveries browser"]
BINDING_NAME_FRONTIERSCOUT_ADD = L["Record a discovery here"]

-- Layout of the saved data is described in docs/SPEC.md §3.2.
local defaults = {
	global = {
		schema = FS.SCHEMA,
		sessions = 0,
		guilds = {},
	},
	profile = {
		debug = false,
		waypointMode = "auto", -- "auto" | "native" | "tomtom"
		worldmap = { enabled = true, scale = 1, cats = { npc = true, location = true, item = true, event = true } },
		minimap = { enabled = true, scale = 1, edge = false, cats = { npc = true, location = true, item = true, event = true } },
		panel = { shown = true },
		tooltips = true,
	},
}

function FS:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("FrontierScoutDB", defaults, true)

	local global = self.db.global
	global.sessions = global.sessions + 1
	global.firstSeen = global.firstSeen or GetServerTime()

	local version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
	if not version or version:find("@project", 1, true) then
		version = "dev"
	end
	self.version = version

	self:RegisterChatCommand("fs", "OnSlashCommand")
	self:RegisterChatCommand("frontierscout", "OnSlashCommand")
end

function FS:OnEnable()
	self:ListenEvent("PLAYER_ENTERING_WORLD", function() self:RefreshGuild() end)
	self:ListenEvent("PLAYER_GUILD_UPDATE", function() self:RefreshGuild() end)
	self:ListenEvent("GUILD_ROSTER_UPDATE", function() self:RefreshGuild() end)
	for _, fn in ipairs(self.enableHooks or {}) do fn() end
	self:RefreshGuild()
end

-- Runs `fn` from OnEnable (for modules loaded before the addon is enabled).
function FS:OnEnableHook(fn)
	self.enableHooks = self.enableHooks or {}
	self.enableHooks[#self.enableHooks + 1] = fn
end

-- AceEvent keeps one handler per event or message and object; these let any
-- number of modules listen. Handlers get the event/message arguments.
local listeners = { event = {}, message = {} }

local function listen(self, kind, name, fn)
	local list = listeners[kind][name]
	if not list then
		list = {}
		listeners[kind][name] = list
		local dispatch = function(_, ...)
			for _, f in ipairs(list) do f(...) end
		end
		if kind == "event" then
			self:RegisterEvent(name, dispatch)
		else
			self:RegisterMessage(name, dispatch)
		end
	end
	list[#list + 1] = fn
end

function FS:ListenEvent(event, fn) listen(self, "event", event, fn) end
function FS:Listen(message, fn) listen(self, "message", message, fn) end

-- Addon compartment (minimap addons menu), see AddonCompartmentFunc in the TOC.
function FrontierScout_OnAddonCompartmentClick()
	FS:OnSlashCommand("")
end

function FS:Debug(fmt, ...)
	if self.db and self.db.profile.debug then
		self:Print("|cff999999[debug]|r " .. fmt:format(...))
	end
end

-- Slash commands ----------------------------------------------------------

local commands = {}
local commandOrder = { "help", "add", "waypoints", "config", "status", "version", "debug" }
local commandHelp = {
	help = L["show this help"],
	add = L["record a discovery here (optional: title)"],
	waypoints = L["waypoint mode: auto, native or tomtom"],
	config = L["open the options"],
	status = L["show addon, client and guild status"],
	version = L["show the addon version"],
	debug = L["toggle debug output"],
}

function commands.help(self)
	self:Print(L["Commands:"])
	self:Print("  /fs - " .. L["open the discoveries browser"])
	for _, name in ipairs(commandOrder) do
		self:Print(("  /fs %s - %s"):format(name, commandHelp[name]))
	end
end

-- Opens the browser; the UI files define OpenBrowser.
function commands.browse(self)
	if self:GetStore() and self.OpenBrowser then self:OpenBrowser() end
end

function commands.add(self, args)
	local blocked = ns.Capture.Blocked()
	if blocked == "combat" then
		self:Print(L["Not available in combat."])
		return
	elseif blocked == "instance" then
		self:Print(L["FrontierScout records open-world discoveries only."])
		return
	end
	if not self:GetStore() or not self:CheckCan("create") then return end
	local draft = ns.Capture.Draft()
	if args ~= "" then draft.title = args end
	if self.OpenEditor then self:OpenEditor(nil, draft) end
end

function commands.waypoints(self, args)
	local mode = args:lower()
	if self.WAYPOINT_MODES[mode] then
		self.db.profile.waypointMode = mode
	elseif mode ~= "" then
		self:Print(L["Unknown waypoint mode: %s"]:format(mode))
	end
	self:Print(L["Waypoint mode: %s"]:format(self.db.profile.waypointMode))
end

function commands.config(self)
	if self.OpenOptions then self:OpenOptions() end
end

function commands.version(self)
	self:Print(L["Version: %s"]:format(self.version))
end

function commands.status(self)
	local clientVersion, build, _, interface = GetBuildInfo()
	commands.version(self)
	self:Print(L["Client: %s (build %s, interface %d)"]:format(clientVersion, build, interface))
	if IsInGuild() then
		self:Print(L["Guild: %s"]:format(GetGuildInfo("player") or "?"))
	else
		self:Print(L["Guild: none"])
	end
	if self.store then
		self:Print(L["Discoveries in this guild: %d"]:format(self.store:Count()))
		local rank = self:MyRank()
		self:Print(L["Your rank: %s (%d), archivist: %s"]:format(self.rankNames[rank] or "?", rank or -1,
			self:AmArchivist() and L["yes"] or L["no"]))
		if not self.aclConfigured then self:Print(L["Guild permissions: not set up (only the Guild Master can write)."]) end
	end
	local global = self.db.global
	self:Print(L["Saved data: session %d, first seen %s"]:format(global.sessions, date("%Y-%m-%d", global.firstSeen)))
	self:Print(L["Debug output: %s"]:format(self.db.profile.debug and L["on"] or L["off"]))
end

function commands.debug(self)
	local profile = self.db.profile
	profile.debug = not profile.debug
	self:Print(L["Debug output: %s"]:format(profile.debug and L["on"] or L["off"]))
end

function FS:OnSlashCommand(input)
	local name, args = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	name = name ~= "" and name:lower() or "browse"
	local handler = commands[name]
	if handler then
		handler(self, args)
	else
		self:Print(L["Unknown command: %s"]:format(name))
		commands.help(self)
	end
end
