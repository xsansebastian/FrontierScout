-- Packaging checks: WoW silently skips files it cannot find, so a typo in the
-- TOC or an XML include only shows up as a nil library at runtime.

local TOC = "FrontierScout.toc"

local function exists(path)
	local f = io.open(path, "r")
	if f then f:close() return true end
	return false
end

local function readAll(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

local function dirname(path)
	return path:match("^(.*)/[^/]*$") or "."
end

local function normalize(dir, file)
	local path = file:gsub("\\", "/")
	if dir ~= "." then path = dir .. "/" .. path end
	return path
end

local function tocFiles()
	local files = {}
	for line in readAll(TOC):gmatch("[^\r\n]+") do
		line = line:match("^%s*(.-)%s*$")
		if line ~= "" and not line:find("^#") then
			files[#files + 1] = normalize(".", line)
		end
	end
	return files
end

-- Follows <Script file=> / <Include file=> recursively. Commented-out entries are ignored.
local function collect(path, seen, missing)
	if seen[path] then return end
	seen[path] = true
	if not exists(path) then
		missing[#missing + 1] = path
		return
	end
	if path:find("%.xml$") then
		local xml = readAll(path):gsub("<!%-%-.-%-%->", "")
		for file in xml:gmatch('<%a+%s+file="([^"]+)"') do
			collect(normalize(dirname(path), file), seen, missing)
		end
	end
end

describe("FrontierScout.toc", function()
	it("targets the Forever interface", function()
		local interface = readAll(TOC):match("## Interface:%s*([^\r\n]+)")
		assert.is_not_nil(interface)
		assert.matches("^16001", interface)
	end)

	it("declares the saved variables used by Core/Init.lua", function()
		assert.matches("## SavedVariables: FrontierScoutDB", readAll(TOC), 1, true)
	end)

	it("references only files that exist, through every XML include", function()
		local seen, missing = {}, {}
		for _, file in ipairs(tocFiles()) do
			collect(file, seen, missing)
		end
		assert.same({}, missing)
	end)

	it("loads every addon source file", function()
		local listed = {}
		for _, file in ipairs(tocFiles()) do listed[file] = true end
		local p = assert(io.popen('find Core Locales UI -name "*.lua" 2>/dev/null'))
		local unlisted = {}
		for file in p:lines() do
			if not listed[file] then unlisted[#unlisted + 1] = file end
		end
		p:close()
		assert.same({}, unlisted)
	end)
end)
