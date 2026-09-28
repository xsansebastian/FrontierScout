local _, ns = ...

-- Tells the player about discoveries that just arrived in their zone
-- (docs/SPEC.md §7.8): a chat line and/or an on-screen message.
local FS, L = ns.FS, ns.L
local Categories = ns.Categories

local MAX_LISTED = 3

function FS:NotifyReceived(entries)
	local settings = self.db.profile.notify
	if not (settings.chat or settings.toast) then return end
	local map = C_Map.GetBestMapForUnit("player")
	if not map then return end
	local zone = ns.Maps.Zone(map)
	local here = {}
	for _, e in ipairs(entries) do
		if ns.Maps.Zone(e.map) == zone then here[#here + 1] = e end
	end
	if #here == 0 then return end
	local zoneName = ns.Maps.Name(zone) or "?"
	local summary = #here == 1
		and L["New discovery in %s: %s (%s)"]:format(zoneName, here[1].title, Categories.Label(here[1].sub))
		or L["%d new discoveries in %s"]:format(#here, zoneName)
	if settings.chat then
		self:Print(summary)
		if #here > 1 then
			for i = 1, math.min(#here, MAX_LISTED) do
				self:Print(("  %s (%s)"):format(here[i].title, Categories.Label(here[i].sub)))
			end
		end
	end
	if settings.toast and UIErrorsFrame then
		UIErrorsFrame:AddMessage(summary, 0.2, 0.8, 1)
	end
end

FS:Listen("FRONTIERSCOUT_ENTRIES_RECEIVED", function(entries) FS:NotifyReceived(entries) end)
