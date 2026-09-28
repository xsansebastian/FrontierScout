local ADDON_NAME, ns = ...

local FS = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")
ns.FS = FS

local L = LibStub("AceLocale-3.0"):GetLocale(ADDON_NAME)

FS.SCHEMA = 1

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

function FS:Debug(fmt, ...)
	if self.db and self.db.profile.debug then
		self:Print("|cff999999[debug]|r " .. fmt:format(...))
	end
end

-- Slash commands ----------------------------------------------------------

local commands = {}
local commandOrder = { "help", "status", "version", "debug" }
local commandHelp = {
	help = L["show this help"],
	status = L["show addon, client and guild status"],
	version = L["show the addon version"],
	debug = L["toggle debug output"],
}

function commands.help(self)
	self:Print(L["Commands:"])
	for _, name in ipairs(commandOrder) do
		self:Print(("  /fs %s - %s"):format(name, commandHelp[name]))
	end
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
	local name = self:GetArgs(input, 1)
	name = name and name:lower() or "help"
	local handler = commands[name]
	if handler then
		handler(self)
	else
		self:Print(L["Unknown command: %s"]:format(name))
		commands.help(self)
	end
end
