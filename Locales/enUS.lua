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

-- Commands and key bindings
L["Open or close the discoveries browser"] = true
L["Record a discovery here"] = true
L["record a discovery here (optional: title)"] = true
L["waypoint mode: auto, native or tomtom"] = true
L["open the discoveries browser"] = true
L["Not available in combat."] = true
L["FrontierScout records open-world discoveries only."] = true
L["Unknown waypoint mode: %s"] = true
L["Waypoint mode: %s"] = true
L["Discoveries in this guild: %d"] = true

-- Categories
L["NPC"] = true
L["Location"] = true
L["Item"] = true
L["Event"] = true
L["Rare"] = true
L["Vendor"] = true
L["Trainer"] = true
L["Notable NPC"] = true
L["Treasure"] = true
L["Cave"] = true
L["Secret"] = true
L["Lore"] = true
L["Hotspot"] = true
L["Drop"] = true
L["Quest item"] = true
L["Curiosity"] = true
L["World event"] = true
L["Timed spawn"] = true

-- Guild
L["Join a guild to use FrontierScout."] = true
L["Guild data is still loading. Try again in a moment."] = true

-- Waypoints
L["Waypoint set: %s"] = true
L["TomTom is not loaded. Use /fs waypoints auto or native."] = true
L["This map does not allow waypoints."] = true

-- Add / edit dialog
L["Choose a category and type."] = true
L["A title is required."] = true
L["No position yet: stand on the spot and click \"Use my position\"."] = true
L["Coordinates must look like 45.2, 67.8."] = true
L["The NPC ID must be a number."] = true
L["This guild has reached the discovery limit."] = true
L["This discovery no longer exists."] = true
L["unknown"] = true
L["Edit discovery"] = true
L["New discovery"] = true
L["Shift-click items to insert their links."] = true
L["Saved: %s"] = true
L["Category"] = true
L["Type"] = true
L["Title"] = true
L["Description"] = true
L["Zone: %s"] = true
L["Coordinates"] = true
L["Use my position"] = true
L["NPC ID"] = true
L["Use target"] = true
L["Items (one per line: item link or ID = cost)"] = true
L["Respawn (minutes)"] = true
L["Window"] = true
L["Schedule note"] = true
L["Tags (comma-separated, up to 5)"] = true
L["Save"] = true
L["Cancel"] = true
L["Scout"] = true
L["Record this vendor and its stock in FrontierScout"] = true

-- Browser
L["NPC ID: %d"] = true
L["Respawn: %d min"] = true
L["Window: %s"] = true
L["Items"] = true
L["...and %d more"] = true
L["Tags: %s"] = true
L["Added by %s on %s"] = true
L["Edited by %s on %s (revision %d)"] = true
L["Select a discovery"] = true
L["Other"] = true
L["All zones"] = true
L["FrontierScout - %d discoveries"] = true
L["Waypoint"] = true
L["Edit"] = true
L["Delete"] = true
L["New"] = true
L["No discoveries here yet.\nClick New or type /fs add."] = true
L["Delete \"%s\"?"] = true
