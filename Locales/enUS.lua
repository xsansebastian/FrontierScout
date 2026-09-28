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

-- Commands (M2)
L["open the options"] = true

-- Tooltips
L["%d items"] = true
L["Added by %s"] = true
L["Approved by %s"] = true
L["Shift-click: waypoint · Right-click: menu"] = true
L["sold at %s"] = true

-- Map pins
L["Show in browser"] = true

-- Map side panel
L["No discoveries on this map."] = true
L["Ctrl-right-click the map to add a discovery there."] = true
L["Back"] = true
L["Show or hide FrontierScout discoveries"] = true

-- Options
L["Show pins"] = true
L["Icon size"] = true
L["Categories"] = true
L["World map"] = true
L["Minimap"] = true
L["Keep distant pins on the minimap edge"] = true
L["General"] = true
L["Show discoveries in NPC and item tooltips"] = true
L["Waypoints"] = true
L["TomTom if installed, else the map pin"] = true
L["Map pin only"] = true
L["TomTom only"] = true

-- Status (M3)
L["Your rank: %s (%d), archivist: %s"] = true
L["yes"] = true
L["no"] = true
L["Guild permissions: not set up (only the Guild Master can write)."] = true

-- Permissions
L["Your guild rank can't do that. Guild leadership sets this up in /fs config."] = true

-- Browser (M3)
L["Not set up for this guild yet: only the Guild Master can write. See /fs config."] = true

-- Guild Setup
L["Submit new discoveries"] = true
L["Edit their own discoveries"] = true
L["Edit anyone's discoveries"] = true
L["Delete their own discoveries"] = true
L["Delete anyone's discoveries"] = true
L["Report outdated discoveries"] = true
L["Archivists: minimum rank"] = true
L["%s and above"] = true
L["Everyone"] = true
L["Guild Info is too long to add the FrontierScout tag. Shorten it and try again."] = true
L["Guild permissions saved to Guild Info."] = true
L["Current settings come from the guild's Guild Info."] = true
L["This guild has no FrontierScout settings yet, so only the Guild Master can write."] = true
L["Everyone can see all discoveries. Choose the lowest rank allowed to do each action."] = true
L["Guild Info tag: %s"] = true
L["Write to Guild Info"] = true
L["Adds or updates the tag in Guild Info and leaves the rest of the text as it is."] = true
L["Undo changes"] = true
L["Archivists approve discoveries and share them with the guild. To make someone an archivist, add {FS:A} to their officer note (Guild & Communities > Roster). Their rank must also meet the archivist rank above."] = true
L["none yet"] = true
L["Archivists: %s"] = true
L["Guild Setup"] = true

-- Sync commands
L["sync with online archivists now"] = true
L["Last sync: %s; archivists online: %s"] = true
L["never"] = true
L["none seen"] = true

-- Sync
L["Sync is paused in combat and instances."] = true
L["Looking for archivists..."] = true

-- Review
L["No longer valid: %s"] = true
L["Your submission \"%s\" was rejected: %s"] = true
L["no reason given"] = true
L["Your submission \"%s\" was approved."] = true

-- Curation (dialog)
L["Submitted for review: %s"] = true

-- Curation (browser)
L["Report outdated"] = true
L["Discoveries"] = true
L["Report \"%s\" as outdated? What changed?"] = true
L["Report"] = true
L["Thanks! The archivists will take a look."] = true

-- Sync warnings
L["%s sent %s but has no {FS:A} officer-note tag; ignored."] = true

-- Submissions, review and sync tabs
L["Outdated"] = true
L["waiting for an archivist"] = true
L["in the review queue"] = true
L["approved"] = true
L["rejected"] = true
L["My submissions (%d)"] = true
L["My submissions"] = true
L["Nothing submitted yet."] = true
L["Send again"] = true
L["No archivist is online. Submissions are sent when one is."] = true
L["Clear finished"] = true
L["Discoveries you add, edit, delete or report are reviewed by an archivist before the guild sees them."] = true
L["%s, sent %s"] = true
L["Status: %s"] = true
L["Reason: %s"] = true
L["By %s (%s), %s"] = true
L["Can't be approved any more: %s"] = true
L["Warning: the entry changed since this was proposed (revision %d, now %d)."] = true
L["Changes"] = true
L["Reject \"%s\"? Reason (sent to the author):"] = true
L["Reject"] = true
L["Review (%d)"] = true
L["Review"] = true
L["Nothing to review."] = true
L["Approve"] = true
L["Show"] = true
L["Select a proposal to review it."] = true
L["Resolved"] = true
L["Dismiss"] = true
L["Warnings"] = true
L["Sync"] = true
L["Sync now"] = true
L["Discoveries: %d (%d records, counting deletions still spreading)"] = true
L["Last full sync: %s"] = true
L["Archivists seen: %s"] = true
L["Your role: %s"] = true
L["archivist"] = true
L["member"] = true
L["Syncing with %s..."] = true
L["Data hash: %08x"] = true

-- Browser (M6)
L["new"] = true
L["New since last login"] = true

-- Notifications
L["New discovery in %s: %s (%s)"] = true
L["%d new discoveries in %s"] = true

-- Options (M6)
L["Removed data of %d other guild(s)."] = true
L["Local data cleared. Syncing again..."] = true
L["Notifications"] = true
L["Chat message when discoveries arrive in my zone"] = true
L["On-screen message when discoveries arrive in my zone"] = true
L["Data"] = true
L["Other guilds with stored data: %s"] = true
L["none"] = true
L["Delete data of other guilds"] = true
L["Delete the discoveries stored for guilds you are not in?"] = true
L["Reset this guild's data and sync again"] = true
L["Clear this guild's local discoveries and download them again from an archivist? Your submissions are kept."] = true
L["Archivists can only reset while another archivist is online, so the guild's data isn't lost."] = true
