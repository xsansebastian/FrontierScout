local _, ns = ...

-- Guild key and per-guild storage bucket (docs/SPEC.md §3.1-3.2).
-- The roster cache and ACL arrive in M3.
local FS, Store = ns.FS, ns.Store

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

-- WoW side -----------------------------------------------------------------

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
