local _, ns = ...

-- Per-action rank thresholds and the archivist check (docs/SPEC.md §4).
-- Pure Lua: callers pass rank indexes, texts and flags.
local ACL = {}
ns.ACL = ACL

-- Action keys in tag order. "do" is a Lua keyword, so always index with ["do"].
ACL.KEYS = { "s", "eo", "ea", "do", "da", "r", "ar" }
ACL.DEFAULTS = { s = 0, eo = 0, ea = 0, ["do"] = 0, da = 0, r = 9, ar = 0 }
ACL.NOTE_TAG = "{FS:A}"
ACL.MAX_INFO = 500 -- Guild Info text length (SPEC §12 q6)

local TAG_PATTERN = "%[FS1([^%]]*)%]"

local function copyDefaults()
	local t = {}
	for k, v in pairs(ACL.DEFAULTS) do t[k] = v end
	return t
end

-- Thresholds from Guild Info text. Returns the table and whether a tag was
-- found; missing or invalid keys keep their defaults.
function ACL.Parse(text)
	local t = copyDefaults()
	local body = type(text) == "string" and text:match(TAG_PATTERN)
	if not body then return t, false end
	for key, value in body:gmatch("(%a+)=(%d+)") do
		value = tonumber(value)
		if ACL.DEFAULTS[key] and value <= 9 then t[key] = value end
	end
	return t, true
end

function ACL.Format(t)
	local parts = { "[FS1" }
	for _, key in ipairs(ACL.KEYS) do
		parts[#parts + 1] = ("%s=%d"):format(key, t[key] or ACL.DEFAULTS[key])
	end
	return table.concat(parts, " ") .. "]"
end

-- Guild Info text with the tag replaced or appended, leaving everything else
-- as it was. Returns nil, "toolong" when the result wouldn't fit.
function ACL.Apply(text, t)
	text = text or ""
	local tag = ACL.Format(t)
	local s, e = text:find(TAG_PATTERN)
	local result
	if s then
		result = text:sub(1, s - 1) .. tag .. text:sub(e + 1)
	elseif text == "" then
		result = tag
	else
		result = text:gsub("%s+$", "") .. "\n" .. tag
	end
	if #result > ACL.MAX_INFO then return nil, "toolong" end
	return result
end

-- May a member of rank `rankIndex` (0 = Guild Master) do `action`?
function ACL.Can(t, action, rankIndex)
	return rankIndex ~= nil and rankIndex <= (t[action] or -1)
end

-- Which ACL key governs a proposal: op is "create" | "edit" | "delete" | "report".
function ACL.KeyFor(op, isAuthor)
	if op == "create" then return "s" end
	if op == "edit" then return isAuthor and "eo" or "ea" end
	if op == "delete" then return isAuthor and "do" or "da" end
	if op == "report" then return "r" end
end

-- Edits and deletions of your own entries are allowed by either the "own" or
-- the "any" threshold.
function ACL.CanPropose(t, op, rankIndex, isAuthor)
	local key = ACL.KeyFor(op, isAuthor)
	if not key then return false end
	if ACL.Can(t, key, rankIndex) then return true end
	if isAuthor and (op == "edit" or op == "delete") then
		return ACL.Can(t, ACL.KeyFor(op, false), rankIndex)
	end
	return false
end

function ACL.NoteHasTag(note)
	return type(note) == "string" and note:find(ACL.NOTE_TAG, 1, true) ~= nil
end

-- SPEC §4.4: rank gate for everyone; officer-note tag too when the viewer
-- can read officer notes. `member` = { rankIndex, officerNoteHasTag }.
function ACL.IsArchivist(t, member, viewerSeesNotes)
	if not member or not ACL.Can(t, "ar", member.rankIndex) then return false end
	if viewerSeesNotes then return member.officerNoteHasTag == true end
	return true
end
