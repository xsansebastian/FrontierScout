local _, ns = ...

-- Text sanitizing and small parse/format helpers. Pure Lua, no WoW API.
local Format = {}
ns.Format = Format

-- A complete item hyperlink. The colour prefix is either |cAARRGGBB or the
-- quality form |cnIQ4: used by newer clients.
local ITEM_LINK = "|c[^|]*|Hitem:[^|]*|h%[[^|]*%]|h|r"

local function trim(s)
	return (s:match("^%s*(.-)%s*$"))
end
Format.Trim = trim

-- Cuts `s` to at most `n` bytes without splitting a UTF-8 sequence.
function Format.Truncate(s, n)
	if #s <= n then return s end
	s = s:sub(1, n)
	for i = #s, math.max(1, #s - 3), -1 do
		local b = s:byte(i)
		if b < 0x80 then break end
		if b >= 0xC0 then
			local need = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or 2
			if #s - i + 1 < need then s = s:sub(1, i - 1) end
			break
		end
	end
	return s
end

-- Removes every UI escape sequence, keeping the visible text of hyperlinks.
local function stripCodes(s, multiline)
	s = s:gsub("|H.-|h(.-)|h", "%1")
	s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:|]*:", ""):gsub("|r", "")
	s = s:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|K.-|k", "")
	s = s:gsub("|n", "\n"):gsub("|", "")
	s = s:gsub("\r\n?", "\n"):gsub("[%z\1-\9\11-\31\127]", "")
	if multiline then
		s = s:gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n")
	else
		s = s:gsub("\n", " ")
	end
	return (s:gsub("[ \t]+", " "))
end

-- Plain text without any links or escape codes, e.g. for searching.
function Format.PlainText(s)
	return stripCodes(s or "", true)
end

-- Cleans user or network text: strips escape codes (keeping item links when
-- opts.links), normalizes whitespace (keeping newlines when opts.multiline),
-- trims, and cuts to maxLen bytes without breaking a link or a character.
-- Returns nil for non-strings.
function Format.Sanitize(text, maxLen, opts)
	if type(text) ~= "string" then return nil end
	opts = opts or {}

	local parts, pos = {}, 1
	while true do
		local s, e = text:find(ITEM_LINK, pos)
		if not s then break end
		parts[#parts + 1] = { text = text:sub(pos, s - 1) }
		parts[#parts + 1] = opts.links and { link = text:sub(s, e) } or { text = text:sub(s, e) }
		pos = e + 1
	end
	parts[#parts + 1] = { text = text:sub(pos) }

	for i, p in ipairs(parts) do
		if p.text then
			p.text = stripCodes(p.text, opts.multiline)
			if i == 1 then p.text = p.text:gsub("^%s+", "") end
			if i == #parts then p.text = p.text:gsub("%s+$", "") end
		end
	end

	local out, len = {}, 0
	for _, p in ipairs(parts) do
		if p.link then
			if len + #p.link > maxLen then break end
			out[#out + 1] = p.link
			len = len + #p.link
		else
			local t = Format.Truncate(p.text, maxLen - len)
			out[#out + 1] = t
			len = len + #t
			if #t < #p.text then break end
		end
	end
	return trim(table.concat(out))
end

function Format.ItemIdFromLink(link)
	if type(link) ~= "string" then return nil end
	return tonumber(link:match("|Hitem:(%d+)"))
end

-- 123456 copper -> "12g 34s 56c".
function Format.Money(copper)
	copper = math.floor(tonumber(copper) or 0)
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g .. "g" end
	if s > 0 then parts[#parts + 1] = s .. "s" end
	if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
	return table.concat(parts, " ")
end

-- Normalized 0..1 coordinates -> "45.2, 67.8" (map percent).
function Format.Coords(x, y, decimals)
	local fmt = "%." .. (decimals or 1) .. "f"
	return (fmt .. ", " .. fmt):format(x * 100, y * 100)
end

-- "45.2, 67.8" or "45.2 67.8" (map percent) -> 0.452, 0.678.
function Format.ParseCoords(text)
	if type(text) ~= "string" then return nil end
	local a, b = text:match("^%s*([%d%.]+)%s*[,; ]%s*([%d%.]+)%s*$")
	local x, y = tonumber(a), tonumber(b)
	if not x or not y or x > 100 or y > 100 then return nil end
	return x / 100, y / 100
end

-- One item per line: "<item link or itemID> = <cost>" (cost optional).
function Format.ParseItems(text)
	local items = {}
	for line in (text or ""):gmatch("[^\n]+") do
		local id = Format.ItemIdFromLink(line) or tonumber(line:match("^%s*(%d+)"))
		if id then
			local cost = line:match("=%s*(.-)%s*$")
			items[#items + 1] = { id = id, cost = (cost and cost ~= "") and cost or nil }
		end
	end
	return items
end

-- Inverse of ParseItems. `linkFor(id)` may return an item link to show instead of the ID.
function Format.Items(items, linkFor)
	local lines = {}
	for _, item in ipairs(items or {}) do
		local label = (linkFor and linkFor(item.id)) or tostring(item.id)
		lines[#lines + 1] = item.cost and (label .. " = " .. item.cost) or label
	end
	return table.concat(lines, "\n")
end

function Format.ParseTags(text)
	local tags = {}
	for tag in (text or ""):gmatch("[^,]+") do
		tag = trim(tag)
		if tag ~= "" then tags[#tags + 1] = tag end
	end
	return tags
end

function Format.Tags(tags)
	return table.concat(tags or {}, ", ")
end
