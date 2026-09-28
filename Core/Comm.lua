local _, ns = ...

-- Addon messages (docs/SPEC.md §3.3, §6.3, §6.6): envelope, encoding, guild
-- and whisper isolation, per-sender rate limit, and pausing in combat or
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
local recentWhispers = {} -- whisper target -> GetTime(), to hide "player not found" errors
local whisperFailed = {}  -- full name -> true: send to them over GUILD instead

-- Small messages for one player that go over the guild channel (addressed
-- with `to`) instead of a whisper: whispering WoW Forever's "Name Surname"
-- names isn't reliable, and these must arrive.
Comm.VIA_GUILD = { PROP = true, PACK = true, QMISS = true, QDEC = true, ARCH = true, SYNCREQ = true, WANT = true, BUSY = true }

-- Sends everything for `name` over the guild channel (a member whose
-- downloads over whispers never arrived asks for this).
function FS:PreferGuild(name)
	whisperFailed[name] = true
end

-- A whisper from us that the game couldn't deliver prints "No player named
-- '...' is currently playing." Hide it (the user didn't whisper anyone) and
-- reach that player over the guild channel from now on.
function Comm.FilterNotFound(_, _, text)
	if not ERR_CHAT_PLAYER_NOT_FOUND_S or type(text) ~= "string" then return false end
	for target, at in pairs(recentWhispers) do
		if GetTime() - at > 10 then
			recentWhispers[target] = nil
		elseif text == ERR_CHAT_PLAYER_NOT_FOUND_S:format(target) then
			whisperFailed[Guild.FullName(target, GetNormalizedRealmName())] = true
			FS:Debug("whisper to %s failed; using the guild channel for them", target)
			return true
		end
	end
	return false
end
local limiter = Comm.NewRateLimiter(Comm.RATE_LIMIT, Comm.RATE_WINDOW)
local queue = {}

-- Adds handler(FS, msg, sender, distribution) for message type `t`.
function FS:OnMessageType(t, handler)
	handlers[t] = handlers[t] or {}
	table.insert(handlers[t], handler)
end

-- Sends message type `t` with `payload` fields on GUILD or WHISPER (to
-- `target`). While paused the message is queued and sent on resume.
function FS:Send(t, payload, channel, target, prio)
	if not self.guildKey then return false end
	payload.v, payload.g, payload.t = Comm.PROTOCOL, self.guildKey, t
	if channel == "WHISPER" and (Comm.VIA_GUILD[t] or whisperFailed[target]) then
		payload.to, channel, target = target, "GUILD", nil
	elseif channel == "WHISPER" then
		target = Guild.WhisperName(target, GetNormalizedRealmName())
		recentWhispers[target] = GetTime()
	end
	self:Debug("sending %s via %s%s", t, channel, payload.to and (" to " .. payload.to) or (target and (" to " .. target) or ""))
	local item = { Comm.Encode(payload), channel, target, prio or "NORMAL" }
	if Comm.Paused() then
		if #queue < Comm.MAX_QUEUE then queue[#queue + 1] = item end
		return false
	end
	self:SendCommMessage(Comm.PREFIX, item[1], item[2], item[3], item[4])
	return true
end

function FS:FlushQueue()
	if Comm.Paused() then return end
	local pending = queue
	queue = {}
	for _, item in ipairs(pending) do
		self:SendCommMessage(Comm.PREFIX, item[1], item[2], item[3], item[4])
	end
	self:SendMessage("FRONTIERSCOUT_SYNC_RESUMED")
end

function FS:OnCommReceived(prefix, text, distribution, sender)
	if prefix ~= Comm.PREFIX or not self.guildKey then return end
	if distribution ~= "GUILD" and distribution ~= "WHISPER" then return end
	sender = Guild.FullName(sender, GetNormalizedRealmName())
	if not sender or sender == self:PlayerName() then return end
	-- A guild member we don't know yet: our roster is out of date.
	if distribution == "GUILD" and not self:Member(sender) then self:RequestRoster() end
	-- Whispers only from guild members (SPEC §3.3).
	if distribution == "WHISPER" and not self:Member(sender) then
		self:Debug("ignored a whisper from %s: not in the guild roster", sender)
		return
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
	-- Guild messages addressed to someone else.
	if msg.to ~= nil and not self:IsMe(msg.to) then
		self:Debug("skipped %s from %s: addressed to %s", tostring(msg.t), sender, tostring(msg.to))
		return
	end
	self:Debug("received %s from %s", tostring(msg.t), sender)
	for _, handler in ipairs(handlers[msg.t] or {}) do
		handler(self, msg, sender, distribution)
	end
end

FS:OnEnableHook(function()
	FS:RegisterComm(Comm.PREFIX)
	if ChatFrame_AddMessageEventFilter then
		ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", Comm.FilterNotFound)
	end
	FS:ListenEvent("PLAYER_REGEN_ENABLED", function() FS:FlushQueue() end)
	FS:ListenEvent("ZONE_CHANGED_NEW_AREA", function() FS:FlushQueue() end)
end)
