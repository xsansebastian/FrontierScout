local wow = require("tests.helpers.wow")
local Net = require("tests.helpers.net")

-- M6: notifications, "new since last login", data options, performance.

local function data(title, map)
	return { cat = "location", sub = "treasure", title = title, map = map or 1, x = 0.5, y = 0.5 }
end

local MAPS = {
	[1] = { name = "Durotar", mapType = 3, parentMapID = 0 },
	[7] = { name = "Mulgore", mapType = 3, parentMapID = 0 },
}

local function withMaps(client)
	client.state.env.C_Map = {
		GetMapInfo = function(map) return MAPS[map] end,
		GetBestMapForUnit = function() return 1 end,
	}
end

describe("Notifications", function()
	local function network()
		local net = Net.new({ { name = "Arch", rank = 1, archivist = true }, { name = "Mem", rank = 2 } }, { ui = true })
		for _, c in ipairs(net.clients) do withMaps(c) end
		net:Tick()
		return net
	end

	local function printed(client) return table.concat(client.state.printed, "\n") end

	it("announce a new discovery in my zone only", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		arch.FS:SaveEntry(nil, data("Far away", 7))
		net:Flush()
		assert.is_nil(printed(mem):find("New discovery", 1, true))
		arch.FS:SaveEntry(nil, data("Right here", 1))
		net:Flush()
		assert.matches("New discovery in Durotar: Right here (Treasure)", printed(mem), 1, true)
	end)

	it("summarize a batch and skip edits", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		arch.state.bus = nil
		local first
		for i = 1, 4 do
			local e = arch.FS:SaveEntry(nil, data("Spot " .. i))
			first = first or e
		end
		arch.state.bus = net
		mem.FS:SayHello(true)
		net:Flush()
		assert.matches("4 new discoveries in Durotar", printed(mem), 1, true)
		mem.state.printed = {}
		arch.FS:SaveEntry(first.id, data("Spot 1, renamed"))
		net:Flush()
		assert.equals("", printed(mem))
	end)

	it("respect the settings", function()
		local net = network()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		mem.FS.db.profile.notify.chat = false
		local toasts = {}
		mem.state.env.UIErrorsFrame = { AddMessage = function(_, text) toasts[#toasts + 1] = text end }
		arch.FS:SaveEntry(nil, data("Quiet"))
		net:Flush()
		assert.equals("", printed(mem))
		assert.same({}, toasts)
		mem.FS.db.profile.notify.toast = true
		arch.FS:SaveEntry(nil, data("Loud"))
		net:Flush()
		assert.same({ "New discovery in Durotar: Loud (Treasure)" }, toasts)
	end)
end)

describe("New since last login", function()
	it("compares with the previous session's start", function()
		local saved = { global = { guilds = { ["name:Realm:Wardens"] = {
			meta = { sessionStart = 1500 },
			entries = {
				old = { id = "old", cat = "location", sub = "cave", title = "Old", map = 1, x = 0.1, y = 0.1, rev = 1, approvedAt = 1000 },
				new = { id = "new", cat = "location", sub = "cave", title = "New", map = 1, x = 0.1, y = 0.1, rev = 1, approvedAt = 2000 },
			},
		} } } }
		local state, FS = wow.boot({ guild = "Wardens", ui = true, saved = saved, now = 3000 })
		FS:OnEnable()
		assert.equals(1500, FS.newSince)
		assert.equals(3000, FS.db.global.guilds["name:Realm:Wardens"].meta.sessionStart)
		FS:OpenBrowser()
		local browser = state.frames.FrontierScoutBrowser
		browser.newOnly:SetChecked(true)
		browser.newOnly:Click()
		assert.equals(1, #browser.entries.rows)
		assert.matches("New |cff33ff33new|r", browser.entries.rows[1].label:GetText(), 1, true)
	end)
end)

describe("Data options", function()
	it("purge other guilds' data", function()
		local saved = { global = { guilds = { ["name:Realm:Old guild"] = { meta = { name = "Old guild" }, entries = {} } } } }
		local state, FS = wow.boot({ guild = "Wardens", ui = true, saved = saved })
		FS:OnEnable()
		local args = state.options.FrontierScout().args.data.args
		assert.matches("Old guild", args.others.name(), 1, true)
		args.purge.func()
		assert.is_nil(FS.db.global.guilds["name:Realm:Old guild"])
		assert.is_not_nil(FS.db.global.guilds["name:Realm:Wardens"])
		assert.is_true(args.purge.disabled())
	end)

	it("reset and resync, but not as the only archivist online", function()
		local net = Net.new({ { name = "Arch", rank = 1, archivist = true }, { name = "Mem", rank = 2 } }, { ui = true })
		net:Tick()
		local arch, mem = net:Client("Arch"), net:Client("Mem")
		arch.FS:SaveEntry(nil, data("Keep me"))
		net:Flush()
		local memArgs = mem.state.options.FrontierScout().args.data.args
		assert.is_false(memArgs.reset.disabled())
		memArgs.reset.func()
		assert.equals(0, mem.FS.store:Count())
		net:Flush()
		assert.equals(1, mem.FS.store:Count())
		assert.is_true(arch.state.options.FrontierScout().args.data.args.reset.disabled())
	end)
end)

describe("Performance at the 5,000-entry cap", function()
	local function timed(fn)
		local t = os.clock()
		fn()
		return os.clock() - t
	end

	it("stores, digests, searches and browses quickly", function()
		local state, FS, ns = wow.boot({ guild = "Wardens", ui = true })
		state.env.C_Map = {
			GetMapInfo = function(map) return { name = "Zone " .. map, mapType = 3, parentMapID = 0 } end,
			GetBestMapForUnit = function() return 1 end,
		}
		FS:OnEnable()
		local create = timed(function()
			for i = 1, 5000 do
				FS.store:Create({ cat = "npc", sub = "vendor", title = "Vendor " .. i, map = 1 + i % 40, x = 0.5, y = 0.5,
					desc = ("text "):rep(20), items = { { id = i, cost = "1g" } } }, { id = "E-" .. i, by = "A-Realm", now = 1000 + i })
			end
		end)
		assert.equals(5000, FS.store:Count())
		assert.same({ nil, "full" }, { FS.store:Create(data("One too many"), { id = "E-x", by = "A-Realm", now = 1 }) })
		local rebuild = timed(function() ns.Store.New(FS.store.bucket).digest:Root() end)
		FS:OpenBrowser()
		local browser = state.frames.FrontierScoutBrowser
		browser.search:SetText("vendor 4")
		local search = timed(function()
			browser.search.scripts.OnTextChanged(browser.search)
			browser.search.scripts.OnTextChanged(browser.search)
		end)
		-- Generous budgets for plain Lua 5.1 on a CI machine.
		assert.is_true(create < 3, "create took " .. create)
		assert.is_true(rebuild < 1, "digest rebuild took " .. rebuild)
		assert.is_true(search < 2, "two browser refreshes took " .. search)
	end)
end)
