-- A fake guild network: several addon instances whose addon messages reach
-- each other. GUILD goes to every other client in the same guild; WHISPER to
-- the named player. Delivery is queued; call net:Flush() to run it.
local wow = require("tests.helpers.wow")

local Net = {}
Net.__index = Net

-- members = { { name = "Arch", rank = 1, archivist = true }, ... }
-- Everyone shares the guild, the Guild Info tag and a roster built from `members`.
function Net.new(members, opts)
	opts = opts or {}
	local net = setmetatable({ clients = {}, byName = {}, queue = {}, delivered = 0 }, Net)
	local roster = {}
	for _, m in ipairs(members) do
		roster[#roster + 1] = { name = m.name .. "-Realm", rankIndex = m.rank or 2,
			officerNote = m.archivist and "{FS:A}" or "", online = true }
	end
	for _, m in ipairs(members) do
		local state, FS, ns = wow.boot({ guild = "Wardens", player = m.name, rank = m.rank or 2, roster = roster,
			guildInfo = opts.guildInfo or "[FS1 s=2 eo=2 ea=1 do=2 da=1 r=9 ar=1]", canViewNotes = (m.rank or 2) <= 1,
			now = opts.now, ui = opts.ui, channels = opts.channels or m.channels })
		-- m.guildBroken: this player's guild addon messages never arrive (seen on WoW Forever).
		state.guildBroken = m.guildBroken
		state.bus = net
		FS:OnEnable()
		local client = { name = m.name .. "-Realm", state = state, FS = FS, ns = ns }
		net.clients[#net.clients + 1] = client
		net.byName[client.name] = client
	end
	return net
end

function Net:Send(fromState, prefix, text, distribution, target)
	if distribution == "GUILD" and fromState.guildBroken then return end
	local channelName
	if distribution == "CHANNEL" then
		for name, index in pairs(fromState.channels) do
			if index == target then channelName = name end
		end
	end
	for _, c in ipairs(self.clients) do
		if c.state ~= fromState then
			local to = distribution == "GUILD" or (distribution == "WHISPER" and (target == c.name or target .. "-Realm" == c.name))
				or (channelName ~= nil and c.state.channels[channelName] ~= nil)
			if to and not c.offline then
				local sender
				for _, s in ipairs(self.clients) do if s.state == fromState then sender = s.name end end
				self.queue[#self.queue + 1] = { client = c, prefix = prefix, text = text, distribution = distribution, sender = sender }
			end
		end
	end
end

-- Delivers queued messages (and those they trigger) until quiet.
function Net:Flush(limit)
	limit = limit or 10000
	while #self.queue > 0 and limit > 0 do
		local item = table.remove(self.queue, 1)
		local FS = item.client.FS
		FS[item.client.state.commMethod](FS, item.prefix, item.text, item.distribution, item.sender)
		self.delivered = self.delivered + 1
		limit = limit - 1
	end
end

-- Runs every client's pending timers, then delivers messages.
function Net:Tick()
	for _, c in ipairs(self.clients) do wow.runTimers(c.state) end
	self:Flush()
end

function Net:Client(name) return self.byName[name .. "-Realm"] end

return Net
