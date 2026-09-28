local _, ns = ...

-- Curation (docs/SPEC.md §5.3-5.4, §6.4-6.5): members' writes become
-- proposals that an archivist approves or rejects.
--   PROP    (whisper) contributor -> each online archivist   submit
--   PACK    (whisper) archivist -> contributor               queued, remove from outbox
--   QDEC    (guild / whisper) archivist                      a decision: approved / rejected
--   QSYNC   (whisper) archivist <-> archivist                pending queue + recent decisions
-- Approved changes reach everyone as APPR (Sync).
local FS, L = ns.FS, ns.L
local Store, Format, ACL, Categories = ns.Store, ns.Format, ns.ACL, ns.Categories

local Review = {}
ns.Review = Review

Review.OPS = { create = true, edit = true, delete = true, report = true }
Review.MAX_REASON = 200
Review.MAX_QUEUE = 500
Review.DECISION_TTL = 30 * 24 * 3600
Review.RESEND_INTERVAL = 60

-- Pure ---------------------------------------------------------------------------

local function name(v)
	return type(v) == "string" and #v <= 64 and v:find("-", 1, true) and v or nil
end

-- Validates a proposal from the network or the UI. Returns a clean copy or
-- nil and an error code (Store.Validate's for create/edit data).
function Review.ValidateProposal(p)
	if type(p) ~= "table" or not Review.OPS[p.op] then return nil, "invalid" end
	if type(p.pid) ~= "string" or #p.pid > 64 or type(p.eid) ~= "string" or #p.eid > 64 then return nil, "invalid" end
	local author, at = name(p.author), tonumber(p.at)
	if not author or not at then return nil, "invalid" end
	local clean = { pid = p.pid, op = p.op, eid = p.eid, author = author, at = at, baseRev = tonumber(p.baseRev) }
	if p.op == "create" or p.op == "edit" then
		local data, err = Store.Validate(p.data)
		if not data then return nil, err end
		clean.data = data
	end
	local reason = Format.Sanitize(p.reason, Review.MAX_REASON, { multiline = true })
	clean.reason = reason ~= "" and reason or nil
	return clean
end

local function coords(e) return e.x and Format.Coords(e.x, e.y) end
local function itemsText(e) return e.items and tostring(#e.items) or nil end
local function tagsText(e) return e.tags and Format.Tags(e.tags) or nil end
local function scheduleText(e)
	local s = e.schedule
	if not s then return nil end
	return table.concat({ s.respawnMin and (s.respawnMin .. " min") or "", s.window or "", s.note or "" }, " / ")
end

local DIFF_FIELDS = {
	{ "type", function(e) return e.sub and Categories.Label(e.sub) end },
	{ "title", function(e) return e.title end },
	{ "description", function(e) return e.desc end },
	{ "position", function(e) return e.map and (e.map .. " @ " .. coords(e)) end },
	{ "npcID", function(e) return e.npcID and tostring(e.npcID) end },
	{ "items", itemsText },
	{ "schedule", scheduleText },
	{ "tags", tagsText },
}

-- Changed fields between two entry versions: { { field, old, new }, ... }.
function Review.Diff(old, new)
	local changes = {}
	for _, f in ipairs(DIFF_FIELDS) do
		local a, b = f[2](old or {}), f[2](new or {})
		if a ~= b then changes[#changes + 1] = { f[1], a, b } end
	end
	return changes
end

-- WoW side --------------------------------------------------------------------------

local function lists(self)
	local b = self.store.bucket
	b.outbox = b.outbox or {}
	b.mine = b.mine or {}
	b.queue = b.queue or {}
	b.decided = b.decided or {}
	return b
end

local sentAt = {} -- pid -> GetTime() of the last PROP

-- Online archivists other than the player, from the roster.
function FS:OnlineArchivists()
	local list, me = {}, self:PlayerName()
	for member, info in pairs(self.roster) do
		if info.online and member ~= me and self:IsArchivist(member) then list[#list + 1] = member end
	end
	table.sort(list)
	return list
end

-- Sends waiting proposals to every online archivist (each at most once a minute).
function FS:FlushOutbox(force)
	if not self.store then return 0 end
	local archivists = self:OnlineArchivists()
	if #archivists == 0 then return 0 end
	local sent = 0
	for pid, p in pairs(lists(self).outbox) do
		if force or not sentAt[pid] or GetTime() - sentAt[pid] >= Review.RESEND_INTERVAL then
			sentAt[pid] = GetTime()
			for _, archivist in ipairs(archivists) do
				self:Send("PROP", { p = p }, "WHISPER", archivist, "NORMAL")
			end
			sent = sent + 1
		end
	end
	return sent
end

-- Creates a proposal for `op` on entry `eid` (nil for create). Returns the
-- proposal, or nil and an error code.
function FS:Propose(op, eid, data, reason)
	local store = self:GetStore()
	if not store then return nil, "noguild" end
	local global = self.db.global
	global.idSeq = (global.idSeq or 0) + 1
	local now, guid = GetServerTime(), UnitGUID("player")
	local target = eid and store:Get(eid)
	if eid and not target then return nil, "missing" end
	local p, err = Review.ValidateProposal({
		pid = Store.MakeId("P", guid, now, global.idSeq),
		op = op,
		eid = eid or Store.MakeId("E", guid, now, global.idSeq),
		baseRev = target and target.rev,
		data = data,
		reason = reason,
		author = self:PlayerName(),
		at = now,
	})
	if not p then return nil, err end
	local b = lists(self)
	b.outbox[p.pid] = p
	b.mine[p.pid] = {
		op = op, eid = p.eid, at = now, status = "waiting",
		title = (p.data and p.data.title) or (target and target.title) or "?",
	}
	self:SendMessage("FRONTIERSCOUT_PROPOSALS_CHANGED")
	self:FlushOutbox(true)
	return p
end

-- Reports an entry as outdated.
function FS:Report(eid, reason)
	local store = self:GetStore()
	local e = store and store:Get(eid)
	if not e then return nil, "missing" end
	if not self:CheckCan("report", e) then return nil, "denied" end
	if self:AmArchivist() then
		-- Straight into our own queue; other archivists get it through QSYNC.
		local p = self:Propose("report", eid, nil, reason)
		if p then
			lists(self).outbox[p.pid] = nil
			lists(self).mine[p.pid].status = "queued"
			lists(self).queue[p.pid] = p
			self:SendMessage("FRONTIERSCOUT_QUEUE_CHANGED")
		end
		return p
	end
	return self:Propose("report", eid, nil, reason)
end

-- Is proposal `p` allowed for its author right now (SPEC §6.5)?
function FS:ProposalAllowed(p)
	local member = self.roster[p.author]
	if not member and p.author == self:PlayerName() then member = { rankIndex = self:MyRank() } end
	if not member then return false, "notmember" end
	local target = self.store:Get(p.eid)
	if p.op == "create" then
		if self.store:GetAny(p.eid) then return false, "exists" end
	elseif not target then
		return false, "missing"
	end
	local isAuthor = target ~= nil and target.author == p.author
	if not ACL.CanPropose(self.acl, p.op, member.rankIndex, isAuthor) then return false, "denied" end
	return true
end

local function decide(self, pid, status, reason, eid)
	local b = lists(self)
	local p = b.queue[pid]
	b.queue[pid] = nil
	local d = { status = status, by = self:PlayerName(), at = GetServerTime(), reason = reason,
		eid = eid or (p and p.eid), author = p and p.author }
	b.decided[pid] = d
	self:Send("QDEC", { pid = pid, s = status, r = reason, e = d.eid, a = d.author }, "GUILD", nil, "NORMAL")
	self:SendMessage("FRONTIERSCOUT_QUEUE_CHANGED")
	return d
end

-- Approves a queued proposal: applies it (rev+1), pushes APPR, records the
-- decision. Returns the entry (or tombstone), or nil and an error code; a
-- proposal that can no longer apply is rejected with the reason.
function FS:Approve(pid)
	if not self.store or not self:AmArchivist() then return nil, "denied" end
	local p = lists(self).queue[pid]
	if not p then return nil, "missing" end
	local ok, why = self:ProposalAllowed(p)
	if not ok then
		decide(self, pid, "rejected", L["No longer valid: %s"]:format(why))
		return nil, why
	end
	local ctx = { id = p.eid, by = p.author, now = GetServerTime(), approvedBy = self:PlayerName() }
	local result, err
	if p.op == "create" then
		result, err = self.store:Create(p.data, ctx)
	elseif p.op == "edit" then
		result, err = self.store:Update(p.eid, p.data, ctx)
	elseif p.op == "delete" then
		result, err = self.store:Delete(p.eid, ctx)
	else
		result = self.store:Get(p.eid) -- a report resolved as "still valid"
	end
	if not result then
		decide(self, pid, "rejected", L["No longer valid: %s"]:format(err))
		return nil, err
	end
	decide(self, pid, "approved", nil, p.eid)
	if p.op ~= "report" then
		self:SendMessage("FRONTIERSCOUT_ENTRIES_CHANGED", p.eid)
		self:Send("APPR", { e = result }, "GUILD", nil, "NORMAL")
	end
	return result
end

function FS:Reject(pid, reason)
	if not self.store or not self:AmArchivist() then return nil, "denied" end
	if not lists(self).queue[pid] then return nil, "missing" end
	reason = Format.Sanitize(reason or "", Review.MAX_REASON)
	return decide(self, pid, "rejected", reason ~= "" and reason or nil)
end

-- Sorted views for the UI.
function FS:QueueList()
	local list = {}
	for _, p in pairs(self.store and lists(self).queue or {}) do list[#list + 1] = p end
	table.sort(list, function(a, b)
		if a.at ~= b.at then return a.at < b.at end
		return a.pid < b.pid
	end)
	return list
end

function FS:MySubmissions()
	local list = {}
	for pid, s in pairs(self.store and lists(self).mine or {}) do
		list[#list + 1] = { pid = pid, op = s.op, eid = s.eid, at = s.at, status = s.status, title = s.title, reason = s.reason }
	end
	table.sort(list, function(a, b)
		if a.at ~= b.at then return a.at > b.at end
		return a.pid > b.pid
	end)
	return list
end

-- Drops finished submissions from "My submissions".
function FS:ClearFinished()
	local mine = lists(self).mine
	for pid, s in pairs(mine) do
		if s.status == "approved" or s.status == "rejected" then mine[pid] = nil end
	end
	self:SendMessage("FRONTIERSCOUT_PROPOSALS_CHANGED")
end

-- Handlers -------------------------------------------------------------------------------

-- Adds a valid proposal to the queue. Returns true when it is (now) queued or
-- already decided, so the sender can stop resending.
local function enqueue(self, raw, from)
	local p = Review.ValidateProposal(raw)
	if not p then return false end
	local b = lists(self)
	if b.decided[p.pid] then return true, b.decided[p.pid] end
	if b.queue[p.pid] then return true end
	if from and p.author ~= from then return false end -- only your own proposals
	local ok, why = self:ProposalAllowed(p)
	if not ok then
		self:Debug("dropped proposal %s from %s: %s", p.pid, tostring(from), why)
		return false
	end
	local n = 0
	for _ in pairs(b.queue) do n = n + 1 end
	if n >= Review.MAX_QUEUE then return false end
	b.queue[p.pid] = p
	self:SendMessage("FRONTIERSCOUT_QUEUE_CHANGED")
	return true
end

FS:OnMessageType("PROP", function(self, msg, sender)
	if not self.store or not self:AmArchivist() then return end
	local ok, decision = enqueue(self, msg.p, sender)
	if not ok then return end
	self:Send("PACK", { pid = msg.p.pid }, "WHISPER", sender, "ALERT")
	if decision then
		self:Send("QDEC", { pid = msg.p.pid, s = decision.status, r = decision.reason, e = decision.eid, a = decision.author },
			"WHISPER", sender, "ALERT")
	end
end)

FS:OnMessageType("PACK", function(self, msg, sender)
	if not self.store or not self:IsArchivist(sender) or type(msg.pid) ~= "string" then return end
	local b = lists(self)
	if b.outbox[msg.pid] then
		b.outbox[msg.pid] = nil
		if b.mine[msg.pid] and b.mine[msg.pid].status == "waiting" then b.mine[msg.pid].status = "queued" end
		self:SendMessage("FRONTIERSCOUT_PROPOSALS_CHANGED")
	end
end)

local function applyDecision(self, pid, d)
	local b = lists(self)
	if b.queue[pid] then
		b.queue[pid] = nil
		self:SendMessage("FRONTIERSCOUT_QUEUE_CHANGED")
	end
	if self:AmArchivist() and not b.decided[pid] then b.decided[pid] = d end
	local mine = b.mine[pid]
	b.outbox[pid] = nil
	if mine and mine.status ~= d.status then
		mine.status, mine.reason = d.status, d.reason
		self:SendMessage("FRONTIERSCOUT_PROPOSALS_CHANGED")
		if d.status == "rejected" then
			self:Print(L["Your submission \"%s\" was rejected: %s"]:format(mine.title, d.reason or L["no reason given"]))
		else
			self:Print(L["Your submission \"%s\" was approved."]:format(mine.title))
		end
	end
end

FS:OnMessageType("QDEC", function(self, msg, sender)
	if not self.store or not self:IsArchivist(sender) or type(msg.pid) ~= "string" then return end
	if msg.s ~= "approved" and msg.s ~= "rejected" then return end
	local reason = Format.Sanitize(msg.r or "", Review.MAX_REASON)
	applyDecision(self, msg.pid, {
		status = msg.s, by = sender, at = GetServerTime(), reason = reason ~= "" and reason or nil,
		eid = type(msg.e) == "string" and msg.e or nil, author = name(msg.a),
	})
end)

-- Archivists share their queue and recent decisions with each other.
local function sendQueue(self, archivist)
	local b = lists(self)
	local q, d = {}, {}
	for pid, p in pairs(b.queue) do q[pid] = p end
	for pid, dec in pairs(b.decided) do d[pid] = { s = dec.status, r = dec.reason, e = dec.eid, a = dec.author } end
	self:Send("QSYNC", { q = q, d = d }, "WHISPER", archivist, "BULK")
end

FS:OnMessageType("QSYNC", function(self, msg, sender)
	if not self.store or not self:AmArchivist() or not self:IsArchivist(sender) then return end
	if type(msg.d) == "table" then
		for pid, dec in pairs(msg.d) do
			if type(pid) == "string" and type(dec) == "table" and (dec.s == "approved" or dec.s == "rejected") then
				applyDecision(self, pid, { status = dec.s, by = sender, at = GetServerTime(),
					reason = type(dec.r) == "string" and Format.Sanitize(dec.r, Review.MAX_REASON) or nil,
					eid = type(dec.e) == "string" and dec.e or nil, author = name(dec.a) })
			end
		end
	end
	if type(msg.q) == "table" then
		for _, p in pairs(msg.q) do enqueue(self, p, nil) end
	end
end)

-- An archivist meeting another archivist swaps queues; meeting a member,
-- it re-sends decisions on that member's proposals (they may have been offline).
FS:OnMessageType("HELLO", function(self, msg, sender)
	if not self.store or not self:AmArchivist() then return end
	if msg.role == "A" and self:IsArchivist(sender) then
		sendQueue(self, sender)
		return
	end
	for pid, d in pairs(lists(self).decided) do
		if d.author == sender then
			self:Send("QDEC", { pid = pid, s = d.status, r = d.reason, e = d.eid, a = d.author }, "WHISPER", sender, "NORMAL")
		end
	end
end)

FS:OnMessageType("ARCH", function(self, _, sender)
	if not self.store or not self:IsArchivist(sender) then return end
	if self:AmArchivist() then sendQueue(self, sender) end
	self:FlushOutbox()
end)

FS:Listen("FRONTIERSCOUT_ROSTER_UPDATED", function() FS:FlushOutbox() end)

-- Old decisions expire so the lists don't grow forever.
FS:Listen("FRONTIERSCOUT_GUILD_CHANGED", function()
	if not FS.store then return end
	local now, decided = GetServerTime(), lists(FS).decided
	for pid, d in pairs(decided) do
		if now - (d.at or 0) > Review.DECISION_TTL then decided[pid] = nil end
	end
end)
