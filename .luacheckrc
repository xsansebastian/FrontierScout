std = "lua51"
max_line_length = false
exclude_files = { "Libs/", ".luarocks/", "lua_modules/" }

-- WoW API used by the addon. Keep sorted; add as modules grow.
read_globals = {
	"C_AddOns",
	"GetBuildInfo",
	"GetGuildInfo",
	"GetServerTime",
	"IsInGuild",
	"LibStub",
	"date",
}

files["tests/"] = {
	std = "+busted",
	self = false,
	read_globals = { "setfenv" },
}
