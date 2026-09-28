local _, ns = ...

-- Discovery entries of one guild bucket (docs/SPEC.md §5). Pure Lua, no WoW API:
-- callers pass who/when in a context table { id = , by = , now = }.
local Categories, Format, Digest = ns.Categories, ns.Format, ns.Digest

local Store = {}
Store.__index = Store
ns.Store = Store

Store.MAX_ENTRIES = 5000
Store.MAX_TITLE = 64
Store.MAX_DESC = 500
Store.MAX_TAGS = 5
Store.MAX_TAG = 16
Store.MAX_ITEMS = 50
Store.MAX_COST = 64
Store.MAX_WINDOW = 32
Store.MAX_NOTE = 100
Store.TOMBSTONE_TTL = 90 * 24 * 3600

local function posInt(v)
	v = tonumber(v)
	if v and v > 0 and v % 1 == 0 and v < 2 ^ 31 then return v end
end

local function round4(v)
	return math.floor(v * 10000 + 0.5) / 10000
end

local function unit(v)
	v = tonumber(v)
	if v and v == v and v >= 0 and v <= 1 then return round4(v) end
end

local function cleanItems(list)
	if type(list) ~= "table" then return nil end
	local items, seen = {}, {}
	for _, item in ipairs(list) do
		local id = type(item) == "table" and posInt(item.id)
		if id and not seen[id] and #items < Store.MAX_ITEMS then
			seen[id] = true
			local cost = Format.Sanitize(item.cost, Store.MAX_COST)
			items[#items + 1] = { id = id, cost = cost ~= "" and cost or nil }
		end
	end
	return #items > 0 and items or nil
end

local function cleanSchedule(s)
	if type(s) ~= "table" then return nil end
	local respawn = tonumber(s.respawnMin)
	respawn = respawn and respawn >= 0 and math.floor(respawn + 0.5) or nil
	local window = Format.Sanitize(s.window, Store.MAX_WINDOW)
	local note = Format.Sanitize(s.note, Store.MAX_NOTE)
	local clean = {
		respawnMin = respawn,
		window = window ~= "" and window or nil,
		note = note ~= "" and note or nil,
	}
	return next(clean) and clean or nil
end

local function cleanTags(list)
	if type(list) ~= "table" then return nil end
	local tags, seen = {}, {}
	for _, tag in ipairs(list) do
		tag = Format.Sanitize(tag, Store.MAX_TAG)
		if tag and tag ~= "" and not seen[tag:lower()] and #tags < Store.MAX_TAGS then
			seen[tag:lower()] = true
			tags[#tags + 1] = tag
		end
	end
	return #tags > 0 and tags or nil
end

-- Validates and normalizes the user-editable part of an entry.
-- Returns a new table, or nil and an error code:
-- "category", "title", "map", "position", "npcID".
function Store.Validate(data)
	if type(data) ~= "table" then return nil, "invalid" end
	if not Categories.IsValid(data.cat, data.sub) then return nil, "category" end

	local title = Format.Sanitize(data.title, Store.MAX_TITLE)
	if not title or title == "" then return nil, "title" end

	local map = posInt(data.map)
	if not map then return nil, "map" end
	local x, y = unit(data.x), unit(data.y)
	if not x or not y then return nil, "position" end

	local npcID
	if data.npcID ~= nil and data.npcID ~= "" then
		npcID = posInt(data.npcID)
		if not npcID then return nil, "npcID" end
	end

	local desc = Format.Sanitize(data.desc, Store.MAX_DESC, { links = true, multiline = true })
	return {
		cat = data.cat,
		sub = data.sub,
		title = title,
		desc = (desc and desc ~= "") and desc or nil,
		map = map,
		x = x,
		y = y,
		npcID = npcID,
		items = cleanItems(data.items),
		schedule = cleanSchedule(data.schedule),
		tags = cleanTags(data.tags),
	}
end

-- "E-<guid suffix>-<serverTime>-<n>" (SPEC §5.1); the prefix is "P" for proposals.
function Store.MakeId(prefix, guid, now, n)
	local suffix = type(guid) == "string" and guid:match("([^%-]+)$") or "0"
	return ("%s-%s-%d-%d"):format(prefix, suffix, now, n)
end

function Store.New(bucket)
	bucket.entries = bucket.entries or {}
	return setmetatable({ bucket = bucket, digest = Digest.New(bucket.entries) }, Store)
end

-- Conflict rule (SPEC §6.2): higher rev, then later approvedAt, then the
-- lexically greater approvedBy wins. Is `a` newer than `b`?
function Store.Newer(a, b)
	if not b then return true end
	if a.rev ~= b.rev then return a.rev > b.rev end
	if a.approvedAt ~= b.approvedAt then return a.approvedAt > b.approvedAt end
	return (a.approvedBy or "") > (b.approvedBy or "")
end

local function put(self, e)
	self.bucket.entries[e.id] = e
	self.digest:Set(e)
end

-- Validates a canonical entry received from another client: content for
-- live entries, provenance for all. Returns a clean copy or nil, error.
function Store.ValidateRemote(e)
	if type(e) ~= "table" or type(e.id) ~= "string" or #e.id > 64 then return nil, "invalid" end
	local rev, at = tonumber(e.rev), tonumber(e.approvedAt)
	if not rev or rev < 1 or rev % 1 ~= 0 or not at then return nil, "invalid" end
	local function name(v) return type(v) == "string" and #v <= 64 and v or nil end
	local clean
	if e.deleted then
		clean = { deleted = true }
	else
		local err
		clean, err = Store.Validate(e)
		if not clean then return nil, err end
		local flags = tonumber(e.flags)
		clean.flags = flags and flags > 0 and math.floor(flags) or nil
	end
	clean.id = e.id
	clean.rev = rev
	clean.approvedAt = at
	clean.createdAt = tonumber(e.createdAt)
	clean.author = name(e.author)
	clean.editedBy = name(e.editedBy)
	clean.approvedBy = name(e.approvedBy)
	return clean
end

-- Applies a canonical entry from another client when it is newer than ours
-- (tombstones included). Returns the stored entry, or nil and a reason:
-- Validate's codes, "invalid", "old", "full".
function Store:Apply(e)
	local clean, err = Store.ValidateRemote(e)
	if not clean then return nil, err end
	local cur = self.bucket.entries[clean.id]
	if cur and not Store.Newer(clean, cur) then return nil, "old" end
	if not cur and not clean.deleted and self:Count() >= Store.MAX_ENTRIES then return nil, "full" end
	put(self, clean)
	return clean
end

-- Local ids in `buckets` (a remote manifest) that the remote side doesn't
-- have and that are older than the tombstone lifetime: their deletion was
-- already garbage-collected elsewhere, so they are stale here.
function Store:Stale(manifest, now)
	local stale = {}
	for id, e in pairs(self.bucket.entries) do
		local b = Digest.BucketOf(id)
		local remote = manifest[b]
		if type(remote) == "table" and remote[id] == nil and now - (e.approvedAt or 0) > Store.TOMBSTONE_TTL then
			stale[#stale + 1] = id
		end
	end
	return stale
end

function Store:Forget(id)
	self.bucket.entries[id] = nil
	self.digest:Remove(id)
end

-- Raw entry or tombstone, for sync.
function Store:GetAny(id)
	return self.bucket.entries[id]
end

-- Live (non-deleted) entry by id.
function Store:Get(id)
	local e = self.bucket.entries[id]
	if e and not e.deleted then return e end
end

-- Array of live entries, in no particular order.
function Store:All()
	local list = {}
	for _, e in pairs(self.bucket.entries) do
		if not e.deleted then list[#list + 1] = e end
	end
	return list
end

function Store:Count()
	local n = 0
	for _, e in pairs(self.bucket.entries) do
		if not e.deleted then n = n + 1 end
	end
	return n
end

-- Adds a new approved entry. Returns it, or nil and an error code
-- (Validate's, or "exists", "full").
function Store:Create(data, ctx)
	if self.bucket.entries[ctx.id] then return nil, "exists" end
	if self:Count() >= Store.MAX_ENTRIES then return nil, "full" end
	local e, err = Store.Validate(data)
	if not e then return nil, err end
	e.id = ctx.id
	e.author = ctx.by
	e.createdAt = ctx.now
	e.rev = 1
	e.editedBy = ctx.by
	e.approvedBy = ctx.approvedBy or ctx.by
	e.approvedAt = ctx.now
	put(self, e)
	return e
end

-- Replaces the content of an entry (full data, so cleared fields go away) and
-- bumps its revision. Returns the new entry, or nil and an error code.
function Store:Update(id, data, ctx)
	local old = self:Get(id)
	if not old then return nil, "missing" end
	local e, err = Store.Validate(data)
	if not e then return nil, err end
	e.id = id
	e.author = old.author
	e.createdAt = old.createdAt
	e.rev = old.rev + 1
	e.editedBy = ctx.by
	e.approvedBy = ctx.approvedBy or ctx.by
	e.approvedAt = ctx.now
	e.flags = old.flags
	put(self, e)
	return e
end

-- Replaces an entry with a tombstone so the deletion can propagate (SPEC §5.4).
function Store:Delete(id, ctx)
	local old = self:Get(id)
	if not old then return nil, "missing" end
	local t = {
		id = id,
		deleted = true,
		author = old.author,
		createdAt = old.createdAt,
		rev = old.rev + 1,
		editedBy = ctx.by,
		approvedBy = ctx.approvedBy or ctx.by,
		approvedAt = ctx.now,
	}
	put(self, t)
	return t
end

-- Drops tombstones older than TOMBSTONE_TTL. Returns how many were removed.
function Store:CollectGarbage(now)
	local removed = 0
	for id, e in pairs(self.bucket.entries) do
		if e.deleted and now - (e.approvedAt or 0) > Store.TOMBSTONE_TTL then
			self.bucket.entries[id] = nil
			self.digest:Remove(id)
			removed = removed + 1
		end
	end
	return removed
end

-- WoW side -----------------------------------------------------------------

local FS = ns.FS

local function context(self)
	local global = self.db.global
	global.idSeq = (global.idSeq or 0) + 1
	local now = GetServerTime()
	return {
		id = Store.MakeId("E", UnitGUID("player"), now, global.idSeq),
		by = self:PlayerName(),
		now = now,
	}
end

-- Creates (id == nil) or updates an entry in the active guild. Until curation
-- arrives (M5) every write is applied locally and approved by its writer.
-- Returns the entry, or nil and an error code.
function FS:SaveEntry(id, data)
	local store = self:GetStore()
	if not store then return nil, "noguild" end
	if not self:Can(id and "edit" or "create", id and store:Get(id)) then return nil, "denied" end
	local ctx = context(self)
	local entry, err
	if id then
		entry, err = store:Update(id, data, ctx)
	else
		entry, err = store:Create(data, ctx)
	end
	if entry then
		self:SendMessage("FRONTIERSCOUT_ENTRIES_CHANGED", entry.id)
		self:SendMessage("FRONTIERSCOUT_LOCAL_WRITE", entry)
	end
	return entry, err
end

function FS:DeleteEntry(id)
	local store = self:GetStore()
	if not store then return nil, "noguild" end
	if not self:Can("delete", store:Get(id)) then return nil, "denied" end
	local t, err = store:Delete(id, context(self))
	if t then
		self:SendMessage("FRONTIERSCOUT_ENTRIES_CHANGED", id)
		self:SendMessage("FRONTIERSCOUT_LOCAL_WRITE", t)
	end
	return t, err
end
