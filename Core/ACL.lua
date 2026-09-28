local _, ns = ...

-- Per-action rank thresholds and the archivist check (docs/SPEC.md §4).
-- Pure Lua: callers pass rank indexes, texts and flags.
local ACL = {}
ns.ACL = ACL

-- Rank thresholds in tag order. "do" is a Lua keyword, so always index with ["do"].
ACL.RANK_KEYS = { "s", "eo", "ea", "do", "da", "r" } -- chosen as "this rank and above"
-- All tag keys: the thresholds plus
--   an  1 = archivists also need {FS:A} in their officer note (0 = rank is enough)
--   am  archivist ranks as a bitmask (bit i = rank i); overrides `ar`, which
--       older clients still read (set to the lowest selected rank)
ACL.KEYS = { "s", "eo", "ea", "do", "da", "r", "ar", "an", "am" }
ACL.DEFAULTS = { s = 0, eo = 0, ea = 0, ["do"] = 0, da = 0, r = 9, ar = 0, an = 0 }
local MAX_VALUE = { an = 1, am = 1023 } -- other keys are ranks, 0..9
local OPTIONAL = { an = 0 } -- left out of the tag when at this value
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
		if (ACL.DEFAULTS[key] or key == "am") and value <= (MAX_VALUE[key] or 9) then t[key] = value end
	end
	return t, true
end

function ACL.Format(t)
	local parts = { "[FS1" }
	for _, key in ipairs(ACL.KEYS) do
		local value = t[key] or ACL.DEFAULTS[key]
		if value ~= nil and value ~= OPTIONAL[key] then
			parts[#parts + 1] = ("%s=%d"):format(key, value)
		end
	end
	return table.concat(parts, " ") .. "]"
end

local function hasBit(mask, bit)
	return math.floor(mask / 2 ^ bit) % 2 == 1
end

-- Is rank `rankIndex` one of the archivist ranks?
function ACL.IsArchivistRank(t, rankIndex)
	if rankIndex == nil then return false end
	if t.am then return rankIndex >= 0 and rankIndex <= 9 and hasBit(t.am, rankIndex) end
	return ACL.Can(t, "ar", rankIndex)
end

-- Selects or unselects archivist rank `rankIndex` in `t` (starting from `ar`
-- when there is no selection yet), keeping `ar` as the lowest selected rank.
function ACL.SetArchivistRank(t, rankIndex, on)
	local mask = t.am
	if not mask then
		mask = 0
		for i = 0, t.ar or 0 do mask = mask + 2 ^ i end
	end
	if on and not hasBit(mask, rankIndex) then mask = mask + 2 ^ rankIndex end
	if not on and hasBit(mask, rankIndex) then mask = mask - 2 ^ rankIndex end
	t.am = mask
	local lowest = 0
	for i = 0, 9 do if hasBit(mask, i) then lowest = i end end
	t.ar = lowest
end

-- Compares Guild Info text with the thresholds `t` someone wants. Addons may
-- not write Guild Info (SetGuildInfoText is protected), so leadership pastes
-- the tag in by hand and this says how far along that is:
--   "applied"  the text has a tag with exactly these thresholds
--   "differs"  the text has a tag with other thresholds (returned second)
--   "missing"  no tag yet
--   "toolong"  no tag, and adding one would pass MAX_INFO (characters over returned second)
function ACL.SetupStatus(text, t)
	text = text or ""
	local tag = ACL.Format(t)
	local current = text:match(TAG_PATTERN) and text:match("%[FS1[^%]]*%]")
	if current then
		local parsed = ACL.Parse(current)
		for _, key in ipairs(ACL.KEYS) do
			if (parsed[key] or ACL.DEFAULTS[key]) ~= (t[key] or ACL.DEFAULTS[key]) then return "differs", current end
		end
		return "applied"
	end
	local needed = #text + (text == "" and 0 or 1) + #tag
	if needed > ACL.MAX_INFO then return "toolong", needed - ACL.MAX_INFO end
	return "missing"
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
-- SPEC §4.4: everyone at or above the archivist rank. With `an=1` the
-- officer-note tag is required too, checked by viewers who can read notes.
function ACL.IsArchivist(t, member, viewerSeesNotes)
	if not member or not ACL.IsArchivistRank(t, member.rankIndex) then return false end
	if t.an == 1 and viewerSeesNotes then return member.officerNoteHasTag == true end
	return true
end
