local _, ns = ...

-- /fs commtest: checks that addon messages travel both ways between the
-- player and every other online FrontierScout user, on the guild channel and
-- on the private channel. It talks straight to the game API on its own prefix
-- (no AceComm, serializer, compression or FrontierScout filtering), so a
-- missing reply points at the game or the server, not at the addon.
local FS, L, Comm, Guild = ns.FS, ns.L, ns.Comm, ns.Guild

local CommTest = {}
ns.CommTest = CommTest

CommTest.PREFIX = "FScoutPing"
CommTest.WAIT = 10 -- seconds to collect replies
local REPLY_GAP = 5 -- answer one player at most this often per channel

local current        -- { id, replies = { GUILD = { name = true }, CHANNEL = { ... } } }
local answered = {}  -- sender .. distribution -> GetTime()

local function send(text, distribution, target)
	if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return "not available" end
	local ok, result = pcall(C_ChatInfo.SendAddonMessage, CommTest.PREFIX, text, distribution, target)
	if not ok then return "error: " .. tostring(result) end
	if result == nil or result == true or result == 0 then return "accepted" end
	for key, value in pairs(Enum and Enum.SendAddonMessageResult or {}) do
		if value == result then return ("refused (%s)"):format(key) end
	end
	return ("refused (%s)"):format(tostring(result))
end

-- The routes to test: the guild channel, and the private channel when joined.
local function routes()
	local list = { { "GUILD" } }
	local channel = FS:CommChannel() or (FS.commChannel and GetChannelName and GetChannelName(FS.commChannel))
	if channel and channel ~= 0 then list[#list + 1] = { "CHANNEL", channel } end
	return list
end

-- Everything that can stop a character's chat or addon messages. WoW Forever
-- runs on the modern client: besides trial / restricted accounts it has
-- C_SocialRestrictions (muted, silenced, squelched, chat disabled, age
-- verification, can send / receive chat) and an addon messaging lockdown
-- (C_ChatInfo.InChatMessagingLockdown, e.g. in instances).
local function restrictions()
	local S, C = C_SocialRestrictions, C_ChatInfo
	local checks = {
		{ "can send chat", S and S.CanSendChat },
		{ "can receive chat", S and S.CanReceiveChat },
		{ "can speak in guild chat", C_GuildInfo and C_GuildInfo.CanSpeakInGuildChat },
		{ "messaging lockdown", C and C.InChatMessagingLockdown },
		{ "muted", S and S.IsMuted },
		{ "silenced", S and S.IsSilenced },
		{ "squelched", S and S.IsSquelched },
		{ "chat disabled", S and S.IsChatDisabled },
		{ "age-verification restricted", S and S.IsAgeVerificationRestricted },
		{ "trial", IsTrialAccount },
		{ "restricted", IsRestrictedAccount },
	}
	local parts = { "level " .. tostring(UnitLevel and UnitLevel("player")) }
	for _, check in ipairs(checks) do
		local value = "?"
		if check[2] then
			local ok, result = pcall(check[2])
			value = ok and tostring(result and true or false) or "error"
		end
		parts[#parts + 1] = ("%s: %s"):format(check[1], value)
	end
	return table.concat(parts, " | ")
end

local function prefixes()
	local check = C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered
	local all = C_ChatInfo and C_ChatInfo.GetRegisteredAddonMessagePrefixes
	return ("%s, %s %s | prefixes registered by all addons: %s"):format(Comm.PrefixStatus(), CommTest.PREFIX,
		check and (check(CommTest.PREFIX) and "yes" or "NO") or "?", all and tostring(#all()) or "?")
end

local function report()
	if not current then return end
	local test = current
	current = nil
	for _, route in ipairs(test.routes) do
		local names = {}
		for name in pairs(test.replies[route[1]] or {}) do names[#names + 1] = Ambiguate(name, "guild") end
		table.sort(names)
		FS:Print(("Replies over %s: %s"):format(route[1], #names > 0 and table.concat(names, ", ") or "none"))
	end
	local online = 0
	for name, member in pairs(FS.roster or {}) do
		if member.online and not FS:IsMe(name) then online = online + 1 end
	end
	FS:Print(("Guild members online: %d (only those running this FrontierScout version reply)."):format(online))
end

function FS:CommTest()
	if not IsInGuild() then
		self:Print(L["You are not in a guild."])
		return
	end
	if current then
		self:Print(L["A test is already running."])
		return
	end
	current = { id = tostring(math.floor(GetTime() * 1000)), replies = {}, routes = routes() }
	self:Print(L["Testing addon messages with the guild; results in %d seconds..."]:format(CommTest.WAIT))
	self:Print("Account: " .. restrictions())
	self:Print("Prefixes: " .. prefixes())
	for _, route in ipairs(current.routes) do
		self:Print(("Sent over %s: %s"):format(route[1], send("ping:" .. current.id, route[1], route[2])))
	end
	if C_Timer then C_Timer.After(CommTest.WAIT, report) end
end

-- Pings from guild members get a pong on the same route; pongs for our
-- running test are counted. Anything else on this prefix (e.g. whoami's
-- "probe") is ignored.
function CommTest.OnMessage(prefix, text, distribution, sender)
	if prefix ~= CommTest.PREFIX or type(text) ~= "string" then return end
	if distribution ~= "GUILD" and distribution ~= "CHANNEL" then return end
	sender = Guild.FullName(sender, GetNormalizedRealmName())
	if not sender or FS:IsMe(sender) or not FS:Member(sender) then return end
	local kind, id = text:match("^(%a+):(%d+)$")
	if kind == "ping" then
		local key = sender .. distribution
		if answered[key] and GetTime() - answered[key] < REPLY_GAP then return end
		answered[key] = GetTime()
		FS:Print(L["%s is testing FrontierScout messages: received over %s."]:format(Ambiguate(sender, "guild"), distribution))
		local target
		if distribution == "CHANNEL" then
			for _, route in ipairs(routes()) do
				if route[1] == "CHANNEL" then target = route[2] end
			end
			if not target then return end
		end
		send("pong:" .. id, distribution, target)
	elseif kind == "pong" and current and id == current.id then
		current.replies[distribution] = current.replies[distribution] or {}
		current.replies[distribution][sender] = true
	end
end

FS:OnEnableHook(function()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		C_ChatInfo.RegisterAddonMessagePrefix(CommTest.PREFIX)
	end
	FS:ListenEvent("CHAT_MSG_ADDON", CommTest.OnMessage)
end)
