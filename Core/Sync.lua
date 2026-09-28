local _, ns = ...

-- Dataset sync (docs/SPEC.md §6): archivists are the source of truth.
--   HELLO (guild)        any -> all        after login, announces root/count/role
--   ARCH  (whisper/guild) archivist        answer to HELLO, and a 10-minute beacon
--   SYNCREQ -> MANIFEST -> WANT -> ENT     pull of differing buckets from one archivist
--   APPR  (guild)        archivist -> all  live push of a new canonical revision
--   BUSY  (whisper)      archivist         already serving two clients; retry later
-- Canonical data (ARCH, MANIFEST, ENT, APPR) is only accepted from players who
-- pass the archivist check (§4.4); archivists pull from each other the same way.
local FS, L = ns.FS, ns.L

local HELLO_DELAY_MIN, HELLO_DELAY_MAX = 15, 45
local BEACON_INTERVAL = 600
local SESSION_TIMEOUT = 120
local RETRY_DELAY = 60
local MAX_SERVING = 2
local ENT_BATCH = 20
local WANT_CHUNK = 100
local HELLO_THROTTLE = 30
local MANIFEST_TIMEOUT = 30 -- no manifest by then: ask for the guild channel next time

local sync = {
	archivists = {}, -- name -> { root, count, seen }
	guildFrom = {},  -- archivist -> true: their whispers don't reach us
	gotManifest = false,
	serving = {},    -- member name -> last activity (archivist side)
	lastHello = nil,
}

local function now() return GetTime() end

local function digest(self) return self.store.digest end

local function syncState(self)
	local bucket = self.store.bucket
	bucket.syncState = bucket.syncState or {}
	return bucket.syncState
end

local function after(delay, fn)
	if C_Timer then C_Timer.After(delay, fn) end
end

-- Trust --------------------------------------------------------------------------

local warned = {}

-- Does `sender` pass the archivist check? Officers who can read officer notes
-- get a warning when an untagged officer-rank player serves data (SPEC §4.4).
local function trusted(self, sender, what)
	if self:IsArchivist(sender) then return true end
	local member = self:Member(sender)
	self:Debug("ignored %s from %s: not an archivist for this client (in roster: %s, rank: %s, {FS:A} seen: %s, can read officer notes: %s, archivist rank: %s)",
		what, sender, tostring(member ~= nil), tostring(member and member.rankIndex), tostring(member and member.officerNoteHasTag),
		tostring(self:CanViewOfficerNotes()), tostring(self.acl.ar))
	if member and self:CanViewOfficerNotes() and ns.ACL.Can(self.acl, "ar", member.rankIndex) and not warned[sender] then
		warned[sender] = true
		self:Warn(L["%s sent %s but has no {FS:A} officer-note tag; ignored."], Ambiguate(sender, "guild"), what)
	end
	return false
end

function FS:Warn(fmt, ...)
	if not self.store then return end
	local b = self.store.bucket
	b.warnings = b.warnings or {}
	table.insert(b.warnings, date("%m-%d %H:%M ") .. fmt:format(...))
	while #b.warnings > 20 do table.remove(b.warnings, 1) end
	self:Debug(fmt, ...)
end

function FS:Warnings()
	return self.store and self.store.bucket.warnings or {}
end

-- Pulling ------------------------------------------------------------------------

local function finishPull(self, ok)
	if ok and self.store then
		syncState(self).lastFullSync = GetServerTime()
		self:Debug("sync complete with %s", tostring(self.syncPartner))
		self:SendMessage("FRONTIERSCOUT_SYNC_DONE", self.syncPartner)
	end
	self.syncPartner, sync.partnerAt, sync.wanted = nil, nil, nil
end

-- Starts pulling from `archivist` unless a pull is already running. A pull
-- whose manifest never came (the archivist's whispers don't reach us) is
-- retried asking for everything over the guild channel (`gc`).
local function startPull(self, archivist)
	if not self.store or ns.Comm.Paused() then return end
	if self.syncPartner then
		local waited = now() - sync.partnerAt
		if not sync.gotManifest and waited >= MANIFEST_TIMEOUT then
			sync.guildFrom[self.syncPartner] = true
		elseif waited < SESSION_TIMEOUT then
			return
		end
	end
	self.syncPartner, sync.partnerAt, sync.gotManifest = archivist, now(), false
	self:Send("SYNCREQ", { b = digest(self):Buckets(), gc = sync.guildFrom[archivist] or nil }, "WHISPER", archivist, "ALERT")
end

-- An online archivist whose root differs from ours, other than `except`.
local function otherArchivist(self, except)
	local root = digest(self):Root()
	for name, info in pairs(sync.archivists) do
		if name ~= except and info.root ~= root and now() - info.seen < BEACON_INTERVAL and self:IsArchivist(name) then
			return name
		end
	end
end

-- Announcing ------------------------------------------------------------------------

function FS:SayHello(force)
	if not self.store then return false end
	if not force and sync.lastHello and now() - sync.lastHello < HELLO_THROTTLE then return false end
	sync.lastHello = now()
	local d = digest(self)
	self:Send("HELLO", {
		root = d:Root(),
		count = d.count,
		role = self:AmArchivist() and "A" or "M",
		open = self.OpenProposals and self:OpenProposals() or nil,
	}, "GUILD", nil, "ALERT")
	return true
end

local function beacon(self, channel, target)
	local d = digest(self)
	self:Send("ARCH", { root = d:Root(), count = d.count }, channel, target, "ALERT")
end

-- Handlers ---------------------------------------------------------------------------

FS:OnMessageType("HELLO", function(self, msg, sender)
	if not self.store or not self:AmArchivist() then return end
	beacon(self, "WHISPER", sender)
	-- Another archivist with different data: pull theirs too, so we converge.
	if msg.role == "A" and msg.root ~= digest(self):Root() and self:IsArchivist(sender) then
		sync.archivists[sender] = { root = msg.root, count = msg.count, seen = now() }
		startPull(self, sender)
	end
end)

FS:OnMessageType("ARCH", function(self, msg, sender)
	if not self.store or not trusted(self, sender, "ARCH") then return end
	sync.archivists[sender] = { root = msg.root, count = tonumber(msg.count) or 0, seen = now() }
	if msg.root ~= digest(self):Root() then startPull(self, sender) end
end)

FS:OnMessageType("SYNCREQ", function(self, msg, sender)
	if not self.store or not self:AmArchivist() or type(msg.b) ~= "table" then return end
	if msg.gc then self:PreferGuild(sender) end
	for name, t in pairs(sync.serving) do
		if now() - t > SESSION_TIMEOUT then sync.serving[name] = nil end
	end
	local busy = 0
	for _ in pairs(sync.serving) do busy = busy + 1 end
	if busy >= MAX_SERVING and not sync.serving[sender] then
		self:Send("BUSY", {}, "WHISPER", sender, "ALERT")
		return
	end
	local diff = digest(self):Diff(msg.b)
	sync.serving[sender] = #diff > 0 and now() or nil
	self:Send("MANIFEST", { m = digest(self):Manifest(diff) }, "WHISPER", sender, "BULK")
end)

FS:OnMessageType("MANIFEST", function(self, msg, sender)
	if not self.store or sender ~= self.syncPartner or type(msg.m) ~= "table" then return end
	if not trusted(self, sender, "MANIFEST") then return end
	sync.gotManifest = true
	local stale = self.store:Stale(msg.m, GetServerTime())
	for _, id in ipairs(stale) do self.store:Forget(id) end
	if #stale > 0 then self:SendMessage("FRONTIERSCOUT_ENTRIES_CHANGED") end
	local want = digest(self):Wanted(msg.m)
	if #want == 0 then
		finishPull(self, true)
		return
	end
	sync.partnerAt = now()
	for i = 1, #want, WANT_CHUNK do
		local ids = {}
		for j = i, math.min(i + WANT_CHUNK - 1, #want) do ids[#ids + 1] = want[j] end
		self:Send("WANT", { ids = ids, last = i + WANT_CHUNK > #want or nil }, "WHISPER", sender, "ALERT")
	end
end)

FS:OnMessageType("WANT", function(self, msg, sender)
	if not self.store or not self:AmArchivist() or not sync.serving[sender] or type(msg.ids) ~= "table" then return end
	sync.serving[sender] = now()
	local batch = {}
	local function flush(done)
		self:Send("ENT", { e = batch, done = done or nil }, "WHISPER", sender, "BULK")
		batch = {}
	end
	for _, id in ipairs(msg.ids) do
		local e = type(id) == "string" and self.store:GetAny(id)
		if e then
			batch[#batch + 1] = e
			if #batch >= ENT_BATCH then flush(false) end
		end
	end
	if msg.last then
		flush(true)
		sync.serving[sender] = nil
	elseif #batch > 0 then
		flush(false)
	end
end)

-- Applies canonical entries from an archivist; returns how many were new.
-- Announces entries that are new here (not edits or deletions) with
-- FRONTIERSCOUT_ENTRIES_RECEIVED, for notifications.
local function applyAll(self, list)
	local applied, fresh = 0, {}
	for _, e in ipairs(list) do
		local existed = type(e) == "table" and self.store:Get(e.id) ~= nil
		local stored = self.store:Apply(e)
		if stored then
			applied = applied + 1
			if not existed and not stored.deleted then fresh[#fresh + 1] = stored end
		end
	end
	if applied > 0 then self:SendMessage("FRONTIERSCOUT_ENTRIES_CHANGED") end
	if #fresh > 0 then self:SendMessage("FRONTIERSCOUT_ENTRIES_RECEIVED", fresh) end
	return applied
end

FS:OnMessageType("ENT", function(self, msg, sender)
	if not self.store or type(msg.e) ~= "table" or not trusted(self, sender, "ENT") then return end
	applyAll(self, msg.e)
	if sender == self.syncPartner then
		sync.partnerAt = now()
		if msg.done then finishPull(self, true) end
	end
end)

FS:OnMessageType("APPR", function(self, msg, sender)
	if not self.store or type(msg.e) ~= "table" or not trusted(self, sender, "APPR") then return end
	applyAll(self, { msg.e })
end)

FS:OnMessageType("BUSY", function(self, _, sender)
	if sender ~= self.syncPartner then return end
	finishPull(self, false)
	local other = otherArchivist(self, sender)
	if other then
		startPull(self, other)
	else
		after(RETRY_DELAY + math.random(0, 30), function()
			local info = sync.archivists[sender]
			if info and self.store and info.root ~= digest(self):Root() then startPull(self, sender) end
		end)
	end
end)

-- Archivists push their own writes right away (non-archivist writes become
-- proposals in M5).
FS:Listen("FRONTIERSCOUT_LOCAL_WRITE", function(entry)
	if FS.store and FS:AmArchivist() then
		FS:Send("APPR", { e = entry }, "GUILD", nil, "NORMAL")
	end
end)

-- Lifecycle ---------------------------------------------------------------------------

local function reset()
	wipe(warned)
	wipe(sync.archivists)
	wipe(sync.serving)
	wipe(sync.guildFrom)
	sync.lastHello, sync.gotManifest = nil, false
	FS.syncPartner, sync.partnerAt, sync.wanted = nil, nil, nil
end

FS:Listen("FRONTIERSCOUT_GUILD_CHANGED", function(key)
	reset()
	if key then
		after(HELLO_DELAY_MIN + math.random() * (HELLO_DELAY_MAX - HELLO_DELAY_MIN), function() FS:SayHello() end)
	end
end)

-- After combat or leaving an instance, catch up with anything we missed.
FS:Listen("FRONTIERSCOUT_SYNC_RESUMED", function()
	local other = FS.store and otherArchivist(FS)
	if other then startPull(FS, other) end
end)

FS:OnEnableHook(function()
	if C_Timer then
		C_Timer.NewTicker(BEACON_INTERVAL, function()
			if FS.store and FS:AmArchivist() and not ns.Comm.Paused() then beacon(FS, "GUILD") end
		end)
	end
end)

-- Archivists that answered or announced themselves recently (so are online).
function FS:SeenArchivists()
	local list = {}
	for name, info in pairs(sync.archivists) do
		if now() - info.seen < BEACON_INTERVAL + 60 and self:IsArchivist(name) then list[#list + 1] = name end
	end
	table.sort(list)
	return list
end

-- Status for /fs status and the browser.
function FS:SyncStatus()
	local online = {}
	for name, info in pairs(sync.archivists) do
		if now() - info.seen < BEACON_INTERVAL + 60 then online[#online + 1] = name end
	end
	table.sort(online)
	local state = self.store and syncState(self) or {}
	return {
		lastFullSync = state.lastFullSync,
		archivists = online,
		root = self.store and digest(self):Root(),
		count = self.store and digest(self).count or 0,
		syncing = self.syncPartner,
	}
end

-- /fs sync
function FS:SyncNow()
	if not self:GetStore() then return end
	if ns.Comm.Paused() then
		self:Print(L["Sync is paused in combat and instances."])
	elseif self:SayHello(true) then
		self:Print(L["Looking for archivists..."])
	end
end
