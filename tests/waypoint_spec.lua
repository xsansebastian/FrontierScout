local wow = require("tests.helpers.wow")

local ENTRY = { title = "Old Grizzlegut", map = 100, x = 0.5, y = 0.5 }

-- Map 100 (a cave) doesn't allow user waypoints; its parent 1 does.
local function boot(opts)
	local state, FS = wow.boot()
	local calls = { native = {}, tomtom = {} }
	state.env.C_Map = {
		CanSetUserWaypointOnMap = function(map) return map == 1 end,
		GetMapInfo = function(map)
			if map == 100 then return { parentMapID = 1 } end
			return { parentMapID = 0 }
		end,
		SetUserWaypoint = function(point) calls.native[#calls.native + 1] = point end,
	}
	state.env.UiMapPoint = {
		CreateFromCoordinates = function(map, x, y) return { map = map, x = x, y = y } end,
	}
	state.env.C_SuperTrack = { SetSuperTrackedUserWaypoint = function(on) calls.supertrack = on end }
	state.translate = function(x, y, from, to)
		if from == 100 and to == 1 then return x / 10 + 0.3, y / 10 + 0.3 end
	end
	if opts and opts.tomtom then
		state.env.TomTom = {
			AddWaypoint = function(_, map, x, y, o) calls.tomtom[#calls.tomtom + 1] = { map, x, y, o.title, o.from } end,
		}
	end
	return FS, calls
end

describe("FS:SetWaypoint", function()
	it("uses TomTom in auto mode when it is loaded", function()
		local FS, calls = boot({ tomtom = true })
		assert.same({ true, "tomtom" }, { FS:SetWaypoint(ENTRY) })
		assert.same({ { 100, 0.5, 0.5, "Old Grizzlegut", "FrontierScout" } }, calls.tomtom)
		assert.equals(0, #calls.native)
	end)

	it("falls back to the native waypoint, climbing to a parent map", function()
		local FS, calls = boot()
		assert.same({ true, "native" }, { FS:SetWaypoint(ENTRY) })
		assert.same({ { map = 1, x = 0.35, y = 0.35 } }, calls.native)
		assert.is_true(calls.supertrack)
	end)

	it("uses the native waypoint in native mode even with TomTom", function()
		local FS, calls = boot({ tomtom = true })
		FS.db.profile.waypointMode = "native"
		assert.same({ true, "native" }, { FS:SetWaypoint({ title = "x", map = 1, x = 0.1, y = 0.2 }) })
		assert.same({ { map = 1, x = 0.1, y = 0.2 } }, calls.native)
		assert.equals(0, #calls.tomtom)
	end)

	it("fails in tomtom mode without TomTom", function()
		local FS = boot()
		FS.db.profile.waypointMode = "tomtom"
		assert.same({ false, "notomtom" }, { FS:SetWaypoint(ENTRY) })
	end)

	it("fails when no map in the chain allows waypoints", function()
		local FS, calls = boot()
		assert.same({ false, "nomap" }, { FS:SetWaypoint({ title = "x", map = 50, x = 0.1, y = 0.1 }) })
		assert.equals(0, #calls.native)
	end)

	it("prints feedback", function()
		local state, FS = wow.boot()
		FS.SetWaypoint = function() return false, "nomap" end
		FS:Waypoint(ENTRY)
		assert.matches("does not allow waypoints", state.printed[1], 1, true)
	end)
end)
