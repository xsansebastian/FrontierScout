# FrontierScout
Crowdsourced discovery addon for World of Warcraft: Forever. Automatically records new quest givers, rares, recipes and vendors as you play and shares them with other players via addon messaging, filling the gap before the databases catch up.

## Status

Milestone **M0 (scaffold)**: the addon loads, keeps its saved data and answers slash commands.
See [docs/SPEC.md](docs/SPEC.md) for the full specification and milestone plan.

## Install (development build)

1. Copy or clone this repository into `World of Warcraft/_classic_beta_/Interface/AddOns/FrontierScout`
   (the folder name must be `FrontierScout`).
2. Start the game and enable **FrontierScout** in the AddOns list.
3. Type `/fs status` in chat.

Libraries are already included in `Libs/`; nothing else to install.

## Slash commands

| Command | Does |
|---|---|
| `/fs` or `/fs help` | List commands |
| `/fs status` | Addon version, client build and interface, guild, saved-data session count |
| `/fs version` | Addon version |
| `/fs debug` | Toggle debug output |

`/frontierscout` works as an alias for `/fs`.

## Development

Requires Lua 5.1, [luacheck](https://github.com/lunarmodules/luacheck) and [busted](https://github.com/lunarmodules/busted):

```sh
luarocks --lua-version=5.1 install luacheck
luarocks --lua-version=5.1 install busted
luacheck .
busted
```

CI runs the same two commands on every pull request.

To update the embedded libraries, bump the pinned revisions in `scripts/update-libs.sh`, run it, and review the diff.
