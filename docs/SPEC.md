# FrontierScout — Specification

> Status: **Draft v0.1** — for review before any implementation.
> Target: **WoW Forever** (Blizzard, beta as of Sept 2026, launch Nov 4 2026), which runs the
> Mainline (Midnight, 12.x) UI/API.

---

## 1. Overview

FrontierScout lets a guild build a **shared, private atlas of discoveries**: rare NPCs,
vendors, hidden locations, treasures, notable item drops, timed events — anything worth
telling guildmates about. Discoveries are:

- **Guild-isolated** — data is stored, synced and displayed per guild; nothing leaves the guild.
- **Curated** — members submit, designated **archivists** approve; only approved data is shown.
- **ACL-controlled** — which guild ranks may create / edit / delete is configured by guild leadership.
- **Visible where you need it** — world map pins, minimap pins, a map side panel, and a zone browser.
- **Navigable** — one click sets a waypoint (TomTom if installed, otherwise Blizzard's native waypoint).

### 1.1 Goals

1. Capture a discovery in under 10 seconds (pre-filled from player position / target / open vendor).
2. Every guild member converges on the same approved dataset without any external server.
3. Leadership fully controls who can write, and a modified client cannot inject approved data.
4. Zero combat impact; no interaction with Midnight's protected combat data.

### 1.2 Non-goals (v1)

- **Routes / polylines** — deferred to v2 (data model leaves room, see §5.6).
- Cross-guild or public sharing, web export, external database.
- Per-rank *read* visibility — every guild member sees every approved entry.
- Combat-related features of any kind.

---

## 2. Platform & constraints

| Topic | Decision |
|---|---|
| Client | WoW Forever, Mainline 12.x API. `## Interface:` number to be confirmed in beta via `/dump select(4, GetBuildInfo())`. |
| Lua | 5.1 (WoW flavour), `bit` library available. |
| Maps | `C_Map` (uiMapID-based). Positions stored as uiMapID + normalized x/y. |
| Comms | `C_ChatInfo.SendAddonMessage` via AceComm, channels `GUILD` and `WHISPER` only. |
| Waypoints | `C_Map.SetUserWaypoint` + `C_SuperTrack` (native) or TomTom API. |
| Midnight restrictions | Addon comms and some unit data are restricted in combat / instanced content, and some values can be *secret* (`issecretvalue`). FrontierScout is open-world only and **pauses all sync while `InCombatLockdown()` or `IsInInstance()`**, checks the `Enum.SendAddonMessageResult` return value, and never reads unit data that is secret. |

### 2.1 Embedded libraries

| Library | Purpose |
|---|---|
| LibStub, CallbackHandler-1.0 | Library plumbing |
| AceAddon-3.0, AceEvent-3.0, AceTimer-3.0, AceConsole-3.0 | Addon lifecycle, events, timers, slash commands |
| AceDB-3.0 | SavedVariables with profiles |
| AceComm-3.0 (+ ChatThrottleLib) | Chunked, throttled addon messages |
| AceSerializer-3.0 | Table serialization |
| LibDeflate | Compression + addon-channel-safe encoding |
| HereBeDragons-2.0, HereBeDragons-Pins-2.0 | World map and minimap pins, coordinate translation |
| LibDataBroker-1.1, LibDBIcon-1.0 | Minimap / broker launcher |
| AceConfig-3.0, AceConfigDialog-3.0, AceGUI-3.0 | Options panel only |

The browser window and map side panel use native frames (`ScrollBox` + `DataProvider`) for
performance.

---

## 3. Guild isolation

### 3.1 Guild key

Every piece of data is namespaced by a **guild key**:

```
guildKey = "club:" .. C_Club.GetGuildClubId()                        -- primary (stable across renames)
         | "name:" .. GetNormalizedRealmName() .. ":" .. guildName   -- fallback if clubId unavailable
```

*Beta check:* confirm that `C_Club.GetGuildClubId()` is available and stable on Forever. If it
isn't, use the fallback only.

### 3.2 Storage isolation

`FrontierScoutDB` (account-wide SavedVariables) is structured as:

```lua
FrontierScoutDB = {
  schema = 1,
  guilds = {
    [guildKey] = {
      meta      = { name = "Guild Name", realm = "Realm", lastSeen = <time> },
      entries   = { [entryId] = Entry, ... },       -- approved canonical set (+ tombstones)
      outbox    = { [proposalId] = Proposal, ... }, -- my submissions not yet acknowledged
      mine      = { [proposalId] = ProposalStatus }, -- history of my submissions & decisions
      queue     = { [proposalId] = Proposal, ... }, -- archivists only: pending review
      syncState = { lastFullSync = <time>, digest = {...} },
    },
  },
  profile = { ... UI settings (AceDB profile) ... },
}
```

- A character's **active bucket** is chosen from its current guild on `PLAYER_GUILD_UPDATE`
  / login. Alts in different guilds on the same account never see each other's data.
- A character with no guild has no active bucket: the UI shows "Join a guild to use FrontierScout".
- If you leave a guild, its bucket stays but is hidden. Options → "Purge data for guilds I'm no
  longer in".

### 3.3 Transport isolation

- AceComm prefix: **`FScout`** (≤16 chars), registered with `C_ChatInfo.RegisterAddonMessagePrefix`.
- Channels: **`GUILD`** (broadcasts) and **`WHISPER`** (targeted transfers) only. Never
  `PARTY`/`RAID`/custom channels.
- Every message envelope carries `v` (protocol version) and `g` (guildKey). Messages whose `g`
  doesn't match the receiver's active guildKey are dropped.
- `WHISPER` messages are accepted **only if the sender is in the current guild roster**
  (roster cache, §4.5). This blocks outsiders from whispering data in.

---

## 4. Roles, ACL & trust

### 4.1 Roles

| Role | Can |
|---|---|
| **Member** | Read approved entries, set waypoints, report an entry as outdated. |
| **Contributor** | Member + submit proposals, as far as the ACL allows (§4.2). |
| **Archivist** | Approve/reject proposals, serve the canonical dataset, auto-approve own edits. |
| **Leadership** | Anyone who can edit Guild Info or officer notes; configures ACL and archivists through in-game guild permissions. |

### 4.2 Per-action ACL

Each action has a **rank threshold**. A player may perform the action if
`rankIndex <= threshold` (`rankIndex` is 0-based, 0 = Guild Master, as returned by
`GetGuildRosterInfo`).

| Key | Action |
|---|---|
| `s`  | Submit a new discovery |
| `eo` | Propose an edit to an entry *you authored* |
| `ea` | Propose an edit to *any* entry |
| `do` | Propose deletion of an entry *you authored* |
| `da` | Propose deletion of *any* entry |
| `r`  | Report an entry as outdated (defaults to all ranks) |
| `ar` | **Archivist minimum rank** — the rank gate, §4.4 |

All write actions produce **proposals** that an archivist has to approve. The ACL decides which
proposals are valid; archivists decide which valid proposals are published.

### 4.3 Where configuration lives

Two in-game storage locations. Blizzard enforces write permission on both, so a spoofed
message can't change them.

**a) Guild Info tag: ACL thresholds.** Readable by every member (`GetGuildInfoText()`),
writable only by ranks with "Edit Guild Info" (`CanEditGuildInfo()`).

```
[FS1 s=5 eo=5 ea=1 do=5 da=1 r=9 ar=1]
```

- `FS1` = tag schema version. Parsed with a single Lua pattern; missing keys fall back to defaults.
- Default when there is no tag: `s=0 eo=0 ea=0 do=0 da=0 r=9 ar=0` (GM-only writes) and a banner
  telling leadership to configure the addon.
- Options → *Guild Setup* shows rank names next to each threshold, previews the tag, and has a
  **Write to Guild Info** button (only enabled when `CanEditGuildInfo()` is true). It appends or
  replaces the tag and leaves the rest of the guild info text untouched.

**b) Officer notes: archivist designation.** An archivist's officer note contains the token
`{FS:A}` (6 chars; officer notes allow 31). Only ranks with "Edit Officer Note" can set it,
and only ranks with "View Officer Note" (`C_GuildInfo.CanViewOfficerNote()`) can read it.

### 4.4 Archivist verification (hybrid "officer note + rank gate")

A client decides whether player **P** is an archivist as follows:

```
if P.rankIndex > ar then                       -- everyone can see ranks
    return false
elseif C_GuildInfo.CanViewOfficerNote() then   -- officer-capable viewer
    return P.officerNote contains "{FS:A}"
else                                           -- regular member
    return true                                -- rank gate only
end
```

- **Officer-capable clients** do full verification.
- **Regular members** trust anyone at or above the `ar` rank. Residual risk: an officer-rank
  player without the tag could pose as an archivist to regular members. That's acceptable,
  because officer ranks are already highly trusted. Officer clients that see an untagged
  high-rank player serving data log a warning in the Archivist tab.
- Setting `ar` to the officer rank(s) makes the rank gate and the officer-note permission
  cover the same people.

### 4.5 Roster cache

- Built from `GetGuildRosterInfo(i)` on `GUILD_ROSTER_UPDATE`. Refreshes are requested with
  `C_GuildInfo.GuildRoster()`, at most once per 15 s (Blizzard throttle).
- Stores `fullName (Name-Realm) → { rankIndex, officerNoteHasTag, online }`.
- All ACL and archivist checks go through the cache and use **current** rank at receive time.
- Names are always normalized to `Name-Realm` (`Ambiguate` only for display).

### 4.6 Rank changes & revocation

- Checks happen **at receive time**. If an archivist is demoted, entries they already approved
  stay valid (they are part of the canonical set), but the demoted player can't serve or
  approve anything new.
- If an archivist is compromised, another archivist can review entries (Browser filter
  "approved by X") and delete them.

---

## 5. Data model

### 5.1 Entry (canonical, approved)

```lua
Entry = {
  id        = "E-<authorGUIDsuffix>-<serverTime>-<n>", -- globally unique, created by the author
  cat       = "npc" | "location" | "item" | "event",
  sub       = "<subtype>",            -- see 5.2
  title     = "string ≤ 64",
  desc      = "string ≤ 500",         -- plain text; |cff…/|H links stripped, except item links
  map       = uiMapID,
  x, y      = 0..1 (4 decimals),
  -- optional, category-specific
  npcID     = number?,
  items     = { {id=itemID, cost="string?"} ... }?, -- vendor stock / notable drops
  schedule  = { respawnMin=number?, window="string?", note="string?" }?,
  tags      = { "string", ... }?,     -- max 5, ≤ 16 chars each
  -- provenance
  author    = "Name-Realm",
  createdAt = serverTime,
  rev       = integer,                -- increments on every approved change
  editedBy  = "Name-Realm",
  approvedBy= "Name-Realm",
  approvedAt= serverTime,             -- from GetServerTime()
  deleted   = true?,                  -- tombstone
  flags     = integer?,               -- count of open "outdated" reports
}
```

### 5.2 Categories & subtypes (v1)

| Category | Subtypes | Auto-capture |
|---|---|---|
| `npc` | `rare`, `vendor`, `trainer`, `notable` | Target's npcID + name from `UnitGUID("target")`. For vendors, stock from `MERCHANT_SHOW` (`GetMerchantNumItems`, `GetMerchantItemLink`, cost). |
| `location` | `treasure`, `cave`, `secret`, `lore`, `hotspot` | Player position |
| `item` | `drop`, `quest-item`, `curiosity` | Item link dropped/pasted into the dialog; player position as the "found here" spot |
| `event` | `world-event`, `timed-spawn` | Player position; manual schedule fields |

Every auto-capture checks `issecretvalue()` before reading, and skips when in combat or instanced.

### 5.3 Proposal

```lua
Proposal = {
  pid     = "P-<authorGUIDsuffix>-<serverTime>-<n>",
  op      = "create" | "edit" | "delete" | "report",
  eid     = entryId,           -- target (for create: the new id)
  baseRev = integer?,          -- rev the edit/delete was based on
  data    = Entry-subset?,     -- create/edit payload
  reason  = "string ≤ 200"?,   -- delete/report
  author  = "Name-Realm",
  at      = serverTime,
}
```

### 5.4 Lifecycle

```
            submit                 approve
 draft ───────────▶ pending ───────────────▶ approved (rev+1, broadcast)
                      │
                      │ reject (with reason)
                      ▼
                   rejected  (author notified; stays in "My Submissions")
```

- **Edit conflicts**: when `baseRev < entry.rev` at approval time, the review UI shows a diff
  against the current entry and warns the archivist.
- **Delete** produces a tombstone (`deleted=true`, rev+1). Tombstones are kept **90 days** so
  they propagate, then garbage-collected.
- **Report outdated** increments `flags` on archivist clients and shows in the review queue.
  An archivist resolves it with an edit, a delete, or "dismiss".
- An archivist's own create/edit/delete is **auto-approved** (still recorded with `approvedBy`).

### 5.5 Coordinates

- Captured with `C_Map.GetBestMapForUnit("player")` + `C_Map.GetPlayerMapPosition(map, "player")`.
- Map-click capture: right-click on the world map canvas → "Add discovery here" uses
  `WorldMapFrame:GetNormalizedCursorPosition()` and the displayed map ID.
- HereBeDragons translates coordinates between parent and child maps for display.

### 5.6 Forward compatibility (routes, v2)

The entry schema reserves `cat="route"` with `points={ {x,y}, ... }` on a single map. Clients
must **ignore unknown categories** rather than error.

---

## 6. Sync protocol

### 6.1 Principles

- **Archivists are the source of truth.** Members only accept canonical data (`ENT`, `APPR`)
  from senders who pass the archivist check (§4.4).
- **Members don't relay canonical data** to each other.
- **Offline tolerance**: members keep a local copy and can browse it with no archivist online.
  Submissions wait in the `outbox` until an archivist appears.
- **Archivists sync with each other**, so the canonical set and the pending queue converge
  across archivists.

### 6.2 Versioning & conflict resolution

- Each entry has `(rev, approvedAt, approvedBy)`. When two versions of an entry meet, the
  winner is decided by **higher `rev`, then later `approvedAt`, then lexically greater
  `approvedBy`**. The result is deterministic and converges.
- **Dataset digest**: entries are hashed into **64 buckets** by `fnv1a32(id) % 64`. Each bucket's
  hash is the FNV-1a of the sorted `id:rev:approvedAt` lines. The root hash is the FNV-1a of the
  64 bucket hashes. Digests are updated incrementally when entries change.

### 6.3 Envelope

```lua
{ v = 1, g = guildKey, t = "<TYPE>", ... payload }
-- AceSerializer → LibDeflate:CompressDeflate → LibDeflate:EncodeForWoWAddonChannel
```

### 6.4 Messages

| Type | Channel | From → To | Payload | Purpose |
|---|---|---|---|---|
| `HELLO` | GUILD | any → all | `root, count, role` | Announce presence after login (15–45 s random delay) |
| `ARCH` | GUILD | archivist → all | `root, count` | Answer to `HELLO` / periodic beacon (≤ 1 per 10 min) |
| `SYNCREQ` | WHISPER | member → archivist | `buckets[64]` | Ask for diff when root differs |
| `MANIFEST` | WHISPER | archivist → member | `{ [bucket] = { id=rev:approvedAt, ... } }` | Details for mismatched buckets only |
| `WANT` | WHISPER | member → archivist | `ids[]` | Request entries the member lacks or has older |
| `ENT` | WHISPER | archivist → member | `entries[]` (≤ 20 per msg) | Bulk transfer, `BULK` priority |
| `PROP` | WHISPER | contributor → each online archivist | `Proposal` | Submit |
| `PACK` | WHISPER | archivist → contributor | `pid, status="queued"` | Ack. Contributor moves the item from `outbox` to `mine` |
| `APPR` | GUILD | archivist → all | `Entry` (single) | Live push of a newly approved revision |
| `REJ` | WHISPER | archivist → author | `pid, reason` | Rejection notice (stored for next login if offline) |
| `QSYNC` | WHISPER | archivist ↔ archivist | pending-queue digest + items | Keep review queues and decisions consistent |

### 6.5 Flows

**Member login**

1. Load the local bucket. The UI is usable immediately.
2. After a random 15–45 s delay: `HELLO` on GUILD.
3. Online archivists answer with `ARCH`. The member picks one (lowest server load: random among
   responders) and, if the root differs, runs `SYNCREQ → MANIFEST → WANT → ENT`.
4. Flush the `outbox`: send each pending `PROP` to every online archivist. Resend until `PACK`.

**Submission**

1. The contributor fills the dialog. The client checks the ACL locally (grays out disallowed actions).
2. Create the `Proposal` → `outbox` → `PROP` to online archivists (or wait).
3. Each receiving archivist re-checks the sender's roster membership and the ACL for `op`
   (`eo`/`do` also require `entry.author == sender`). Valid proposals go into `queue` and get
   `PACK`; invalid ones are dropped silently and logged.

**Review**

1. An archivist opens the Review tab, sees the proposal, the diff and a map preview, and
   clicks Approve or Reject.
2. Approve → apply to `entries` (rev+1) → `APPR` on GUILD → other archivists and online members
   apply it. The proposal is marked decided in `QSYNC`, so other archivists drop it from their queues.
3. Reject → `REJ` to the author (or held until the author's next `HELLO`).

### 6.6 Limits & throttling

- ChatThrottleLib via AceComm: `ALERT` priority for control messages, `BULK` for `ENT`.
- Maximum outgoing `ENT` bandwidth per archivist: ~1 KB/s. At most **2 concurrent member syncs**
  per archivist; others are told to retry later (`BUSY`).
- Receive-side rate limit: messages from a single sender beyond 30/min are dropped (anti-spam).
- Sync is **paused** in combat / instances and resumes on `PLAYER_REGEN_ENABLED` /
  `ZONE_CHANGED_NEW_AREA`.
- Hard caps: 5,000 entries per guild. Oversized fields are truncated on receipt.

---

## 7. User interface

### 7.1 World map pins

- HereBeDragons-Pins `AddWorldMapIconMap`, with one icon per category/subtype (Blizzard atlas
  icons, no custom art needed for v1).
- Hover: tooltip with title, subtype, description excerpt, author, "approved by", respawn/schedule.
- Click: opens the entry in the side panel. Shift-click: set waypoint. Right-click: context
  menu (Waypoint, Edit, Delete, Report outdated).
- Filter dropdown added to the world map's tracking/filter button area: toggle categories and
  subtypes.

### 7.2 Minimap pins

- HereBeDragons-Pins `AddMinimapIconMap`, same icons at smaller size, optional edge-clamp for
  nearby entries (configurable radius).
- Per-category toggle, separate from the world map filters.

### 7.3 Map side panel

- A collapsible panel docked to the right edge of `WorldMapFrame`, with a toggle button on the map.
- Lists entries on the **currently displayed map** (and its child zones when you're viewing a
  continent), grouped by category, with a search box.
- Hovering a row highlights (pulses) its pin. Clicking selects it and shows the detail view
  inside the panel.
- Listens to map changes through the map canvas callbacks (`WorldMapFrame:GetMapID()` on
  `OnMapChanged`).

### 7.4 Browser window (`/fs`)

Tabs:

1. **Discoveries**: left tree *Continent → Zone* (entry counts), center list, right detail
   pane. Search across title/desc/tags/npc/item. Filters: category, subtype, author,
   "flagged outdated", "new since last login".
2. **My Submissions**: my outbox + history with status (waiting / queued / approved / rejected
   + reason).
3. **Review Queue**: *archivists only*. Proposals with diff view, map preview, approve/reject
   (reason), bulk actions, flagged-entry list, and a warnings log for untagged high-rank serving
   (§4.4).
4. **Sync**: last sync time, number of entries, archivists online, root hash (debug), "Sync now".

### 7.5 Add / Edit dialog

- Entry points: browser "New", map right-click "Add discovery here", `/fs add`, and a
  **"Scout this"** button in target / merchant context (only for NPC / vendor subtypes).
- Pre-fill: position, zone, target npcID/name, vendor stock, item link from cursor.
- Fields adapt to the category. Validation: title required, length limits.
- Buttons are disabled with a tooltip explaining the ACL when the player lacks the right.

### 7.6 Tooltip integration

- `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, …)`: when the unit's npcID
  has an entry, add a line: `FrontierScout: <title> (<subtype>)`.
- Same for items (`Enum.TooltipDataType.Item`) with notable-item entries.
- Skipped whenever values are secret.

### 7.7 Launcher & commands

- LibDBIcon minimap button + LDB launcher (left-click: browser, right-click: options).
- `/fs` browser, `/fs add` new at player position, `/fs sync` force sync, `/fs config` options,
  `/fs debug` toggle debug log.

### 7.8 Options

- Display: enable world map / minimap pins, icon scale, minimap radius, per-category filters.
- Waypoints: `Auto (TomTom if loaded)` / `Native only` / `TomTom only`.
- Notifications: chat message and/or toast when new entries arrive in my current zone.
- Guild Setup (leadership): ACL thresholds with rank names, tag preview, "Write to Guild Info",
  and a checklist of how to tag archivists in officer notes.
- Data: purge stale guild buckets, reset local data and resync.

---

## 8. Waypoints

```lua
function FS:SetWaypoint(entry)
  local mode = self.db.profile.waypointMode           -- "auto" | "native" | "tomtom"
  local useTomTom = (mode == "tomtom") or (mode == "auto" and TomTom and TomTom.AddWaypoint)
  if useTomTom and TomTom and TomTom.AddWaypoint then
    TomTom:AddWaypoint(entry.map, entry.x, entry.y, {
      title = entry.title, from = "FrontierScout", persistent = false, minimap = true, world = true,
    })
  elseif C_Map.CanSetUserWaypointOnMap(entry.map) then
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(entry.map, entry.x, entry.y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
  else
    -- fall back to the nearest parent map that allows user waypoints (HBD translation)
  end
end
```

- Native waypoints are single (Blizzard allows one user waypoint). TomTom supports many.
- "Waypoint all in zone" (TomTom only) is a v1.1 nice-to-have.

---

## 9. Threat model

| Threat | Mitigation |
|---|---|
| A non-guild player whispers fake data | Envelope `g` check + WHISPER sender must be in the guild roster |
| A member on a modified client broadcasts fake `APPR`/`ENT` | Receivers require the sender to pass the archivist check (§4.4) |
| An unauthorized rank submits proposals | Archivists re-check the ACL on receipt; clients also hide the UI |
| A member edits someone else's entry with `eo` rights only | Archivist checks `entry.author == sender` for `eo`/`do` |
| A member changes the ACL or archivist list | Stored in Guild Info / officer notes, protected by Blizzard's guild permissions |
| An officer-rank player without the tag poses as an archivist | Residual risk accepted; officer clients log a warning (§4.4) |
| A demoted or rogue archivist | Loses powers immediately (receive-time check); their approvals can be filtered and reverted |
| Spam / flooding | Per-sender rate limit, size caps, entry cap |
| Payload exploits | Deserialization in `pcall`, schema validation, field whitelist, text sanitized (strip escape codes except item links) |

No cryptographic signing in v1: WoW has no key infrastructure, and the guild-permission-backed
trust anchors cover the realistic threats.

---

## 10. Code layout

```
FrontierScout/
  FrontierScout.toc
  embeds.xml
  Libs/                      -- embedded libraries (§2.1), via .pkgmeta externals
  Locales/enUS.lua           -- AceLocale-ready (esES etc. later)
  Core/
    Init.lua                 -- AceAddon, DB defaults, slash commands
    Guild.lua                -- guildKey, roster cache, events
    ACL.lua                  -- Guild Info tag parse/write, rank checks, archivist check
    Store.lua                -- entries, proposals, tombstones, GC, validation
    Digest.lua               -- FNV-1a, 64-bucket digest
    Comm.lua                 -- envelope, send/recv, rate limit, pause rules
    Sync.lua                 -- HELLO/ARCH/SYNCREQ/MANIFEST/WANT/ENT
    Review.lua               -- PROP/PACK/APPR/REJ/QSYNC, approval logic
    Capture.lua              -- position/target/merchant capture
    Waypoint.lua             -- TomTom / native
  UI/
    Icons.lua
    MapPins.lua              -- world map + minimap pins (HBD)
    MapPanel.lua             -- world map side panel
    Browser.lua              -- main window + tabs
    EditDialog.lua
    ReviewTab.lua
    Tooltip.lua
    Options.lua              -- AceConfig, Guild Setup
  .pkgmeta                   -- BigWigs packager, lib externals
  .luacheckrc
  tests/                     -- busted specs for pure-Lua modules (ACL, Digest, Store, Sync state machine)
```

Pure logic (ACL parsing, digest, store, conflict resolution, sync state machine) is kept free of
WoW API calls so it can be unit-tested with **busted** outside the game. CI runs luacheck + busted.

---

## 11. Milestones

| # | Milestone | Scope | Exit criteria |
|---|---|---|---|
| M0 | Scaffold | TOC, libs, DB, slash cmd, luacheck/busted CI | Loads on Forever beta with no Lua errors |
| M1 | Local atlas | Store, capture, edit dialog, browser (Discoveries tab), waypoints | Can create, browse and waypoint local entries |
| M2 | Map surfaces | World map pins, minimap pins, side panel, tooltips, filters | Entries visible on all four surfaces |
| M3 | Guild & ACL | guildKey isolation, roster cache, Guild Info tag, officer-note archivists, Guild Setup UI | ACL correctly gates UI in a 3-rank test guild |
| M4 | Sync | Digest, HELLO/ARCH, SYNCREQ…ENT, APPR live push | Two clients converge from empty and after divergent edits |
| M5 | Curation | Proposals, outbox, review queue, QSYNC, reports, tombstones | End-to-end submit → approve → all members see it |
| M6 | Polish | Notifications, localization scaffold (esES), perf pass (5k entries), docs | Beta testers in one guild for a week without data loss |

---

## 12. Open questions / to verify in beta

1. The exact `## Interface:` value for Forever, and whether Forever uses a separate TOC suffix
   (e.g. `_Forever.toc`).
2. Whether `C_Club.GetGuildClubId()` is available and stable.
3. The exact addon comms restrictions under Midnight rules on Forever: which contexts block
   `SendAddonMessage`, and what the throttle budgets are.
4. Whether `C_Map.CanSetUserWaypointOnMap` is true for all Forever zones.
5. Which Blizzard atlas icons exist for categories (fall back to bundled TGAs if needed).
6. Guild Info text length limit on Forever, to confirm there's room for the tag.
