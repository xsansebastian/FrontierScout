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
			-- AceConsole:GetArgs subset: first whitespace-separated word.
			function addon:GetArgs(input)
				return (input or ""):match("^%s*(%S+)")
			end
			return addon
		end,
	}
end

local function newAceLocale()
	local locales = {}
	return {
		NewLocale = function(_, app)
			locales[app] = setmetatable({}, {
				__newindex = function(t, k, v) rawset(t, k, v == true and k or v) end,
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
	local state = { chatCommands = {}, printed = {} }
	local env = setmetatable({}, { __index = _G })

	local libs = {
		["AceAddon-3.0"] = newAceAddon(state),
		["AceDB-3.0"] = newAceDB(env),
		["AceLocale-3.0"] = newAceLocale(),
	}
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
	env.GetServerTime = function() return opts.now or 1790000000 end
	env.GetBuildInfo = function() return "1.60.1", "70009", "Sep 25 2026", 16001 end
	env.IsInGuild = function() return opts.guild ~= nil end
	env.GetGuildInfo = function() return opts.guild end

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

-- Runs a slash command the way WoW would (e.g. "status").
function M.slash(state, input)
	local method = state.chatCommands.fs
	state.ns.FS[method](state.ns.FS, input)
end

return M
