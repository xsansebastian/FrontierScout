local wow = require("tests.helpers.wow")

local FILES = { "Locales/enUS.lua", "Core/Init.lua" }

local function boot(opts)
	local state = wow.new(opts)
	local ns = wow.load(state, FILES)
	ns.FS:OnInitialize()
	state.printed = {}
	return state, ns.FS
end

local function output(state)
	return table.concat(state.printed, "\n")
end

describe("Core/Init", function()
	it("registers /fs and /frontierscout", function()
		local state = boot()
		assert.equals("OnSlashCommand", state.chatCommands.fs)
		assert.equals("OnSlashCommand", state.chatCommands.frontierscout)
	end)

	it("creates defaults on first run", function()
		local _, FS = boot({ now = 1234 })
		assert.equals(1, FS.db.global.schema)
		assert.equals(1, FS.db.global.sessions)
		assert.equals(1234, FS.db.global.firstSeen)
		assert.same({}, FS.db.global.guilds)
		assert.is_false(FS.db.profile.debug)
		assert.equals("auto", FS.db.profile.waypointMode)
	end)

	it("keeps existing saved data and counts sessions", function()
		local _, FS = boot({
			now = 9999,
			saved = { global = { sessions = 4, firstSeen = 1000, guilds = { ["club:1"] = { x = 1 } } } },
		})
		assert.equals(5, FS.db.global.sessions)
		assert.equals(1000, FS.db.global.firstSeen)
		assert.same({ x = 1 }, FS.db.global.guilds["club:1"])
	end)

	it("reports 'dev' when the version placeholder was not replaced", function()
		local _, FS = boot()
		assert.equals("dev", FS.version)
	end)

	it("reports the packaged version", function()
		local _, FS = boot({ version = "v0.1.0" })
		assert.equals("v0.1.0", FS.version)
	end)

	describe("slash commands", function()
		it("shows help for an empty command", function()
			local state = boot()
			wow.slash(state, "")
			assert.matches("Commands:", output(state), 1, true)
			assert.matches("/fs status", output(state), 1, true)
		end)

		it("shows help after an unknown command", function()
			local state = boot()
			wow.slash(state, "bogus")
			assert.matches("Unknown command: bogus", output(state), 1, true)
			assert.matches("Commands:", output(state), 1, true)
		end)

		it("is case-insensitive", function()
			local state = boot({ version = "v1" })
			wow.slash(state, "VERSION")
			assert.matches("Version: v1", output(state), 1, true)
		end)

		it("status shows client, guild and saved data", function()
			local state = boot({ guild = "Frontier Wardens", now = 1790000000 })
			wow.slash(state, "status")
			local out = output(state)
			assert.matches("interface 16001", out, 1, true)
			assert.matches("Guild: Frontier Wardens", out, 1, true)
			assert.matches("Saved data: session 1", out, 1, true)
		end)

		it("status handles no guild", function()
			local state = boot()
			wow.slash(state, "status")
			assert.matches("Guild: none", output(state), 1, true)
		end)

		it("debug toggles and persists in the profile", function()
			local state, FS = boot()
			wow.slash(state, "debug")
			assert.is_true(FS.db.profile.debug)
			assert.matches("Debug output: on", output(state), 1, true)
			wow.slash(state, "debug")
			assert.is_false(FS.db.profile.debug)
		end)
	end)

	it("Debug prints only when enabled", function()
		local state, FS = boot()
		FS:Debug("hidden %d", 1)
		assert.equals(0, #state.printed)
		FS.db.profile.debug = true
		FS:Debug("shown %d", 2)
		assert.matches("shown 2", output(state), 1, true)
	end)
end)
