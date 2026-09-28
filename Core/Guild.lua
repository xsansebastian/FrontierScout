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

-- Roster cache from rows { name, guid, rankIndex, officerNote, online }:
-- fullName -> { rankIndex, officerNoteHasTag, online, guid }.
-- On WoW Forever names are "Name Surname" (with a space).
function Guild.BuildRoster(rows, realm)
	local roster = {}
	for _, row in ipairs(rows) do
		local full = Guild.FullName(row.name, realm)
		if full then
			roster[full] = {
				rankIndex = row.rankIndex,
				officerNoteHasTag = ACL.NoteHasTag(row.officerNote),
				online = row.online and true or false,
				guid = row.guid,
			}
		end
	end
	return roster
end

-- A name reduced for tolerant comparison: without our own realm, lower
-- case, without spaces ("Lakota Blackelk-Realm" -> "lakotablackelk").
function Guild.LooseName(name, realm)
	if type(name) ~= "string" then return nil end
	return (Guild.WhisperName(name, realm):lower():gsub("%s", ""))
end

-- The name to whisper: without our own realm. WoW Forever addresses players
-- as "Name Surname" and rejects "Name Surname-Realm".
function Guild.WhisperName(fullName, realm)
	if type(fullName) ~= "string" then return fullName end
	local base, suffix = fullName:match("^(.-)%-([^%-]+)$")
	if base and suffix == realm then return base end
	return fullName
end

-- WoW side -----------------------------------------------------------------

FS.acl, FS.aclConfigured = ACL.Parse(nil)
FS.roster = {}
FS.rankNames = {}

-- The player's name as the guild roster has it (found by GUID once the
-- roster has loaded), so it matches what other members see. Before that,
-- UnitFullName.
function FS:PlayerName()
	if self.selfName then return self.selfName end
	local name, realm = UnitFullName("player")
	return name .. "-" .. (realm or GetNormalizedRealmName())
end

-- Is `name` the player? Accepts the roster name, the UnitFullName form, and
-- either without the realm, spaces or case (names reach us in all of these).
function FS:IsMe(name)
	if type(name) ~= "string" then return false end
	local realm = GetNormalizedRealmName()
	local loose = Guild.LooseName(name, realm)
	local unitName, unitRealm = UnitFullName("player")
	for _, mine in ipairs({ self:PlayerName(), unitName and (unitName .. "-" .. (unitRealm or realm)) }) do
		if name == mine or loose == Guild.LooseName(mine, realm) then return true end
	end
	return false
end

-- The player's guild rank index (0 = Guild Master), or nil without a guild.
function FS:MyRank()
	if not IsInGuild() then return nil end
	local _, _, rankIndex = GetGuildInfo("player")
	return rankIndex
end

-- May this client check officer notes for {FS:A}? Only when the game says
-- so AND actually returned note text: a client that is allowed but gets no
-- notes back can't check anyone, so it uses the rank gate like members do.
function FS:CanViewOfficerNotes()
	local allowed = C_GuildInfo and C_GuildInfo.CanViewOfficerNote and C_GuildInfo.CanViewOfficerNote() or false
	return allowed and (self.notesRead or 0) > 0
end

-- Asks the server for fresh roster data, at most every 15 seconds.
function FS:RequestRoster()
	local now = GetTime()
	if self.rosterRequested and now - self.rosterRequested < 15 then return end
	self.rosterRequested = now
	-- Older clients only have the global GuildRoster(); without a request the
	-- roster only loads when the player opens the guild window.
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end
end

-- Rebuilds the roster cache, rank names and ACL from the game.
function FS:UpdateRoster()
	local rows = {}
	local realm, myGuid = GetNormalizedRealmName(), UnitGUID("player")
	self.notesRead = 0 -- officer notes the game gave us text for (diagnostics)
	if IsInGuild() then
		for i = 1, GetNumGuildMembers() or 0 do
			local name, _, rankIndex, _, _, _, _, officerNote, online, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
			if type(officerNote) == "string" and officerNote ~= "" then self.notesRead = self.notesRead + 1 end
			rows[#rows + 1] = { name = name, guid = guid, rankIndex = rankIndex, officerNote = officerNote, online = online }
			if guid and guid == myGuid then self.selfName = Guild.FullName(name, realm) end
		end
	end
	self.roster = Guild.BuildRoster(rows, realm)
	self.rosterLoose = {}
	for full in pairs(self.roster) do self.rosterLoose[Guild.LooseName(full, realm)] = full end
	-- Still empty (the server hasn't answered yet): ask again once the throttle allows.
	if IsInGuild() and next(self.roster) == nil and C_Timer then
		C_Timer.After(16, function() self:RequestRoster() end)
	end
	self.rankNames = {}
	for i = 1, IsInGuild() and GuildControlGetNumRanks() or 0 do
		self.rankNames[i - 1] = GuildControlGetRankName(i)
	end
	self:RefreshACL()
	self:SendMessage("FRONTIERSCOUT_ROSTER_UPDATED")
end

-- The roster entry for `name` and its roster key. Exact match first, then
-- tolerant (case, spaces, our realm), because names can reach us in a
-- slightly different form than the roster has them.
function FS:Member(name)
	if type(name) ~= "string" then return nil end
	local member = self.roster[name]
	if member then return member, name end
	local key = self.rosterLoose and self.rosterLoose[Guild.LooseName(name, GetNormalizedRealmName())]
	if key then return self.roster[key], key end
end

-- Reads the thresholds from Guild Info when its text changed. The text can
-- still be empty right after login; then the last known tag for this guild
-- (saved) is used, so nobody briefly loses their rights.
function FS:RefreshACL()
	local text = IsInGuild() and GetGuildInfoText() or nil
	local meta = self.store and self.store.bucket.meta
	if (not text or text == "") and meta and meta.aclText then text = meta.aclText end
	if not text or text == "" or text == self.aclText then return end
	self.aclText = text
	self.acl, self.aclConfigured = ACL.Parse(text)
	if meta and self.aclConfigured then meta.aclText = text end
end

-- Why the player is or isn't an archivist, for /fs whoami and /fs debug.
function FS:ArchivistStatus()
	local member = self:Member(self:PlayerName())
	return ("rank %s, archivist rank %s, officer note needed: %s, {FS:A} seen: %s, can read officer notes: %s, archivist: %s"):format(
		tostring(member and member.rankIndex or self:MyRank()), tostring(self.acl.ar), tostring(self.acl.an == 1),
		tostring(member and member.officerNoteHasTag), tostring(self:CanViewOfficerNotes()), tostring(self:AmArchivist()))
end

function FS:IsArchivist(fullName)
	self:RefreshACL()
	local member = self:Member(fullName)
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
	self:RefreshACL()
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
	if bucket then
		-- "New since last login" compares against the previous session's start.
		self.newSince = bucket.meta.sessionStart or 0
		bucket.meta.sessionStart = GetServerTime()
	end
	if self.store then
		self.store:CollectGarbage(GetServerTime())
		self.aclText = nil -- re-read for this guild (or use its saved tag)
		self:RefreshACL()
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
