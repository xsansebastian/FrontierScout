local ADDON_NAME = ...

local L = LibStub("AceLocale-3.0"):NewLocale(ADDON_NAME, "enUS", true)
if not L then return end

-- Slash commands
L["Commands:"] = true
L["show this help"] = true
L["show addon, client and guild status"] = true
L["show the addon version"] = true
L["toggle debug output"] = true
L["Unknown command: %s"] = true

-- Status
L["Version: %s"] = true
L["Client: %s (build %s, interface %d)"] = true
L["Guild: %s"] = true
L["Guild: none"] = true
L["Saved data: session %d, first seen %s"] = true
L["Debug output: %s"] = true
L["on"] = true
L["off"] = true
