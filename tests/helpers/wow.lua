-- Minimal fake WoW + Ace environment for loading addon files outside the game.
-- Only what the addon code actually touches is stubbed; extend as modules grow.
local M = {}

local ADDON_NAME = "FrontierScout"

local function deepcopy(t)
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in pairs(t) do copy[k] = deepcopy(v) end
	return copy
end

-- Fills missing keys of `target` from `defaults`, recursively (AceDB-style).
local function applyDefaults(target, defaults)
	for k, v in pairs(defaults) do
		if type(v) == "table" then
			if type(target[k]) ~= "table" then target[k] = {} end
			applyDefaults(target[k], v)
		elseif target[k] == nil then
			target[k] = v
		end
	end
end

local function newAceDB(env)
	return {
		New = function(_, svName, defaults)
			local sv = env[svName] or {}
			env[svName] = sv
			sv.global = sv.global or {}
			sv.profiles = sv.profiles or {}
			sv.profiles.Default = sv.profiles.Default or {}
			applyDefaults(sv.global, deepcopy(defaults.global or {}))
			applyDefaults(sv.profiles.Default, deepcopy(defaults.profile or {}))
			return { global = sv.global, profile = sv.profiles.Default }
		end,
	}
end

-- The real AceSerializer and LibDeflate (pure Lua), loaded once.
local realLibs
local function loadRealLibs()
	if realLibs then return realLibs end
	local env = setmetatable({}, { __index = _G })
	for _, path in ipairs({ "Libs/LibStub/LibStub.lua", "Libs/AceSerializer-3.0/AceSerializer-3.0.lua", "Libs/LibDeflate/LibDeflate.lua" }) do
		local chunk = assert(loadfile(path))
		setfenv(chunk, env)
		chunk()
	end
	realLibs = { ["AceSerializer-3.0"] = env.LibStub("AceSerializer-3.0"), LibDeflate = env.LibStub("LibDeflate") }
	return realLibs
end

local function newAceAddon(state)
	return {
		NewAddon = function(_, name)
			local addon = { name = name }
			function addon:RegisterChatCommand(cmd, method)
				state.chatCommands[cmd] = method
			end
			function addon:Print(msg)
				state.printed[#state.printed + 1] = msg
			end
			-- AceComm subset: messages go to state.bus (see tests/helpers/net.lua).
			function addon:RegisterComm(prefix, method)
				state.commPrefix, state.commMethod = prefix, method or "OnCommReceived"
			end
			-- state.sendResult (e.g. 9, GeneralError) makes the game refuse every message;
			-- state.refuse = { CHANNEL = 8 } only messages on that distribution.
			function addon:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
				local refused = state.sendResult or (state.refuse and state.refuse[distribution])
				if refused then
					if callbackFn then callbackFn(callbackArg, #text, #text, refused) end
					return
				end
				state.sent[#state.sent + 1] = { prefix = prefix, text = text, distribution = distribution, target = target, prio = prio }
				if callbackFn then callbackFn(callbackArg, #text, #text, true) end
				if state.bus then state.bus:Send(state, prefix, text, distribution, target) end
			end
			-- AceEvent subset: records registrations, delivers messages.
			function addon:RegisterEvent(event, handler)
				state.events[event] = handler or event
			end
			function addon:RegisterMessage(message, handler)
				state.messageHandlers[message] = handler
			end
			function addon:SendMessage(message, ...)
				state.messages[#state.messages + 1] = { message, ... }
				local handler = state.messageHandlers[message]
				if type(handler) == "function" then handler(message, ...) end
			end
			-- AceConsole:GetArgs subset: first whitespace-separated word.
			function addon:GetArgs(input)
				return (input or ""):match("^%s*(%S+)")
			end
			return addon
		end,
	}
end

-- Like AceLocale: NewLocale returns a table for the default locale and the
-- client's (`clientLocale`), nil otherwise; the client's strings win.
local function newAceLocale(clientLocale)
	local locales = {}
	return {
		NewLocale = function(_, app, locale, isDefault)
			if not isDefault and locale ~= clientLocale then return nil end
			local existing = locales[app]
			locales[app] = setmetatable(existing or {}, {
				__newindex = function(t, k, v)
					if isDefault and rawget(t, k) ~= nil then return end
					rawset(t, k, v == true and k or v)
				end,
			})
			return locales[app]
		end,
		GetLocale = function(_, app)
			return setmetatable({}, {
				__index = function(_, k) return rawget(locales[app] or {}, k) or k end,
			})
		end,
	}
end

-- Builds a fresh environment. `opts.saved` pre-seeds SavedVariables,
-- `opts.guild` sets the player's guild name (nil = unguilded).
function M.new(opts)
	opts = opts or {}
	local state = { chatCommands = {}, printed = {}, events = {}, messages = {}, messageHandlers = {}, sent = {}, timers = {} }
	local env = setmetatable({}, { __index = _G })

	local libs = {
		["AceAddon-3.0"] = newAceAddon(state),
		["AceDB-3.0"] = newAceDB(env),
		["AceLocale-3.0"] = newAceLocale(opts.locale or "enUS"),
		["AceSerializer-3.0"] = loadRealLibs()["AceSerializer-3.0"],
		LibDeflate = loadRealLibs().LibDeflate,
		-- Coordinate translation is set per test through state.translate(x, y, fromMap, toMap).
		["HereBeDragons-2.0"] = {
			TranslateZoneCoordinates = function(_, x, y, from, to)
				if state.translate then return state.translate(x, y, from, to) end
			end,
		},
	}
	state.libs = libs
	env.LibStub = setmetatable({}, {
		__call = function(_, major) return assert(libs[major], "missing lib stub " .. major) end,
	})
	env.FrontierScoutDB = deepcopy(opts.saved)
	env.C_AddOns = {
		GetAddOnMetadata = function(_, field)
			if field == "Version" then return opts.version or "@project-version@" end
		end,
	}
	env.date = os.date
	env.Ambiguate = function(name) return (name:gsub("%-.*", "")) end
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.GetServerTime = function() return opts.now or 1790000000 end
	env.GetBuildInfo = function() return "1.60.1", "70009", "Sep 25 2026", 16001 end
	env.IsInGuild = function() return opts.guild ~= nil end
	-- Guild: opts.rank (default 0 = GM), opts.ranks (names), opts.roster
	-- ({ name, rankIndex, officerNote, online }), opts.guildInfo text.
	env.GetGuildInfo = function()
		if opts.guild then return opts.guild, "Rank", opts.rank or 0 end
	end
	env.GetTime = function() return state.time or 1000 end
	state.roster = opts.roster or {}
	state.guildInfo = opts.guildInfo or ""
	state.canViewNotes = opts.canViewNotes or false
	env.C_GuildInfo = {
		GuildRoster = function() state.rosterRequests = (state.rosterRequests or 0) + 1 end,
		CanViewOfficerNote = function() return state.canViewNotes end,
		CanSpeakInGuildChat = function() return state.canSpeak ~= false end,
	}
	env.C_ChatInfo = {
		IsAddonMessagePrefixRegistered = function(prefix) return not (state.unregistered and state.unregistered[prefix]) end,
		SendAddonMessage = function(prefix, text, distribution)
			state.probes = (state.probes or 0) + 1
			return state.sendResult or 0, prefix, text, distribution
		end,
	}
	-- Chat channels (only with opts.channels): numbers from 5 up.
	state.channels = {}
	if opts.channels then
		env.JoinTemporaryChannel = function(name)
			if not state.channels[name] then
				local n = 4
				for _ in pairs(state.channels) do n = n + 1 end
				state.channels[name] = n + 1
			end
		end
		env.LeaveChannelByName = function(name) state.channels[name] = nil end
		env.GetChannelName = function(name)
			local index = state.channels[name]
			if index then return index, name end
			return 0
		end
	end
	env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, NotInGroup = 5, ChannelThrottle = 8,
		GeneralError = 9 } }
	env.GetNumGuildMembers = function() return #state.roster end
	env.GetGuildRosterInfo = function(i)
		local m = state.roster[i]
		return m.name, "Rank", m.rankIndex, 60, "Warrior", "Zone", "", m.officerNote or "", m.online,
			0, "WARRIOR", 0, 0, false, false, 0, m.guid
	end
	local ranks = opts.ranks or { "Guild Master", "Officer", "Member" }
	env.GuildControlGetNumRanks = function() return #ranks end
	env.GuildControlGetRankName = function(i) return ranks[i] end
	env.GetGuildInfoText = function() return state.guildInfo end
	env.CanEditGuildInfo = function() return (opts.rank or 0) == 0 end
	-- SetGuildInfoText is protected in the game: addons can't call it.
	env.GetNormalizedRealmName = function() return "Realm" end
	env.C_Club = { GetGuildClubId = function() return opts.clubId end }
	-- opts.player = "Name" (realm "Realm"), default Scout.
	state.player = opts.player or "Scout"
	env.UnitFullName = function() return state.player, "Realm" end
	env.UnitGUID = function(unit)
		if unit == "player" then return opts.player and ("Player-1234-" .. opts.player) or "Player-1234-0ABCDEF0" end
	end
	-- Timers run when the test calls M.runTimers(state).
	env.C_Timer = {
		After = function(delay, fn) state.timers[#state.timers + 1] = { delay = delay, fn = fn } end,
		NewTicker = function(_, fn) state.tickers = state.tickers or {} state.tickers[#state.tickers + 1] = fn end,
	}
	env.InCombatLockdown = function() return false end
	env.IsInInstance = function() return false end

	state.env = env
	state.ns = {}
	return state
end

-- Loads addon files (paths relative to the repo root) in TOC order.
function M.load(state, files)
	for _, path in ipairs(files) do
		local chunk = assert(loadfile(path))
		setfenv(chunk, state.env)
		chunk(ADDON_NAME, state.ns)
	end
	return state.ns
end

-- Addon files in TOC order, read from FrontierScout.toc: Locales + Core,
-- plus UI when `withUI`.
function M.coreFiles(withUI)
	local files = {}
	for line in io.lines("FrontierScout.toc") do
		local path = line:match("^%s*((%a+)\\[^%s]+%.lua)%s*$")
		if path and (path:find("^Locales") or path:find("^Core") or (withUI and path:find("^UI"))) then
			files[#files + 1] = (path:gsub("\\", "/"))
		end
	end
	return files
end

-- Loads Locales + Core (and UI with opts.ui, on fake frames) and runs
-- OnInitialize; returns state, FS, ns.
function M.boot(opts)
	local state = M.new(opts)
	if opts and opts.ui then require("tests.helpers.frames").install(state.env, state) end
	local ns = M.load(state, M.coreFiles(opts and opts.ui))
	ns.FS:OnInitialize()
	state.printed = {}
	return state, ns.FS, ns
end

-- Decodes a sent message ({ prefix, text } from state.sent or a net queue
-- item); returns the message and, for addressed messages, the recipient.
function M.decode(ns, item)
	local text, to = item.text, nil
	if item.prefix == ns.Comm.PREFIX_TO then to, text = ns.Comm.Unaddress(text) end
	return ns.Comm.Decode(text), to
end

-- Runs (and clears) pending C_Timer.After callbacks.
function M.runTimers(state)
	local pending = state.timers
	state.timers = {}
	for _, t in ipairs(pending) do t.fn() end
	return #pending
end

-- Delivers a game event to the addon's registered handler.
function M.fire(state, event, ...)
	local handler = assert(state.events[event], "no handler for " .. event)
	if type(handler) == "string" then
		state.ns.FS[handler](state.ns.FS, event, ...)
	else
		handler(event, ...)
	end
end

-- Runs a slash command the way WoW would (e.g. "status").
function M.slash(state, input)
	local method = state.chatCommands.fs
	state.ns.FS[method](state.ns.FS, input)
end

return M
