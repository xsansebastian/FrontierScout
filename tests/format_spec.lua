local wow = require("tests.helpers.wow")

local Format
setup(function()
	local _, _, ns = wow.boot()
	Format = ns.Format
end)

local LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r"
local NEW_LINK = "|cnIQ4:|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r"

describe("Format.Sanitize", function()
	it("returns nil for non-strings", function()
		assert.is_nil(Format.Sanitize(nil, 10))
		assert.is_nil(Format.Sanitize(42, 10))
	end)

	it("strips colours, textures, atlases and stray pipes", function()
		local s = "|cffff0000Red|r |TInterface\\Icons\\X:0|t|A:VignetteKill:12:12|a boss || here"
		assert.equals("Red boss here", Format.Sanitize(s, 100))
	end)

	it("keeps the visible text of non-item hyperlinks", function()
		assert.equals("see [Fireball] now", Format.Sanitize("see |cff71d5ff|Hspell:133|h[Fireball]|h|r now", 100))
	end)

	it("keeps item links only when allowed", function()
		assert.equals("drops " .. LINK, Format.Sanitize("drops " .. LINK, 200, { links = true }))
		assert.equals("drops " .. NEW_LINK, Format.Sanitize("drops " .. NEW_LINK, 200, { links = true }))
		assert.equals("drops [Thunderfury]", Format.Sanitize("drops " .. LINK, 200))
	end)

	it("never cuts an item link in half", function()
		local s = Format.Sanitize("abc " .. LINK .. " tail", 20, { links = true })
		assert.equals("abc", s)
	end)

	it("never cuts a UTF-8 character in half", function()
		local s = Format.Sanitize("ñññ", 5) -- 6 bytes
		assert.equals("ññ", s)
	end)

	it("normalizes whitespace and newlines", function()
		assert.equals("a b c", Format.Sanitize("  a \t b\nc  ", 100))
		assert.equals("a\n\nb", Format.Sanitize("a  \n\n\n\nb", 100, { multiline = true }))
		assert.equals("a\nb", Format.Sanitize("a|nb", 100, { multiline = true }))
	end)

	it("removes control characters", function()
		assert.equals("ab", Format.Sanitize("a\1\127b", 100))
	end)
end)

describe("Format helpers", function()
	it("formats money", function()
		assert.equals("12g 34s 56c", Format.Money(123456))
		assert.equals("5s", Format.Money(500))
		assert.equals("0c", Format.Money(0))
	end)

	it("formats and parses coordinates", function()
		assert.equals("45.2, 67.8", Format.Coords(0.452, 0.678))
		assert.equals("45.20, 67.80", Format.Coords(0.452, 0.678, 2))
		local x, y = Format.ParseCoords("45.2, 67.8")
		assert.near(0.452, x, 1e-9)
		assert.near(0.678, y, 1e-9)
		x = Format.ParseCoords("45.2 67.8")
		assert.near(0.452, x, 1e-9)
		assert.is_nil(Format.ParseCoords("hello"))
		assert.is_nil(Format.ParseCoords("120, 5"))
	end)

	it("parses and formats item lists", function()
		local items = Format.ParseItems(LINK .. " = 5g\n12345\n  nonsense\n777 = 2 Honor")
		assert.same({ { id = 19019, cost = "5g" }, { id = 12345 }, { id = 777, cost = "2 Honor" } }, items)
		assert.equals("19019 = 5g\n12345\n777 = 2 Honor", Format.Items(items))
		assert.equals("[x] = 5g", Format.Items({ { id = 1, cost = "5g" } }, function() return "[x]" end))
	end)

	it("parses and formats tags", function()
		assert.same({ "cave", "elite mob" }, Format.ParseTags(" cave, , elite mob ,"))
		assert.equals("a, b", Format.Tags({ "a", "b" }))
		assert.equals("", Format.Tags(nil))
	end)

	it("reads item IDs from links", function()
		assert.equals(19019, Format.ItemIdFromLink(LINK))
		assert.is_nil(Format.ItemIdFromLink("no link"))
	end)
end)
