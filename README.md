# FrontierScout
A guild-private atlas of discoveries for World of Warcraft: Forever: rares, vendors and their
stock, treasures, caves, secrets, lore, notable items and timed events. Guildmates record what
they find, archivists review it, and every member gets the same atlas through addon messages,
with no external server, filling the gap before the databases catch up.

## Status

All milestones of [docs/SPEC.md](docs/SPEC.md) (M0–M6) are implemented. Everything is covered
by automated specs, but **nothing has run in the game yet**: the next step is a beta week in
one guild, following [docs/TESTING.md](docs/TESTING.md).

- Record discoveries in seconds (position, target NPC, vendor stock) and browse them by zone.
- World map and minimap pins, a side panel on the map, tooltips on NPCs and items.
- Waypoints through TomTom or Blizzard's map pin.
- Guild isolation, rank-based permissions set in Guild Info, archivists set in officer notes.
- Review queue, and sync of the approved atlas to every member.
- English and Spanish (esES / esMX).

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
  tooltips, notifications for new discoveries in your zone, waypoints, guild setup, and data
  clean-up (other guilds' data, reset and resync).
- **Waypoints** go to TomTom when it is installed, otherwise to Blizzard's map pin.
  `/fs waypoints native` or `/fs waypoints tomtom` forces one.

You need to be in a guild: each guild has its own discoveries, and alts in other guilds don't see them.

## How sharing works

- **Archivists** (chosen by leadership, see below) keep the guild's official atlas. What they add
  or change goes to everyone right away.
- **Everyone else** submits: new discoveries, edits, deletions and "report outdated" go to the
  archivists' **Review** tab. Your **My submissions** tab shows whether each one is waiting (no
  archivist online yet: it is sent automatically when one logs in), in the queue, approved or
  rejected with the reason.
- After login, the addon quietly compares its copy with an online archivist and downloads only
  what changed. You can browse your copy offline at any time. The **Sync** tab shows the state.
- Nothing is sent outside the guild, and only archivists' data is ever accepted.

## Guild setup (leadership)

Until a guild is set up, only the Guild Master can write. In `/fs config` → **Guild Setup**:

1. Choose the lowest rank allowed to submit, edit or delete (own / anyone's), report, and to be an
   archivist.
2. Copy the tag shown under the ranks (click it, Ctrl+A, Ctrl+C), for example
   `[FS1 s=5 eo=5 ea=1 do=5 da=1 r=9 ar=1]`, and paste it on its own line in **Guild & Communities →
   Guild Info** (needs the "Edit Guild Info" guild permission). Replace any older `[FS1 ...]` tag and
   keep the rest of the text. The game doesn't let addons edit Guild Info, so this step is manual.
   Click **Check again**: the page confirms when Guild Info has the settings. Every member's addon
   reads the tag from there within a minute, so nobody can fake it.
3. **Archivists** (who approve discoveries and share them with the guild) are chosen by rank:
   tick the ranks under "Archivists: ranks that approve discoveries" (for example Guild Master and
   Officer). Every online or offline member of those ranks is listed on the page. For a stricter
   setup, tick "Also require {FS:A} in their officer note" and add `{FS:A}` to the officer notes of
   the chosen archivists.

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
