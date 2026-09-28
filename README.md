# FrontierScout
Crowdsourced discovery addon for World of Warcraft: Forever. Automatically records new quest givers, rares, recipes and vendors as you play and shares them with other players via addon messaging, filling the gap before the databases catch up.

## Status

Milestones **M1–M4**: record discoveries, browse them by zone, see them on the world map,
minimap and tooltips, set waypoints, control by guild rank who may write, and **sync** the
archivists' discoveries to every guild member through addon messages (no external server).
Members' own submissions are still kept locally until the review queue arrives in M5.
See [docs/SPEC.md](docs/SPEC.md) for the full specification and milestone plan.

## Install (development build)

1. Copy or clone this repository into `World of Warcraft/_classic_beta_/Interface/AddOns/FrontierScout`
   (the folder name must be `FrontierScout`).
2. Start the game and enable **FrontierScout** in the AddOns list.
3. Type `/fs status` in chat.

## Using it

- **Record a discovery:** stand on the spot and type `/fs add` (or `/fs add Hidden cave` to pre-fill
  the title). With an NPC targeted, the NPC and its ID are pre-filled. At a vendor, click
  **Scout** at the top of the merchant window to record the vendor with its stock.
- **Browse:** `/fs`, the addon compartment (the addons button on the minimap), or a key binding
  (Options → Keybindings → AddOns → FrontierScout). Pick a zone on the left, search, or toggle
  categories. Select a discovery to see its details, set a waypoint, edit or delete it.
- **On the map:** discoveries show as pins on the world map and minimap. Hover for details,
  click to open them in the side panel (the **FS** button on the map toggles it), shift-click
  for a waypoint, right-click for a menu. **Ctrl + right-click** on the world map records a
  discovery at that spot.
- **Tooltips:** NPCs with a discovery and items that are noted or sold by a recorded vendor get a
  FrontierScout line.
- **Options:** `/fs config` or the game's AddOns settings: pins per category, icon size,
  tooltips, waypoints.
- **Waypoints** go to TomTom when it is installed, otherwise to Blizzard's map pin.
  `/fs waypoints native` or `/fs waypoints tomtom` forces one.

You need to be in a guild: each guild has its own discoveries, and alts in other guilds don't see them.

## Guild setup (leadership)

Until a guild is set up, only the Guild Master can write. In `/fs config` → **Guild Setup**:

1. Choose the lowest rank allowed to submit, edit or delete (own / anyone's), report, and to be an
   archivist.
2. Click **Write to Guild Info** (needs the "Edit Guild Info" guild permission). This adds a tag
   such as `[FS1 s=5 eo=5 ea=1 do=5 da=1 r=9 ar=1]` to Guild Info and leaves the rest of the text
   alone. Every member's addon reads it from there, so nobody can fake it.
3. Make archivists by adding `{FS:A}` to their **officer note**. Archivists will approve
   discoveries and share them with the guild once sync arrives.

Libraries are already included in `Libs/`; nothing else to install.

## Slash commands

| Command | Does |
|---|---|
| `/fs` | Open the discoveries browser |
| `/fs help` | List commands |
| `/fs add [title]` | Record a discovery at your position (pre-filled from your target or the open vendor) |
| `/fs waypoints [auto\|native\|tomtom]` | Show or set where waypoints go (auto = TomTom if installed) |
| `/fs config` | Open the options |
| `/fs sync` | Look for online archivists and sync now (otherwise automatic after login) |
| `/fs status` | Addon version, client build and interface, guild, number of discoveries, saved-data session count |
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

CI runs the same two commands on every pull request. The specs cover the pure modules
(Format, Store, Query, Guild), the WoW-facing ones against API stubs (Capture, Waypoint,
slash commands), and smoke-test the UI against fake frames (`tests/helpers/frames.lua`).
The fakes can't catch a wrong Blizzard API call, so UI changes still need an in-game check.

To update the embedded libraries, bump the pinned revisions in `scripts/update-libs.sh`, run it, and review the diff.
