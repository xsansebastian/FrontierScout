local _, ns = ...

-- Addon messages (docs/SPEC.md §3.3, §6.3, §6.6): envelope, encoding, guild
-- isolation, addressing, per-sender rate limit, and pausing in combat or
-- instances. Protocol handlers are registered by Sync / Review.
local FS, Guild = ns.FS, ns.Guild

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "FScout"
Comm.PROTOCOL = 1
-- 2: messages for one player are addressed guild messages (PREFIX_TO).
-- Clients below 2 can't hear them; HELLO / ARCH carry it as `tv`.
Comm.TRANSPORT = 2
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
	end
	self:Debug("sending %s%s via %s", t, target and (" to " .. target) or "",
		self:CommChannel() and ("channel " .. self:CommChannel()) or "the guild channel")
	local item = { prefix, text, "GUILD", nil, prio or "NORMAL", t }
	if Comm.Paused() then
		self:Debug("holding %s until combat or the instance ends", t)
		if #queue < Comm.MAX_QUEUE then queue[#queue + 1] = item end
		return false
	end
	self:SendItem(item)
	return true
end

-- The game can refuse an addon message; ChatThrottleLib then drops it
-- silently, so say so in debug, and resend a refused channel message once over
-- the guild channel. AceComm calls back per chunk with (arg, sent, total,
-- result), where result is a success boolean or a Enum.SendAddonMessageResult code.
local function sentCallback(item, _, _, result)
	if result == false or (type(result) == "number" and result ~= 0) then
		FS:Debug("the game didn't send %s over %s (result %s)", tostring(item[6]), tostring(item.via), tostring(result))
		if item.via == "CHANNEL" and not item.retried then
			item.retried, item.via = true, "GUILD"
			FS:SendCommMessage(item[1], item[2], item[3], item[4], item[5], sentCallback, item)
		end
	end
end

-- Private channel ----------------------------------------------------------------
-- On WoW Forever some players' guild addon messages never reach anyone, with no
-- error. Every client therefore also joins a hidden channel for its guild and
-- sends there once joined (the guild channel stays the fallback, and both are
-- read). Anyone could join a channel, so only senders in the guild roster
-- are read from it, and messages still carry the guild key.
Comm.CHANNEL_DELAY = 5 -- joining before the default channels would shift their numbers

-- "FS<club id>" for the guild; another guild key gets a hash.
function Comm.ChannelName(guildKey)
	if type(guildKey) ~= "string" then return nil end
	local id = guildKey:match("^club:(%d+)$")
	if not id then
		local h = 5381
		for i = 1, #guildKey do h = (h * 33 + guildKey:byte(i)) % 4294967296 end
		id = ("%08x"):format(h)
	end
	return "FS" .. id
end

-- Channel number to send on, or nil while not joined (or sending over the
-- guild channel only; the channel is still read then).
function FS:CommChannel()
	if not self.commChannel or not GetChannelName or self.db.profile.guildChannelOnly then return nil end
	local index = GetChannelName(self.commChannel)
	return index and index > 0 and index or nil
end

local function hideChannel(name)
	if not ChatFrame_RemoveChannel then return end
	for i = 1, NUM_CHAT_WINDOWS or 10 do
		local frame = _G["ChatFrame" .. i]
		if frame then pcall(ChatFrame_RemoveChannel, frame, name) end
	end
end

function FS:JoinCommChannel(guildKey)
	local name = Comm.ChannelName(guildKey)
	if self.commChannel and self.commChannel ~= name and LeaveChannelByName then
		LeaveChannelByName(self.commChannel)
	end
	self.commChannel = name
	if not name or not JoinTemporaryChannel then return end
	JoinTemporaryChannel(name)
	hideChannel(name)
	self:Debug("joined channel %s (number %s)", name, tostring(GetChannelName and GetChannelName(name)))
end

FS:Listen("FRONTIERSCOUT_GUILD_CHANGED", function(key)
	if not key then
		FS:JoinCommChannel(nil)
	elseif C_Timer then
		C_Timer.After(Comm.CHANNEL_DELAY, function()
			if FS.guildKey == key then FS:JoinCommChannel(key) end
		end)
	end
end)

function FS:SendItem(item)
	local channel = self:CommChannel()
	if channel then
		item.via = "CHANNEL"
		self:SendCommMessage(item[1], item[2], "CHANNEL", channel, item[5], sentCallback, item)
	else
		item.via = "GUILD"
		self:SendCommMessage(item[1], item[2], item[3], item[4], item[5], sentCallback, item)
	end
end

-- Sends one test message straight through the game (bypassing the queue) and
-- returns what the game answered; for /fs whoami.
function Comm.Probe()
	if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) or not IsInGuild() then return "not available" end
	local ok, result = pcall(C_ChatInfo.SendAddonMessage, "FScoutPing", "ping", "GUILD")
	if not ok then return "error: " .. tostring(result) end
	if result == nil or result == true or result == 0 then return "sent" end
	for key, value in pairs(Enum and Enum.SendAddonMessageResult or {}) do
		if value == result then return ("refused (%s)"):format(key) end
	end
	return ("refused (%s)"):format(tostring(result))
end

function FS:FlushQueue()
	if Comm.Paused() then return end
	local pending = queue
	queue = {}
	for _, item in ipairs(pending) do
		self:SendItem(item)
	end
	self:SendMessage("FRONTIERSCOUT_SYNC_RESUMED")
end

function FS:OnCommReceived(prefix, text, distribution, sender)
	if (prefix ~= Comm.PREFIX and prefix ~= Comm.PREFIX_TO) or not self.guildKey then return end
	sender = Guild.FullName(sender, GetNormalizedRealmName())
	if not sender or sender == self:PlayerName() then return end
	if distribution == "CHANNEL" then
		-- Anyone can join a channel: only guild members count.
		if not self:Member(sender) then
			self:RequestRoster()
			self:Debug("ignored a channel message from %s: not in the guild roster", sender)
			return
		end
	elseif distribution == "GUILD" then
		-- A guild member we don't know yet: our roster is out of date.
		if not self:Member(sender) then self:RequestRoster() end
	else
		return
	end
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
	-- Older clients put the recipient inside the payload.
	if msg.to ~= nil and not self:IsMe(msg.to) then return end
	self:Debug("received %s from %s%s", tostring(msg.t), sender, to and " (to us)" or "")
	for _, handler in ipairs(handlers[msg.t] or {}) do
		handler(self, msg, sender, to and "WHISPER" or "GUILD")
	end
	-- Everyone should hear this sender on the channel; record how they reach us.
	self.heardOn = self.heardOn or {}
	self.heardOn[sender] = distribution
end

-- Are our prefixes registered with the game? A client has a limit on addon
-- message prefixes (all addons together); an unregistered prefix is never
-- delivered, with no error. For /fs whoami.
function Comm.PrefixStatus()
	local check = C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered
	if not check then return "unknown" end
	local parts = {}
	for _, prefix in ipairs({ Comm.PREFIX, Comm.PREFIX_TO }) do
		parts[#parts + 1] = ("%s %s"):format(prefix, check(prefix) and "yes" or "NO")
	end
	return table.concat(parts, ", ")
end

-- Debug: every addon message on our prefixes as the game delivers it, before
-- AceComm or any filtering (once per sender and prefix every 10 seconds).
local rawSeen = {}
local function rawAddonMessage(prefix, _, distribution, sender)
	if (prefix ~= Comm.PREFIX and prefix ~= Comm.PREFIX_TO) or not (FS.db and FS.db.profile.debug) then return end
	local key = tostring(sender) .. prefix
	if rawSeen[key] and GetTime() - rawSeen[key] < 10 then return end
	rawSeen[key] = GetTime()
	FS:Debug("the game delivered a %s message from %s via %s", prefix, tostring(sender), tostring(distribution))
end

FS:OnEnableHook(function()
	FS:RegisterComm(Comm.PREFIX)
	FS:RegisterComm(Comm.PREFIX_TO)
	FS:Debug("addon message prefixes registered: %s", Comm.PrefixStatus())
	FS:ListenEvent("CHAT_MSG_ADDON", rawAddonMessage)
	FS:ListenEvent("PLAYER_REGEN_ENABLED", function() FS:FlushQueue() end)
	FS:ListenEvent("ZONE_CHANGED_NEW_AREA", function() FS:FlushQueue() end)
end)
