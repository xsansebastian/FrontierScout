-- Every L["..."] used by the addon must be defined in Locales/enUS.lua, the
-- base locale (other locales fall back to it).

local function readAll(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

local function keys(src)
	local out = {}
	for key in src:gmatch('L%["(.-[^\\])"%]') do out[key] = true end
	return out
end

describe("Locales/enUS.lua", function()
	it("defines every string the addon uses", function()
		local defined = keys(readAll("Locales/enUS.lua"))
		local missing = {}
		local p = assert(io.popen('find Core UI -name "*.lua" | sort'))
		for file in p:lines() do
			for key in pairs(keys(readAll(file))) do
				if not defined[key] then missing[#missing + 1] = file .. ": " .. key end
			end
		end
		p:close()
		table.sort(missing)
		assert.same({}, missing)
	end)
end)
