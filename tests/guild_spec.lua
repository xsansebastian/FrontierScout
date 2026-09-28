local wow = require("tests.helpers.wow")

describe("Guild keys and buckets", function()
	local Guild
	setup(function()
		local _, _, ns = wow.boot()
		Guild = ns.Guild
	end)

	it("prefers the club ID and falls back to realm + name", function()
		assert.equals("club:42", Guild.MakeKey(42, "Realm", "Wardens"))
		assert.equals("name:Realm:Wardens", Guild.MakeKey(nil, "Realm", "Wardens"))
		assert.is_nil(Guild.MakeKey(nil, nil, "Wardens"))
	end)

	it("creates a bucket with meta", function()
		local guilds = {}
		local key, bucket = Guild.Resolve(guilds, nil, "Realm", "Wardens", 100)
		assert.equals("name:Realm:Wardens", key)
		assert.equals(bucket, guilds[key])
		assert.same({ name = "Wardens", realm = "Realm", lastSeen = 100 }, bucket.meta)
		assert.same({}, bucket.entries)
	end)

	it("moves a name bucket to the club key once the club ID is known", function()
		local guilds = { ["name:Realm:Wardens"] = { entries = { e = 1 } } }
		local key, bucket = Guild.Resolve(guilds, 42, "Realm", "Wardens", 100)
		assert.equals("club:42", key)
		assert.same({ e = 1 }, bucket.entries)
		assert.is_nil(guilds["name:Realm:Wardens"])
	end)

	it("does not overwrite an existing club bucket", function()
		local guilds = { ["name:Realm:Wardens"] = { entries = { old = 1 } }, ["club:42"] = { entries = { new = 1 } } }
		local _, bucket = Guild.Resolve(guilds, 42, "Realm", "Wardens", 100)
		assert.same({ new = 1 }, bucket.entries)
		assert.is_not_nil(guilds["name:Realm:Wardens"])
	end)
end)

describe("FS:RefreshGuild", function()
	local function changes(state)
		local n = 0
		for _, m in ipairs(state.messages) do
			if m[1] == "FRONTIERSCOUT_GUILD_CHANGED" then n = n + 1 end
		end
		return n
	end

	it("registers guild events on enable", function()
		local state, FS = wow.boot()
		FS:OnEnable()
		state.env.IsInGuild = function() return true end
		state.env.GetGuildInfo = function() return "Wardens" end
		wow.fire(state, "PLAYER_GUILD_UPDATE")
		assert.equals("name:Realm:Wardens", FS.guildKey)
		assert.is_function(state.events.PLAYER_ENTERING_WORLD)
	end)

	it("activates the guild bucket and announces it once", function()
		local state, FS = wow.boot({ guild = "Wardens", clubId = 7 })
		FS:RefreshGuild()
		FS:RefreshGuild()
		assert.equals("club:7", FS.guildKey)
		assert.is_not_nil(FS:GetStore(true))
		assert.equals(1, changes(state))
	end)

	it("has no store without a guild", function()
		local _, FS = wow.boot()
		FS:RefreshGuild()
		assert.is_nil(FS.guildKey)
		assert.is_nil(FS:GetStore(true))
	end)

	it("waits while guild info is still loading", function()
		local state, FS = wow.boot({ guild = "Wardens" })
		state.env.GetGuildInfo = function() return nil end
		FS:RefreshGuild()
		assert.is_nil(FS.guildKey)
		assert.equals(0, changes(state))
		assert.is_nil(FS:GetStore())
		assert.matches("still loading", state.printed[1], 1, true)
	end)

	it("keeps alts in different guilds apart", function()
		local state, FS = wow.boot({ guild = "Wardens" })
		FS:RefreshGuild()
		FS:SaveEntry(nil, { cat = "location", sub = "cave", title = "Cave", map = 1, x = 0.1, y = 0.1 })
		state.env.GetGuildInfo = function() return "Other Guild" end
		FS:RefreshGuild()
		assert.equals("name:Realm:Other Guild", FS.guildKey)
		assert.equals(0, FS.store:Count())
		assert.equals(2, changes(state))
	end)

	it("collects old tombstones when a bucket is activated", function()
		local saved = { global = { guilds = { ["name:Realm:Wardens"] = { entries = {
			old = { id = "old", deleted = true, rev = 2, approvedAt = 1 },
		} } } } }
		local _, FS = wow.boot({ guild = "Wardens", saved = saved, now = 1790000000 })
		FS:RefreshGuild()
		assert.is_nil(FS.db.global.guilds["name:Realm:Wardens"].entries.old)
	end)
end)
