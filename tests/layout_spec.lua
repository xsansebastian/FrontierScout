local wow = require("tests.helpers.wow")
local Net = require("tests.helpers.net")
local frames = require("tests.helpers.frames")

-- Layout fixes from the first in-game screenshots: overlapping checkboxes and
-- banner, a gap in the tabs, clipped button text, an overflowing options page.

local function point(frame, name)
	for _, p in ipairs(frame.points or {}) do
		if p[1] == name then return p end
	end
end

describe("Browser layout", function()
	local function boot(opts)
		local state, FS = wow.boot(opts or { guild = "Wardens", ui = true })
		state.env.C_Map = { GetMapInfo = function() end, GetBestMapForUnit = function() end }
		FS:OnEnable()
		FS:OpenBrowser()
		return state, FS, state.frames.FrontierScoutBrowser
	end

	it("places each filter checkbox after the previous label", function()
		local _, _, browser = boot()
		local anchor = point(browser.newOnly, "LEFT")
		-- Anchored to a label (a font string), not to a checkbox with a fixed offset.
		assert.is_not_nil(anchor[2])
		assert.is_nil(anchor[2].label)
		assert.equals("RIGHT", anchor[3])
	end)

	it("puts the setup banner on its own line and moves the lists down", function()
		local _, _, browser = boot({ guild = "Wardens", ui = true, guildInfo = "Welcome" })
		assert.is_true(browser.banner:IsShown())
		assert.equals("TOPLEFT", point(browser.banner, "TOPLEFT")[1])
		assert.is_nil(point(browser.banner, "BOTTOMRIGHT")) -- no longer squeezed next to New
		local top = browser.Inset.points[#browser.Inset.points]
		assert.equals(-74, top[5])
	end)

	it("keeps the lists up when there is no banner", function()
		local _, _, browser = boot({ guild = "Wardens", ui = true, guildInfo = "[FS1 s=0]" })
		assert.is_false(browser.banner:IsShown())
		local top = browser.Inset.points[#browser.Inset.points]
		assert.equals(-58, top[5])
	end)

	it("closes the gap left by a hidden tab", function()
		local net = Net.new({ { name = "Arch", rank = 1, archivist = true }, { name = "Mem", rank = 2 } }, { ui = true })
		local mem = net:Client("Mem")
		mem.FS:OpenBrowser()
		local browser = mem.state.frames.FrontierScoutBrowser
		local tabs = {}
		for _, tab in ipairs(browser.tabs) do tabs[tab.key] = tab end
		assert.is_false(tabs.review:IsShown())
		assert.equals(tabs.mine, point(tabs.sync, "LEFT")[2])
	end)

	it("sizes buttons to their text", function()
		local state = boot()
		local Widgets = state.ns.Widgets
		local b = Widgets.Button(frames.fake("Frame"), ("x"):rep(40), 80)
		assert.equals(40 * 6 + 24, b.width)
		local small = Widgets.Button(frames.fake("Frame"), "OK", 80)
		assert.equals(80, small.width)
	end)
end)

describe("Map panel layout", function()
	it("puts the category toggles in two rows", function()
		local state, FS = wow.boot({ guild = "Wardens", ui = true })
		state.env.C_Map = { GetMapInfo = function() end, GetBestMapForUnit = function() end }
		FS:OnEnable()
		assert.is_not_nil(state.frames.FrontierScoutMapPanel)
		local list = state.frames.FrontierScoutMapPanel.list
		assert.equals(-96, point(list, "TOPLEFT")[5])
	end)
end)

describe("Options layout", function()
	it("uses one tab per topic and a larger window", function()
		local state, FS = wow.boot({ guild = "Wardens", ui = true })
		FS:OnEnable()
		local opts = state.options.FrontierScout()
		assert.equals("tab", opts.childGroups)
		local tabs = {}
		for key, group in pairs(opts.args) do
			assert.equals("group", group.type)
			assert.is_nil(group.inline)
			tabs[#tabs + 1] = key
		end
		table.sort(tabs)
		assert.same({ "data", "general", "guild", "map" }, tabs)
		assert.equals("full", opts.args.map.args.minimap.args.edge.width)
		assert.same({ 760, 640 }, state.optionsSize)
	end)
end)
