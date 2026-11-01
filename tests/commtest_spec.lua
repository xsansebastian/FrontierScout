local wow = require("tests.helpers.wow")
local Net = require("tests.helpers.net")

-- /fs commtest talks to the game API directly (state.raw in the stubs);
-- pump() plays the game: it delivers those messages as CHAT_MSG_ADDON.
local function pump(net)
	local moved = true
	while moved do
		moved = false
		for _, from in ipairs(net.clients) do
			local raw = from.state.raw or {}
			from.state.raw = {}
			for _, m in ipairs(raw) do
				moved = true
				local lost = m.distribution == "GUILD" and from.state.guildBroken
				local channelName
				for name, index in pairs(from.state.channels) do
					if index == m.target then channelName = name end
				end
				for _, to in ipairs(net.clients) do
					local reaches = m.distribution == "GUILD" or (channelName and to.state.channels[channelName])
					if to ~= from and reaches and not lost then
						wow.fire(to.state, "CHAT_MSG_ADDON", m.prefix, m.text, m.distribution, from.name)
					end
				end
			end
		end
	end
end

local function network(archBroken)
	local net = Net.new({ { name = "Arch", rank = 1, archivist = true, guildBroken = archBroken }, { name = "Gm", rank = 0 } },
		{ channels = true })
	net:Tick() -- join the private channel
	for _, c in ipairs(net.clients) do
		c.state.env.UnitLevel = function() return 20 end
		c.state.printed, c.state.raw = {}, {}
	end
	return net
end

local function printed(client) return table.concat(client.state.printed, "\n") end

describe("/fs commtest", function()
	it("checks both directions on the guild and the private channel", function()
		local net = network(false)
		local arch, gm = net:Client("Arch"), net:Client("Gm")
		wow.slash(arch.state, "commtest")
		local out = printed(arch)
		assert.matches("Account: level 20 | can send chat: ? | can receive chat: ? | can speak in guild chat: true | "
			.. "messaging lockdown: ? | muted: ? | silenced: ? | squelched: ? | chat disabled: ? | "
			.. "age-verification restricted: ? | trial: ? | restricted: ?", out, 1, true)
		assert.matches("Prefixes: FScout yes, FScoutTo yes, FScoutPing yes", out, 1, true)
		assert.matches("Sent over GUILD: accepted", out, 1, true)
		assert.matches("Sent over CHANNEL: accepted", out, 1, true)
		pump(net)
		assert.matches("Arch is testing FrontierScout messages: received over GUILD.", printed(gm), 1, true)
		assert.matches("Arch is testing FrontierScout messages: received over CHANNEL.", printed(gm), 1, true)
		wow.runTimers(arch.state)
		out = printed(arch)
		assert.matches("Replies over GUILD: Gm", out, 1, true)
		assert.matches("Replies over CHANNEL: Gm", out, 1, true)
		assert.matches("Guild members online: 1", out, 1, true)
	end)

	it("shows when one player's guild messages never arrive", function()
		local net = network(true)
		local arch, gm = net:Client("Arch"), net:Client("Gm")
		wow.slash(arch.state, "commtest")
		pump(net)
		assert.is_nil(printed(gm):find("received over GUILD", 1, true))
		wow.runTimers(arch.state)
		assert.matches("Replies over GUILD: none", printed(arch), 1, true)
		assert.matches("Replies over CHANNEL: Gm", printed(arch), 1, true)
	end)

	it("reports WoW Forever's chat restrictions", function()
		local net = network(false)
		local arch = net:Client("Arch")
		arch.state.env.C_SocialRestrictions = {
			CanSendChat = function() return false end, CanReceiveChat = function() return true end,
			IsMuted = function() return true end, IsSilenced = function() return false end,
			IsSquelched = function() return false end, IsChatDisabled = function() return false end,
			IsAgeVerificationRestricted = function() return false end,
		}
		arch.state.env.C_ChatInfo.InChatMessagingLockdown = function() return false end
		wow.slash(arch.state, "commtest")
		assert.matches("can send chat: false | can receive chat: true | can speak in guild chat: true | messaging lockdown: false | "
			.. "muted: true | silenced: false | squelched: false | chat disabled: false | age-verification restricted: false",
			printed(arch), 1, true)
	end)

	it("shows the game's reason when it refuses the test", function()
		local net = network(false)
		local arch = net:Client("Arch")
		arch.state.refuse = { CHANNEL = 8 }
		wow.slash(arch.state, "commtest")
		assert.matches("Sent over CHANNEL: refused (ChannelThrottle)", printed(arch), 1, true)
	end)

	it("ignores whoami probes and players outside the guild", function()
		local net = network(false)
		local gm = net:Client("Gm")
		wow.fire(gm.state, "CHAT_MSG_ADDON", "FScoutPing", "probe", "GUILD", "Arch-Realm")
		wow.fire(gm.state, "CHAT_MSG_ADDON", "FScoutPing", "ping:1", "CHANNEL", "Stranger-Realm")
		assert.is_nil(printed(gm):find("is testing", 1, true))
		assert.same({}, gm.state.raw)
	end)
end)
