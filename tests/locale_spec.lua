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

describe("Locales/esES.lua", function()
	local function defined(path)
		local out, order = {}, {}
		for line in readAll(path):gmatch("[^\n]+") do
			local key, value = line:match('^L%["(.-[^\\])"%] = (.*)$')
			if key then
				out[key] = value
				order[#order + 1] = key
			end
		end
		return out, order
	end

	local function placeholders(s)
		local list = {}
		for p in s:gmatch("%%%-?%d*%a") do list[#list + 1] = p end
		return table.concat(list, " ")
	end

	it("translates every English string, with the same placeholders", function()
		local en, order = defined("Locales/enUS.lua")
		local es = defined("Locales/esES.lua")
		local problems = {}
		for _, key in ipairs(order) do
			local value = es[key]
			if not value then
				problems[#problems + 1] = "missing: " .. key
			elseif placeholders(value) ~= placeholders(key) then
				problems[#problems + 1] = "placeholders: " .. key
			end
		end
		for key in pairs(es) do
			if not en[key] then problems[#problems + 1] = "unknown key: " .. key end
		end
		assert.same({}, problems)
	end)

	it("is used on Spanish clients", function()
		local wow = require("tests.helpers.wow")
		local state, _, ns = wow.boot({ locale = "esES", guild = "Hermandad" })
		wow.slash(state, "status")
		assert.matches("Hermandad: Hermandad", table.concat(state.printed, "\n"), 1, true)
		assert.equals("Tesoro", ns.Categories.Label("treasure"))
	end)
end)
