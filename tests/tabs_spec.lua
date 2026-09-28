local Net = require("tests.helpers.net")

-- M5 in the browser: My submissions, Review (archivists) and Sync tabs, and
-- reporting from the detail pane.

local function data(title)
	return { cat = "location", sub = "treasure", title = title, map = 1, x = 0.5, y = 0.5 }
end

local function network()
	local net = Net.new({ { name = "Arch", rank = 1, archivist = true }, { name = "Mem", rank = 2 } }, { ui = true })
	net:Tick()
	return net
end

local function tabKeys(browser)
	local out = {}
	for _, tab in ipairs(browser.tabs) do
		if tab:IsShown() then out[#out + 1] = tab.key end
	end
	return out
end

describe("Browser tabs", function()
	it("show Review to archivists only", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		arch.FS:OpenBrowser()
		mem.FS:OpenBrowser()
		assert.same({ "discoveries", "mine", "review", "sync" }, tabKeys(arch.state.frames.FrontierScoutBrowser))
		assert.same({ "discoveries", "mine", "sync" }, tabKeys(mem.state.frames.FrontierScoutBrowser))
	end)

	it("review a proposal and see the result in My submissions", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		mem.FS:OpenBrowser()
		mem.FS:SaveEntry(nil, data("Cave loot"))
		net:Flush()
		local mb = mem.state.frames.FrontierScoutBrowser
		mem.FS:ShowBrowserTab("mine")
		local mine = mb.pages.mine
		assert.is_true(mine.frame:IsShown())
		assert.is_false(mb.Inset:IsShown())
		assert.equals("My submissions (1)", mine.tab:GetText())
		mine.frame.list.rows[1]:Click()
		assert.matches("in the review queue", mine.frame.text:GetText(), 1, true)

		arch.FS:OpenBrowser()
		arch.FS:ShowBrowserTab("review")
		local review = arch.state.frames.FrontierScoutBrowser.pages.review
		assert.equals("Review (1)", review.tab:GetText())
		review.frame.list.rows[1]:Click()
		assert.matches("By Mem (Member)", review.frame.text:GetText(), 1, true)
		review.frame.approve:Click()
		net:Flush()
		assert.equals("Review", review.tab:GetText())
		assert.matches("approved", mine.frame.text:GetText(), 1, true)
		assert.equals("My submissions", mine.tab:GetText())
	end)

	it("reject asks for a reason", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		local p = mem.FS:SaveEntry(nil, data("Nope"))
		net:Flush()
		arch.FS:OpenBrowser()
		arch.FS:ShowBrowserTab("review")
		local review = arch.state.frames.FrontierScoutBrowser.pages.review
		review.frame.list.rows[1]:Click()
		review.frame.reject:Click()
		local popup = arch.state.popups[1]
		assert.equals("FRONTIERSCOUT_REJECT", popup[1])
		arch.state.env.StaticPopupDialogs.FRONTIERSCOUT_REJECT.OnAccept({ editBox = { GetText = function() return "dup" end } }, popup[4])
		net:Flush()
		assert.equals("dup", mem.FS.store.bucket.mine[p.pid].reason)
	end)

	it("shows edit diffs to the archivist", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		local e = arch.FS.store:Create(data("Old"), { id = "E-m", by = "Mem-Realm", now = 1 })
		mem.FS.store:Apply(e)
		mem.FS:SaveEntry(e.id, data("New"))
		net:Flush()
		arch.FS:OpenBrowser()
		arch.FS:ShowBrowserTab("review")
		local review = arch.state.frames.FrontierScoutBrowser.pages.review
		review.frame.list.rows[1]:Click()
		assert.matches("title: |cffff7777Old|r -> |cff77ff77New|r", review.frame.text:GetText(), 1, true)
	end)

	it("reports from the detail pane", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		local e = arch.FS:SaveEntry(nil, data("Chest"))
		net:Flush()
		mem.FS:SelectEntry(e.id)
		local detail = mem.state.frames.FrontierScoutBrowser.detail
		assert.is_true(detail.report:IsEnabled())
		detail.report:Click()
		local popup = mem.state.popups[1]
		mem.state.env.StaticPopupDialogs.FRONTIERSCOUT_REPORT.OnAccept({ GetEditBox = function() return { GetText = function() return "gone" end } end }, popup[4])
		net:Flush()
		assert.equals("gone", arch.FS:QueueList()[1].reason)
	end)

	it("shows sync status", function()
		local net = network()
		local mem = net:Client("Mem")
		mem.FS:OpenBrowser()
		mem.FS:ShowBrowserTab("sync")
		local text = mem.state.frames.FrontierScoutBrowser.pages.sync.frame.text:GetText()
		assert.matches("Archivists seen: Arch", text, 1, true)
		assert.matches("Your role: member", text, 1, true)
	end)
end)
