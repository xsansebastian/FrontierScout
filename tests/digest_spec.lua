local wow = require("tests.helpers.wow")

local Digest
setup(function()
	local _, _, ns = wow.boot()
	Digest = ns.Digest
end)

-- 32-bit XOR returning signed results, like LuaJIT's bit library.
local function signedBxor(a, b)
	a, b = a % 4294967296, b % 4294967296
	local r, p = 0, 1
	for _ = 1, 32 do
		local ab, bb = a % 2, b % 2
		if ab ~= bb then r = r + p end
		a, b, p = (a - ab) / 2, (b - bb) / 2, p * 2
	end
	if r >= 2147483648 then r = r - 4294967296 end
	return r
end

describe("Digest.fnv1a", function()
	it("matches the FNV-1a 32-bit test vectors", function()
		assert.equals(0x811c9dc5, Digest.fnv1a(""))
		assert.equals(0xe40c292c, Digest.fnv1a("a"))
		assert.equals(0xbf9cf968, Digest.fnv1a("foobar"))
	end)

	it("gives the same result with the bit library", function()
		_G.bit = { bxor = signedBxor }
		local ok, err = pcall(function()
			for _, s in ipairs({ "", "a", "foobar", "E-0ABCDEF0-1790000000-12", ("ñx"):rep(40) }) do
				assert.equals(Digest.fnvArith(s), Digest.fnv1a(s))
			end
		end)
		_G.bit = nil
		assert(ok, err)
	end)
end)

describe("Digest", function()
	local function e(id, rev, at) return { id = id, rev = rev or 1, approvedAt = at or 100 } end

	it("puts ids in 64 buckets", function()
		for _, id in ipairs({ "a", "b", "E-1" }) do
			local b = Digest.BucketOf(id)
			assert.is_true(b >= 0 and b < 64)
		end
	end)

	it("is independent of insertion order and tracks changes", function()
		local a = Digest.New({ x = e("x"), y = e("y"), z = e("z") })
		local b = Digest.New()
		b:Set(e("z"))
		b:Set(e("x"))
		b:Set(e("y"))
		assert.equals(a:Root(), b:Root())
		assert.equals(3, b.count)
		b:Set(e("y", 2, 200))
		assert.are_not.equal(a:Root(), b:Root())
		assert.equals(3, b.count)
		b:Remove("y")
		b:Remove("y")
		assert.equals(2, b.count)
		assert.equals(Digest.New({ x = e("x"), z = e("z") }):Root(), b:Root())
	end)

	it("diffs buckets and lists wanted ids from a manifest", function()
		local mine = Digest.New({ a = e("a"), b = e("b", 2, 200) })
		local theirs = Digest.New({ a = e("a", 3, 300), b = e("b"), c = e("c") })
		local diff = theirs:Diff(mine:Buckets())
		assert.is_true(#diff >= 1 and #diff <= 3)
		assert.same({ "a", "c" }, mine:Wanted(theirs:Manifest(diff)))
		assert.same({}, mine:Diff(mine:Buckets()))
		assert.equals(64, #mine:Diff(nil))
	end)

	it("ignores malformed manifests", function()
		local d = Digest.New()
		assert.same({}, d:Wanted({ [1] = "junk", [2] = { [5] = "1:1" }, [99] = { x = "1:1" } }))
	end)

	it("compares versions", function()
		assert.is_true(Digest.VersionNewer("2:100", "1:500"))
		assert.is_true(Digest.VersionNewer("1:200", "1:100"))
		assert.is_false(Digest.VersionNewer("1:100", "1:100"))
		assert.is_true(Digest.VersionNewer("1:1", nil))
		assert.is_false(Digest.VersionNewer("x", "1:1"))
	end)
end)
