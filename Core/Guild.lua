local _, ns = ...

-- Guild key and per-guild storage bucket (docs/SPEC.md §3.1-3.2), roster
-- cache (§4.5) and permission checks (§4.2-4.4).
local FS, Store, ACL = ns.FS, ns.Store, ns.ACL

local ROSTER_INTERVAL = 60 -- seconds between roster refresh requests (Blizzard throttles to 15)

local Guild = {}
ns.Guild = Guild

function Guild.MakeKey(clubId, realm, name)
	if clubId then return "club:" .. tostring(clubId) end
	if realm and name then return "name:" .. realm .. ":" .. name end
end

-- Finds or creates the bucket for a guild. When the club ID becomes known
-- after data was stored under the name key, the bucket moves to the club key.
function Guild.Resolve(guilds, clubId, realm, name, now)
	local key = Guild.MakeKey(clubId, realm, name)
	if not key then return nil end
	if clubId and not guilds[key] and realm and name then
		local nameKey = Guild.MakeKey(nil, realm, name)
		if guilds[nameKey] then
			guilds[key], guilds[nameKey] = guilds[nameKey], nil
		end
	end
	local bucket = guilds[key] or {}
	guilds[key] = bucket
	bucket.meta = bucket.meta or {}
	bucket.meta.name = name or bucket.meta.name
	bucket.meta.realm = realm or bucket.meta.realm
	bucket.meta.lastSeen = now
	bucket.entries = bucket.entries or {}
	return key, bucket
end

-- "Name-Realm", appending `realm` to names without one.
function Guild.FullName(name, realm)
	if type(name) ~= "string" or name == "" then return nil end
	if name:find("-", 1, true) then return name end
	return name .. "-" .. realm
end

-- Roster cache from rows { name, rankIndex, officerNote, online }:
-- fullName -> { rankIndex, officerNoteHasTag, online }.
function Guild.BuildRoster(rows, realm)
	local roster = {}
	for _, row in ipairs(rows) do
		local full = Guild.FullName(row.name, realm)
		if full then
			roster[full] = {
				rankIndex = row.rankIndex,
				officerNoteHasTag = ACL.NoteHasTag(row.officerNote),
				online = row.online and true or false,
			}
		end
	end
	return roster
end

-- WoW side -----------------------------------------------------------------

FS.acl, FS.aclConfigured = ACL.Parse(nil)
FS.roster = {}
FS.rankNames = {}

function FS:PlayerName()
	local name, realm = UnitFullName("player")
	return name .. "-" .. (realm or GetNormalizedRealmName())
end

-- The player's guild rank index (0 = Guild Master), or nil without a guild.
function FS:MyRank()
	if not IsInGuild() then return nil end
	local _, _, rankIndex = GetGuildInfo("player")
	return rankIndex
end

function FS:CanViewOfficerNotes()
	return C_GuildInfo and C_GuildInfo.CanViewOfficerNote and C_GuildInfo.CanViewOfficerNote() or false
end

-- Asks the server for fresh roster data, at most every 15 seconds.
function FS:RequestRoster()
	local now = GetTime()
	if self.rosterRequested and now - self.rosterRequested < 15 then return end
	self.rosterRequested = now
	if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
end

-- Rebuilds the roster cache, rank names and ACL from the game.
function FS:UpdateRoster()
	local rows = {}
	if IsInGuild() then
		for i = 1, GetNumGuildMembers() or 0 do
			local name, _, rankIndex, _, _, _, _, officerNote, online = GetGuildRosterInfo(i)
			rows[#rows + 1] = { name = name, rankIndex = rankIndex, officerNote = officerNote, online = online }
		end
	end
	self.roster = Guild.BuildRoster(rows, GetNormalizedRealmName())
	self.rankNames = {}
	for i = 1, IsInGuild() and GuildControlGetNumRanks() or 0 do
		self.rankNames[i - 1] = GuildControlGetRankName(i)
	end
	self.acl, self.aclConfigured = ACL.Parse(IsInGuild() and GetGuildInfoText() or nil)
	self:SendMessage("FRONTIERSCOUT_ROSTER_UPDATED")
end

function FS:IsArchivist(fullName)
	local member = self.roster[fullName]
	if fullName == self:PlayerName() and not member then
		member = { rankIndex = self:MyRank() }
	end
	return ACL.IsArchivist(self.acl, member, self:CanViewOfficerNotes())
end

function FS:AmArchivist()
	return self:IsArchivist(self:PlayerName())
end

-- May the player create / edit / delete / report (`op`) `entry`?
-- Returns true, or false and "noguild" | "denied".
function FS:Can(op, entry)
	if not self.store then return false, "noguild" end
	local isAuthor = entry ~= nil and entry.author == self:PlayerName()
	if ACL.CanPropose(self.acl, op, self:MyRank(), isAuthor) then return true end
	return false, "denied"
end

-- Can plus a chat message when denied.
function FS:CheckCan(op, entry)
	local ok, why = self:Can(op, entry)
	if not ok and why == "denied" then
		self:Print(ns.L["Your guild rank can't do that. Guild leadership sets this up in /fs config."])
	end
	return ok
end

-- Archivists by name (online first), for the Guild Setup page.
function FS:ListArchivists()
	local list = {}
	for name in pairs(self.roster) do
		if self:IsArchivist(name) then list[#list + 1] = name end
	end
	table.sort(list, function(a, b)
		local oa, ob = self.roster[a].online, self.roster[b].online
		if oa ~= ob then return oa end
		return a < b
	end)
	return list
end

FS:OnEnableHook(function()
	FS:ListenEvent("GUILD_ROSTER_UPDATE", function() FS:UpdateRoster() end)
	FS:ListenEvent("PLAYER_GUILD_UPDATE", function()
		FS:UpdateRoster()
		FS:RequestRoster()
	end)
	FS:UpdateRoster()
	FS:RequestRoster()
	if C_Timer then C_Timer.NewTicker(ROSTER_INTERVAL, function() FS:RequestRoster() end) end
end)

-- Picks the active bucket from the character's current guild. Guild data can
-- arrive a few seconds after login, so this runs again on guild events.
function FS:RefreshGuild()
	local key, bucket
	if IsInGuild() then
		local name, _, _, realm = GetGuildInfo("player")
		if not name then return end -- not loaded yet; a later event retries
		realm = realm or GetNormalizedRealmName()
		local clubId = C_Club and C_Club.GetGuildClubId and C_Club.GetGuildClubId()
		key, bucket = Guild.Resolve(self.db.global.guilds, clubId, realm, name, GetServerTime())
	end
	if key == self.guildKey then return end
	self.guildKey = key
	self.store = bucket and Store.New(bucket) or nil
	if self.store then
		self.store:CollectGarbage(GetServerTime())
	end
	self:Debug("guild bucket: %s", tostring(key))
	self:SendMessage("FRONTIERSCOUT_GUILD_CHANGED", key)
end

-- The active guild's Store, or nil (and a message) when there is none.
function FS:GetStore(quiet)
	if not self.store and not quiet then
		if IsInGuild() then
			self:Print(ns.L["Guild data is still loading. Try again in a moment."])
		else
			self:Print(ns.L["Join a guild to use FrontierScout."])
		end
	end
	return self.store
end
