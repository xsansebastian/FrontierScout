local wow = require("tests.helpers.wow")

local Store, Digest
setup(function()
	local _, _, ns = wow.boot()
	Store, Digest = ns.Store, ns.Digest
end)

-- Root of a digest rebuilt from scratch, to check incremental upkeep.
local function ns_digest_root(store)
	return Digest.New(store.bucket.entries):Root()
end

local function data(over)
	local d = { cat = "npc", sub = "rare", title = "Old Grizzlegut", map = 1433, x = 0.45678, y = 0.1 }
	for k, v in pairs(over or {}) do d[k] = v end
	return d
end

local function ctx(id, now, by)
	return { id = id or "E-1", now = now or 1000, by = by or "Scout-Realm" }
end

describe("Store.Validate", function()
	it("normalizes a minimal entry", function()
		local e = Store.Validate(data())
		assert.same({ cat = "npc", sub = "rare", title = "Old Grizzlegut", map = 1433, x = 0.4568, y = 0.1 }, e)
	end)

	it("rejects bad categories, titles, maps and positions", function()
		local cases = {
			{ { cat = "route" }, "category" },
			{ { sub = "treasure" }, "category" },
			{ { title = "   " }, "title" },
			{ { title = "|cffff0000|r" }, "title" },
			{ { map = 0 }, "map" },
			{ { map = 1.5 }, "map" },
			{ { x = 1.2 }, "position" },
			{ { y = 0 / 0 }, "position" },
			{ { npcID = "abc" }, "npcID" },
		}
		for _, case in ipairs(cases) do
			local e, err = Store.Validate(data(case[1]))
			assert.is_nil(e)
			assert.equals(case[2], err)
		end
		assert.same({ nil, "invalid" }, { Store.Validate("nope") })
	end)

	it("caps text fields", function()
		local e = Store.Validate(data({ title = ("x"):rep(100), desc = ("y"):rep(600) }))
		assert.equals(Store.MAX_TITLE, #e.title)
		assert.equals(Store.MAX_DESC, #e.desc)
	end)

	it("cleans items: valid, unique, capped", function()
		local list = { { id = 5, cost = "|cffffffff1g|r" }, { id = 5 }, { id = -1 }, "junk" }
		for i = 1, 60 do list[#list + 1] = { id = 100 + i } end
		local e = Store.Validate(data({ items = list }))
		assert.equals(Store.MAX_ITEMS, #e.items)
		assert.same({ id = 5, cost = "1g" }, e.items[1])
		assert.is_nil(Store.Validate(data({ items = { "junk" } })).items)
	end)

	it("cleans schedules and drops empty ones", function()
		local e = Store.Validate(data({ schedule = { respawnMin = "29.6", window = " dusk ", note = "" } }))
		assert.same({ respawnMin = 30, window = "dusk" }, e.schedule)
		assert.is_nil(Store.Validate(data({ schedule = { respawnMin = -1, note = " " } })).schedule)
	end)

	it("cleans tags: trimmed, unique ignoring case, capped", function()
		local e = Store.Validate(data({ tags = { "Cave", "cave", " elite ", "a", "b", "c", "d", ("z"):rep(30) } }))
		assert.same({ "Cave", "elite", "a", "b", "c" }, e.tags)
	end)

	it("keeps npcID only as a positive integer", function()
		assert.equals(12345, Store.Validate(data({ npcID = "12345" })).npcID)
		assert.is_nil(Store.Validate(data({ npcID = "" })).npcID)
	end)
end)

describe("Store", function()
	local bucket, store
	before_each(function()
		bucket = {}
		store = Store.New(bucket)
	end)

	it("makes ids from the GUID suffix", function()
		assert.equals("E-0ABCDEF0-1790000000-7", Store.MakeId("E", "Player-1234-0ABCDEF0", 1790000000, 7))
		assert.equals("P-0-5-1", Store.MakeId("P", nil, 5, 1))
	end)

	it("creates entries with provenance", function()
		local e = store:Create(data(), ctx("E-1", 1000))
		assert.equals("E-1", e.id)
		assert.equals(1, e.rev)
		assert.equals("Scout-Realm", e.author)
		assert.equals("Scout-Realm", e.approvedBy)
		assert.equals(1000, e.createdAt)
		assert.equals(1000, e.approvedAt)
		assert.equals(e, bucket.entries["E-1"])
		assert.equals(e, store:Get("E-1"))
		assert.equals(1, store:Count())
	end)

	it("refuses duplicate ids and invalid data", function()
		store:Create(data(), ctx("E-1"))
		assert.same({ nil, "exists" }, { store:Create(data(), ctx("E-1")) })
		assert.same({ nil, "title" }, { store:Create(data({ title = "" }), ctx("E-2")) })
		assert.equals(1, store:Count())
	end)

	it("enforces the entry cap", function()
		local old = Store.MAX_ENTRIES
		Store.MAX_ENTRIES = 2
		store:Create(data(), ctx("E-1"))
		store:Create(data(), ctx("E-2"))
		local e, err = store:Create(data(), ctx("E-3"))
		Store.MAX_ENTRIES = old
		assert.is_nil(e)
		assert.equals("full", err)
	end)

	it("updates: replaces content, keeps authorship, bumps rev", function()
		store:Create(data({ npcID = 5, tags = { "a" } }), ctx("E-1", 1000, "Author-Realm"))
		local e = store:Update("E-1", data({ title = "Renamed" }), ctx("E-9", 2000, "Editor-Realm"))
		assert.equals("E-1", e.id)
		assert.equals("Renamed", e.title)
		assert.is_nil(e.npcID)
		assert.is_nil(e.tags)
		assert.equals(2, e.rev)
		assert.equals("Author-Realm", e.author)
		assert.equals(1000, e.createdAt)
		assert.equals("Editor-Realm", e.editedBy)
		assert.equals(2000, e.approvedAt)
		assert.same({ nil, "missing" }, { store:Update("nope", data(), ctx()) })
	end)

	it("keeps the old entry when an update is invalid", function()
		local e = store:Create(data(), ctx("E-1"))
		assert.same({ nil, "title" }, { store:Update("E-1", data({ title = "" }), ctx()) })
		assert.equals(e, store:Get("E-1"))
	end)

	it("deletes into a tombstone", function()
		store:Create(data(), ctx("E-1", 1000))
		local t = store:Delete("E-1", ctx("x", 2000, "Officer-Realm"))
		assert.is_true(t.deleted)
		assert.equals(2, t.rev)
		assert.equals("Officer-Realm", t.approvedBy)
		assert.is_nil(t.title)
		assert.is_nil(store:Get("E-1"))
		assert.equals(0, store:Count())
		assert.same({}, store:All())
		assert.same({ nil, "missing" }, { store:Delete("E-1", ctx()) })
	end)

	it("garbage-collects tombstones after 90 days", function()
		store:Create(data(), ctx("E-1", 1000))
		store:Create(data(), ctx("E-2", 1000))
		store:Delete("E-1", ctx("x", 1000))
		assert.equals(0, store:CollectGarbage(1000 + Store.TOMBSTONE_TTL))
		assert.equals(1, store:CollectGarbage(1001 + Store.TOMBSTONE_TTL))
		assert.is_nil(bucket.entries["E-1"])
		assert.is_not_nil(store:Get("E-2"))
	end)
end)

describe("FS:SaveEntry / DeleteEntry", function()
	it("need a guild", function()
		local state, FS = wow.boot()
		FS:OnEnable()
		assert.same({ nil, "noguild" }, { FS:SaveEntry(nil, data()) })
		assert.matches("Join a guild", table.concat(state.printed, "\n"), 1, true)
	end)

	it("create, update and delete in the active guild and announce changes", function()
		local state, FS = wow.boot({ guild = "Wardens", now = 1790000000 })
		FS:OnEnable()
		local e = FS:SaveEntry(nil, data())
		assert.equals("E-0ABCDEF0-1790000000-1", e.id)
		assert.equals("Scout-Realm", e.author)
		assert.equals(e, FS.db.global.guilds["name:Realm:Wardens"].entries[e.id])

		local e2 = FS:SaveEntry(e.id, data({ title = "New title" }))
		assert.equals(e.id, e2.id)
		assert.equals(2, e2.rev)

		FS:DeleteEntry(e.id)
		assert.is_nil(FS.store:Get(e.id))

		local changed = 0
		for _, m in ipairs(state.messages) do
			if m[1] == "FRONTIERSCOUT_ENTRIES_CHANGED" then changed = changed + 1 end
		end
		assert.equals(3, changed)
	end)
end)

describe("Store merging (sync)", function()
	local store
	before_each(function() store = Store.New({}) end)

	local function canon(over)
		local e = data({ id = "E-1", rev = 1, approvedAt = 100, approvedBy = "A-Realm", author = "Au-Realm", createdAt = 50 })
		for k, v in pairs(over or {}) do e[k] = v end
		return e
	end

	it("orders versions by rev, approvedAt, then approvedBy", function()
		assert.is_true(Store.Newer({ rev = 2, approvedAt = 1 }, { rev = 1, approvedAt = 9 }))
		assert.is_true(Store.Newer({ rev = 1, approvedAt = 9 }, { rev = 1, approvedAt = 1 }))
		assert.is_true(Store.Newer({ rev = 1, approvedAt = 1, approvedBy = "B" }, { rev = 1, approvedAt = 1, approvedBy = "A" }))
		assert.is_false(Store.Newer({ rev = 1, approvedAt = 1, approvedBy = "A" }, { rev = 1, approvedAt = 1, approvedBy = "A" }))
	end)

	it("applies newer entries and tombstones, refuses older ones", function()
		assert.is_not_nil(store:Apply(canon()))
		assert.same({ nil, "old" }, { store:Apply(canon()) })
		assert.is_not_nil(store:Apply(canon({ rev = 2, title = "New" })))
		assert.equals("New", store:Get("E-1").title)
		local t = store:Apply({ id = "E-1", deleted = true, rev = 3, approvedAt = 300, approvedBy = "A-Realm" })
		assert.is_true(t.deleted)
		assert.is_nil(store:Get("E-1"))
		assert.equals(1, store.digest.count)
	end)

	it("validates and cleans remote entries", function()
		assert.same({ nil, "category" }, { store:Apply(canon({ cat = "route" })) })
		assert.same({ nil, "invalid" }, { store:Apply(canon({ rev = 0 })) })
		assert.same({ nil, "invalid" }, { store:Apply({ id = 5 }) })
		local e = store:Apply(canon({ title = "|cffff0000Red|r", evil = "x", author = ("x"):rep(100) }))
		assert.equals("Red", e.title)
		assert.is_nil(e.evil)
		assert.is_nil(e.author)
	end)

	it("keeps the digest in step with every change", function()
		local e = store:Create(data(), ctx("E-1", 100))
		store:Update(e.id, data({ title = "B" }), ctx("x", 200))
		store:Delete(e.id, ctx("x", 300))
		assert.equals(ns_digest_root(store), store.digest:Root())
	end)

	it("finds stale local entries whose tombstones are long gone", function()
		store:Apply(canon({ id = "old", approvedAt = 1 }))
		store:Apply(canon({ id = "new", approvedAt = 10 ^ 9 }))
		local manifest = { [Digest.BucketOf("old")] = {}, [Digest.BucketOf("new")] = {} }
		assert.same({ "old" }, store:Stale(manifest, 10 ^ 9 + 1))
		store:Forget("old")
		assert.is_nil(store:GetAny("old"))
	end)
end)
