local _, ns = ...

-- Addon messages (docs/SPEC.md §3.3, §6.3, §6.6): envelope, encoding, guild
-- isolation, addressing, per-sender rate limit, and pausing in combat or
-- instances. Protocol handlers are registered by Sync / Review.
local FS, Guild = ns.FS, ns.Guild

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "FScout"
Comm.PROTOCOL = 1
Comm.MAX_TEXT = 256 * 1024     -- encoded bytes accepted from one message
Comm.MAX_RAW = 1024 * 1024     -- decompressed bytes
Comm.RATE_LIMIT, Comm.RATE_WINDOW = 30, 60
Comm.MAX_QUEUE = 100

local Serializer = LibStub("AceSerializer-3.0")
local Deflate = LibStub("LibDeflate")

function Comm.Encode(t)
	return Deflate:EncodeForWoWAddonChannel(Deflate:CompressDeflate(Serializer:Serialize(t)))
end

-- Table from an encoded message, or nil for anything malformed.
function Comm.Decode(text)
	if type(text) ~= "string" or #text > Comm.MAX_TEXT then return nil end
	local ok, result = pcall(function()
		local raw = Deflate:DecodeForWoWAddonChannel(text)
		local s = raw and Deflate:DecompressDeflate(raw)
		if not s or #s > Comm.MAX_RAW then return nil end
		local okSer, t = Serializer:Deserialize(s)
		if okSer and type(t) == "table" then return t end
	end)
	return ok and result or nil
end

-- allow(sender, now): false once `sender` sent `limit` messages within `window` seconds.
function Comm.NewRateLimiter(limit, window)
	local log = {}
	return function(sender, now)
		local times = log[sender] or {}
		local kept = {}
		for _, t in ipairs(times) do
			if now - t < window then kept[#kept + 1] = t end
		end
		log[sender] = kept
		if #kept >= limit then return false end
		kept[#kept + 1] = now
		return true
	end
end

-- Addon comms are restricted (and pointless) in combat and instances.
function Comm.Paused()
	return InCombatLockdown() or IsInInstance()
end

-- WoW side -------------------------------------------------------------------

local handlers = {}

-- Messages for one player go over the guild channel too: addon whispers to
-- WoW Forever's "Name Surname" names are lost without any error. They use
-- their own prefix and carry the recipient in plain text before the payload,
-- so everyone else skips them before rate limiting or decoding.
Comm.PREFIX_TO = "FScoutTo"
local SEP = "\001"

function Comm.Address(to, text)
	return to .. SEP .. text
end

-- Recipient and payload of an addressed message, or nil.
function Comm.Unaddress(text)
	if type(text) ~= "string" then return nil end
	local at = text:find(SEP, 1, true)
	if not at or at == 1 or at > 80 then return nil end
	return text:sub(1, at - 1), text:sub(at + 1)
end

local limiter = Comm.NewRateLimiter(Comm.RATE_LIMIT, Comm.RATE_WINDOW)
local queue = {}

-- Adds handler(FS, msg, sender, distribution) for message type `t`.
function FS:OnMessageType(t, handler)
	handlers[t] = handlers[t] or {}
	table.insert(handlers[t], handler)
end

-- Sends message type `t` with `payload` fields to the guild, or with channel
-- "WHISPER" to `target` only (over the guild channel, addressed). While
-- paused the message is queued and sent on resume.
function FS:Send(t, payload, channel, target, prio)
	if not self.guildKey then return false end
	payload.v, payload.g, payload.t = Comm.PROTOCOL, self.guildKey, t
	local prefix, text = Comm.PREFIX, Comm.Encode(payload)
	if channel == "WHISPER" then
		prefix, text = Comm.PREFIX_TO, Comm.Address(target, text)
		self:Debug("sending %s to %s", t, target)
	else
		self:Debug("sending %s to the guild", t)
	end
	local item = { prefix, text, "GUILD", nil, prio or "NORMAL" }
	if Comm.Paused() then
		if #queue < Comm.MAX_QUEUE then queue[#queue + 1] = item end
		return false
	end
	self:SendCommMessage(item[1], item[2], item[3], item[4], item[5])
	return true
end

function FS:FlushQueue()
	if Comm.Paused() then return end
	local pending = queue
	queue = {}
	for _, item in ipairs(pending) do
		self:SendCommMessage(item[1], item[2], item[3], item[4], item[5])
	end
	self:SendMessage("FRONTIERSCOUT_SYNC_RESUMED")
end

function FS:OnCommReceived(prefix, text, distribution, sender)
	if (prefix ~= Comm.PREFIX and prefix ~= Comm.PREFIX_TO) or not self.guildKey then return end
	if distribution ~= "GUILD" then return end
	sender = Guild.FullName(sender, GetNormalizedRealmName())
	if not sender or sender == self:PlayerName() then return end
	-- A guild member we don't know yet: our roster is out of date.
	if not self:Member(sender) then self:RequestRoster() end
	local to
	if prefix == Comm.PREFIX_TO then
		to, text = Comm.Unaddress(text)
		if not to or not self:IsMe(to) then
			self:Debug("skipped a message from %s addressed to %s", sender, tostring(to))
			return
		end
	end
	-- The archivist this client pulls from is exempt: a full sync is many messages.
	if sender ~= self.syncPartner and not limiter(sender, GetTime()) then
		self:Debug("rate limit: dropped a message from %s", sender)
		return
	end
	local msg = Comm.Decode(text)
	if not msg or msg.v ~= Comm.PROTOCOL or msg.g ~= self.guildKey then
		self:Debug("ignored a message from %s: other guild or version", sender)
		return
	end
	self:Debug("received %s from %s%s", tostring(msg.t), sender, to and " (to us)" or "")
	for _, handler in ipairs(handlers[msg.t] or {}) do
		handler(self, msg, sender, to and "WHISPER" or "GUILD")
	end
end

FS:OnEnableHook(function()
	FS:RegisterComm(Comm.PREFIX)
	FS:RegisterComm(Comm.PREFIX_TO)
	FS:ListenEvent("PLAYER_REGEN_ENABLED", function() FS:FlushQueue() end)
	FS:ListenEvent("ZONE_CHANGED_NEW_AREA", function() FS:FlushQueue() end)
end)
