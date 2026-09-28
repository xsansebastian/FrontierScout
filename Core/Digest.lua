local _, ns = ...

-- Dataset digest (docs/SPEC.md §6.2): entries hash into 64 buckets by
-- fnv1a32(id) % 64; a bucket's hash is FNV-1a over its sorted
-- "id:rev:approvedAt" lines; the root is FNV-1a over the 64 bucket hashes.
-- Pure Lua; uses WoW's `bit` library when present.
local Digest = {}
Digest.__index = Digest
ns.Digest = Digest

Digest.BUCKETS = 64

local OFFSET, PRIME_LOW = 2166136261, 403 -- FNV prime = 2^24 + 403
local TWO32, TWO24 = 4294967296, 16777216

-- XOR of two bytes without the bit library.
local function xor8(a, b)
	local r, p = 0, 1
	for _ = 1, 8 do
		local ab, bb = a % 2, b % 2
		if ab ~= bb then r = r + p end
		a, b, p = (a - ab) / 2, (b - bb) / 2, p * 2
	end
	return r
end

local function fnvArith(s)
	local h = OFFSET
	for i = 1, #s do
		local low = h % 256
		h = h - low + xor8(low, s:byte(i))
		-- h * (2^24 + 403) mod 2^32, exact in doubles
		h = ((h % 256) * TWO24 + h * PRIME_LOW) % TWO32
	end
	return h
end

local function fnvBit(s)
	local bxor = bit.bxor
	local h = OFFSET
	for i = 1, #s do
		h = bxor(h, s:byte(i)) % TWO32
		h = ((h % 256) * TWO24 + h * PRIME_LOW) % TWO32
	end
	return h
end

Digest.fnvArith = fnvArith

-- FNV-1a 32-bit of a string, as a number in [0, 2^32).
function Digest.fnv1a(s)
	if bit and bit.bxor then return fnvBit(s) end
	return fnvArith(s)
end

function Digest.BucketOf(id)
	return Digest.fnv1a(id) % Digest.BUCKETS
end

-- The version of an entry as the digest and manifests see it.
function Digest.Version(e)
	return ("%d:%d"):format(e.rev or 0, e.approvedAt or 0)
end

-- Is version string `a` ("rev:approvedAt") newer than `b` (nil = missing)?
function Digest.VersionNewer(a, b)
	if not b then return true end
	local ra, ta = a:match("^(%d+):(%d+)$")
	local rb, tb = b:match("^(%d+):(%d+)$")
	ra, ta, rb, tb = tonumber(ra), tonumber(ta), tonumber(rb), tonumber(tb)
	if not ra or not rb then return false end
	if ra ~= rb then return ra > rb end
	return ta > tb
end

-- New digest over a table of entries (id -> entry, tombstones included).
function Digest.New(entries)
	local d = setmetatable({ lines = {}, hashes = {}, dirty = {}, count = 0 }, Digest)
	for b = 0, Digest.BUCKETS - 1 do
		d.lines[b] = {}
		d.hashes[b] = 0
	end
	for _, e in pairs(entries or {}) do d:Set(e) end
	return d
end

function Digest:Set(e)
	local b = Digest.BucketOf(e.id)
	if not self.lines[b][e.id] then self.count = self.count + 1 end
	self.lines[b][e.id] = Digest.Version(e)
	self.dirty[b] = true
	self.root = nil
end

function Digest:Remove(id)
	local b = Digest.BucketOf(id)
	if self.lines[b][id] then
		self.lines[b][id] = nil
		self.count = self.count - 1
		self.dirty[b] = true
		self.root = nil
	end
end

local function bucketHash(lines)
	local ids = {}
	for id in pairs(lines) do ids[#ids + 1] = id end
	if #ids == 0 then return 0 end
	table.sort(ids)
	for i, id in ipairs(ids) do ids[i] = id .. ":" .. lines[id] end
	return Digest.fnv1a(table.concat(ids, "\n"))
end

-- Array of the 64 bucket hashes (index 1 = bucket 0).
function Digest:Buckets()
	for b in pairs(self.dirty) do
		self.hashes[b] = bucketHash(self.lines[b])
		self.dirty[b] = nil
	end
	local list = {}
	for b = 0, Digest.BUCKETS - 1 do list[b + 1] = self.hashes[b] end
	return list
end

function Digest:Root()
	if not self.root then
		local parts = {}
		for i, h in ipairs(self:Buckets()) do parts[i] = ("%08x"):format(h) end
		self.root = Digest.fnv1a(table.concat(parts))
	end
	return self.root
end

-- Bucket numbers whose hash differs from `remote` (array like Buckets()).
function Digest:Diff(remote)
	local mine, diff = self:Buckets(), {}
	for i = 1, Digest.BUCKETS do
		if type(remote) ~= "table" or mine[i] ~= remote[i] then diff[#diff + 1] = i - 1 end
	end
	return diff
end

-- { [bucket] = { [id] = version } } for the given buckets.
function Digest:Manifest(buckets)
	local m = {}
	for _, b in ipairs(buckets) do
		if self.lines[b] then
			local copy = {}
			for id, v in pairs(self.lines[b]) do copy[id] = v end
			m[b] = copy
		end
	end
	return m
end

-- Ids in a remote manifest that are missing here or newer there.
function Digest:Wanted(manifest)
	local want = {}
	for b, lines in pairs(manifest) do
		local mine = self.lines[b]
		if type(lines) == "table" and mine then
			for id, v in pairs(lines) do
				if type(id) == "string" and type(v) == "string" and Digest.VersionNewer(v, mine[id]) then
					want[#want + 1] = id
				end
			end
		end
	end
	table.sort(want)
	return want
end
