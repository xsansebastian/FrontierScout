local _, ns = ...

-- Browser tabs for curation and sync (docs/SPEC.md §7.4): My submissions,
-- Review queue (archivists only) and Sync.
local FS, L = ns.FS, ns.L
local Review, Widgets, Icons = ns.Review, ns.Widgets, ns.Icons

local OP_LABELS = {
	create = L["New"],
	edit = L["Edit"],
	delete = L["Delete"],
	report = L["Outdated"],
}

local STATUS = {
	waiting = { L["waiting for an archivist"], "|cffaaaaaa%s|r" },
	queued = { L["in the review queue"], "|cffffd100%s|r" },
	approved = { L["approved"], "|cff33ff33%s|r" },
	rejected = { L["rejected"], "|cffff5555%s|r" },
}

local function status(s)
	local st = STATUS[s] or { s, "%s" }
	return st[2]:format(st[1])
end

local function when(t)
	return t and date("%Y-%m-%d %H:%M", t) or "?"
end

local function rankName(member)
	local info = FS.roster[member]
	return info and FS.rankNames[info.rankIndex] or "?"
end

-- A two-pane page: list on the left, text and buttons on the right.
local function twoPane(frame, rowInit)
	local list, bar, view = Widgets.NewList(frame)
	list:SetPoint("TOPLEFT", 6, -6)
	list:SetPoint("BOTTOMLEFT", 6, 36)
	list:SetWidth(320)
	view:SetElementInitializer("Button", rowInit)
	ScrollUtil.InitScrollBoxListWithScrollBar(list, bar, view)
	frame.list = list

	frame.empty = frame:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	frame.empty:SetPoint("TOP", list, "TOP", 0, -20)

	local text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("TOPLEFT", list, "TOPRIGHT", 26, 0)
	text:SetPoint("BOTTOMRIGHT", -8, 36)
	text:SetJustifyH("LEFT")
	text:SetJustifyV("TOP")
	text:SetSpacing(2)
	frame.text = text
end

-- My submissions ------------------------------------------------------------------

local mineState = { selected = nil }

local function mineRow(row, data)
	Widgets.SetupRow(row, function(self)
		mineState.selected = self.data.pid
		FS:SendMessage("FRONTIERSCOUT_PROPOSALS_CHANGED")
	end)
	row.data = data
	row.icon:Hide()
	row.label:ClearAllPoints()
	row.label:SetPoint("LEFT", 4, 0)
	row.label:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	row.label:SetText(("%s: %s"):format(OP_LABELS[data.op] or data.op, data.title))
	row.count:SetText(status(data.status))
	row.bg:SetShown(data.pid == mineState.selected)
end

table.insert(ns.BrowserPages, {
	key = "mine",
	label = function()
		local waiting = 0
		for _, s in ipairs(FS:MySubmissions()) do
			if s.status == "waiting" or s.status == "queued" then waiting = waiting + 1 end
		end
		return waiting > 0 and L["My submissions (%d)"]:format(waiting) or L["My submissions"]
	end,
	visible = function() return true end,
	build = function(frame)
		twoPane(frame, mineRow)
		frame.empty:SetText(L["Nothing submitted yet."])
		frame.resend = Widgets.Button(frame, L["Send again"], 110, function()
			FS:FlushOutbox(true)
			if #FS:OnlineArchivists() == 0 then FS:Print(L["No archivist is online. Submissions are sent when one is."]) end
		end)
		frame.resend:SetPoint("BOTTOMLEFT", 6, 6)
		frame.clear = Widgets.Button(frame, L["Clear finished"], 110, function() FS:ClearFinished() end)
		frame.clear:SetPoint("LEFT", frame.resend, "RIGHT", 4, 0)
	end,
	refresh = function(frame)
		local list = FS:MySubmissions()
		frame.list:SetDataProvider(CreateDataProvider(list), ScrollBoxConstants.RetainScrollPosition)
		frame.empty:SetShown(#list == 0)
		local s
		for _, item in ipairs(list) do if item.pid == mineState.selected then s = item end end
		if not s then
			frame.text:SetText(L["Discoveries you add, edit, delete or report are reviewed by an archivist before the guild sees them."])
			return
		end
		local lines = {
			("|cffffd100%s|r"):format(s.title),
			L["%s, sent %s"]:format(OP_LABELS[s.op] or s.op, when(s.at)),
			L["Status: %s"]:format(status(s.status)),
		}
		if s.reason then lines[#lines + 1] = L["Reason: %s"]:format(s.reason) end
		frame.text:SetText(table.concat(lines, "\n"))
	end,
})

-- Review queue ----------------------------------------------------------------------

local reviewState = { selected = nil }

local function reviewRow(row, p)
	Widgets.SetupRow(row, function(self)
		reviewState.selected = self.data.pid
		FS:SendMessage("FRONTIERSCOUT_QUEUE_CHANGED")
	end)
	row.data = p
	local target = FS.store and FS.store:Get(p.eid)
	local sub = (p.data and p.data.sub) or (target and target.sub)
	row.icon:Show()
	Icons.Apply(row.icon, sub)
	row.label:ClearAllPoints()
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
	row.label:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	local title = (p.data and p.data.title) or (target and target.title) or "?"
	row.label:SetText(("%s: %s"):format(OP_LABELS[p.op] or p.op, title))
	row.count:SetText(Ambiguate(p.author, "guild"))
	row.bg:SetShown(p.pid == reviewState.selected)
end

-- Full description of a proposal for the archivist.
local function proposalText(p)
	local target = FS.store:Get(p.eid)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	local title = (p.data and p.data.title) or (target and target.title) or "?"
	add(("|cffffd100%s: %s|r"):format(OP_LABELS[p.op] or p.op, title))
	add(L["By %s (%s), %s"]:format(Ambiguate(p.author, "guild"), rankName(p.author), when(p.at)))
	local ok, why = FS:ProposalAllowed(p)
	if not ok then add("|cffff5555" .. L["Can't be approved any more: %s"]:format(why) .. "|r") end
	if p.baseRev and target and p.baseRev < target.rev then
		add("|cffff8800" .. L["Warning: the entry changed since this was proposed (revision %d, now %d)."]:format(p.baseRev, target.rev) .. "|r")
	end
	if p.reason then add(L["Reason: %s"]:format(p.reason)) end
	if p.op == "create" then
		local preview = {}
		for k, v in pairs(p.data) do preview[k] = v end
		preview.author, preview.createdAt, preview.rev = p.author, p.at, 1
		add("\n" .. Widgets.DetailText(preview))
	elseif p.op == "edit" then
		add("\n|cffffd100" .. L["Changes"] .. "|r")
		for _, c in ipairs(Review.Diff(target, p.data)) do
			add(("%s: |cffff7777%s|r -> |cff77ff77%s|r"):format(c[1], c[2] or "-", c[3] or "-"))
		end
	elseif target then
		add("\n" .. Widgets.DetailText(target))
	end
	return table.concat(lines, "\n")
end

StaticPopupDialogs.FRONTIERSCOUT_REJECT = {
	text = L["Reject \"%s\"? Reason (sent to the author):"],
	button1 = L["Reject"],
	button2 = CANCEL,
	hasEditBox = true,
	maxLetters = 200,
	OnAccept = function(popup, pid) FS:Reject(pid, ns.PopupText(popup)) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

table.insert(ns.BrowserPages, {
	key = "review",
	label = function()
		local n = #FS:QueueList()
		return n > 0 and L["Review (%d)"]:format(n) or L["Review"]
	end,
	visible = function() return FS.store ~= nil and FS:AmArchivist() end,
	build = function(frame)
		twoPane(frame, reviewRow)
		frame.empty:SetText(L["Nothing to review."])
		frame.approve = Widgets.Button(frame, L["Approve"], 100, function()
			local pid = reviewState.selected
			if pid then FS:Approve(pid) end
		end)
		frame.approve:SetPoint("BOTTOMLEFT", frame.list, "BOTTOMRIGHT", 26, -30)
		frame.reject = Widgets.Button(frame, L["Reject"], 100, function()
			local p = reviewState.selected and FS.store.bucket.queue[reviewState.selected]
			if p then StaticPopup_Show("FRONTIERSCOUT_REJECT", (p.data and p.data.title) or p.eid, nil, p.pid) end
		end)
		frame.reject:SetPoint("LEFT", frame.approve, "RIGHT", 4, 0)
		frame.show = Widgets.Button(frame, L["Show"], 80, function()
			local p = reviewState.selected and FS.store.bucket.queue[reviewState.selected]
			if not p then return end
			if FS.store:Get(p.eid) then
				FS:ShowBrowserTab("discoveries")
				FS:SelectEntry(p.eid)
			elseif p.data then
				FS:SetWaypoint({ title = p.data.title, map = p.data.map, x = p.data.x, y = p.data.y })
			end
		end)
		frame.show:SetPoint("LEFT", frame.reject, "RIGHT", 4, 0)
		frame.warnings = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		frame.warnings:SetPoint("BOTTOMLEFT", 6, 8)
		frame.warnings:SetWidth(320)
		frame.warnings:SetJustifyH("LEFT")
	end,
	refresh = function(frame)
		local list = FS:QueueList()
		frame.list:SetDataProvider(CreateDataProvider(list), ScrollBoxConstants.RetainScrollPosition)
		frame.empty:SetShown(#list == 0)
		local p = reviewState.selected and FS.store.bucket.queue[reviewState.selected]
		if not p then reviewState.selected = nil end
		frame.text:SetText(p and proposalText(p) or L["Select a proposal to review it."])
		frame.approve:SetText(p and p.op == "report" and L["Resolved"] or L["Approve"])
		frame.reject:SetText(p and p.op == "report" and L["Dismiss"] or L["Reject"])
		if p then frame.approve:Enable() frame.reject:Enable() frame.show:Enable()
		else frame.approve:Disable() frame.reject:Disable() frame.show:Disable() end
		local warnings = FS:Warnings()
		frame.warnings:SetText(#warnings > 0 and ("|cffff8800" .. L["Warnings"] .. ":|r " .. warnings[#warnings]) or "")
	end,
})

-- Sync ---------------------------------------------------------------------------------

table.insert(ns.BrowserPages, {
	key = "sync",
	label = function() return L["Sync"] end,
	visible = function() return FS.store ~= nil end,
	build = function(frame)
		frame.text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		frame.text:SetPoint("TOPLEFT", 16, -16)
		frame.text:SetPoint("RIGHT", -16, 0)
		frame.text:SetJustifyH("LEFT")
		frame.text:SetSpacing(4)
		frame.now = Widgets.Button(frame, L["Sync now"], 110, function() FS:SyncNow() end)
		frame.now:SetPoint("BOTTOMLEFT", 10, 10)
	end,
	refresh = function(frame)
		local s = FS:SyncStatus()
		local archivists = {}
		for i, name in ipairs(s.archivists) do archivists[i] = Ambiguate(name, "guild") end
		frame.text:SetText(table.concat({
			L["Discoveries: %d (%d records, counting deletions still spreading)"]:format(FS.store and FS.store:Count() or 0, s.count),
			L["Last full sync: %s"]:format(s.lastFullSync and when(s.lastFullSync) or L["never"]),
			L["Archivists seen: %s"]:format(#archivists > 0 and table.concat(archivists, ", ") or L["none seen"]),
			L["Your role: %s"]:format(FS:AmArchivist() and L["archivist"] or L["member"]),
			s.syncing and L["Syncing with %s..."]:format(Ambiguate(s.syncing, "guild")) or "",
			"|cff888888" .. L["Data hash: %08x"]:format(s.root or 0) .. "|r",
		}, "\n"))
	end,
})
