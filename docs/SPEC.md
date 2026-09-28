# FrontierScout — Specification

> Status: **v0.1, implemented (M0–M6)**; in-game verification pending (docs/TESTING.md).
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
| Client | WoW Forever, Mainline 12.x API (`WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`). Beta interface **16001**; the TOC also lists current Retail interfaces so the addon can be tested on Retail. |
| Lua | 5.1 (WoW flavour), `bit` library available. |
| Maps | `C_Map` (uiMapID-based). Positions stored as uiMapID + normalized x/y. |
| Comms | `C_ChatInfo.SendAddonMessage` via AceComm, on a private guild channel with `GUILD` as fallback (messages for one player are addressed, §3.3). |
| Waypoints | `C_Map.SetUserWaypoint` + `C_SuperTrack` (native) or TomTom API. |
| Midnight restrictions | Addon comms and some unit data are restricted in combat / instanced content, and some values can be *secret* (`issecretvalue`). FrontierScout is open-world only and **pauses all sync while `InCombatLockdown()` or `IsInInstance()`** (outgoing messages are queued), and never reads unit data that is secret. See §6.6 on send results. |

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
| AceConfig-3.0, AceConfigDialog-3.0, AceGUI-3.0 | Options panel and the add/edit form |

Libraries are **vendored** in `Libs/` from pinned upstream revisions by `scripts/update-libs.sh`
(see `Libs/README.md`), so the repository folder can be dropped into `Interface/AddOns` as-is.

The browser window and map side panel use native frames (`ScrollBox` + `DataProvider`) for
performance.

**Launcher (decided in M1):** the native **Addon Compartment** (`## AddonCompartmentFunc` in the
TOC) plus key bindings (`Bindings.xml`), so no LibDataBroker / LibDBIcon. A standalone minimap
button can be added in M6 if beta testers ask for one.

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
-- AceDB layout: addon data under .global, UI settings under .profiles
FrontierScoutDB = {
  global = {
    schema    = 1,
    sessions  = <n>, firstSeen = <time>,               -- shown by /fs status
    guilds = {
      [guildKey] = {
        meta      = { name = "Guild Name", realm = "Realm", lastSeen = <time> },
        entries   = { [entryId] = Entry, ... },        -- approved canonical set (+ tombstones)
        outbox    = { [proposalId] = Proposal, ... },  -- my submissions not yet acknowledged
        mine      = { [proposalId] = ProposalStatus }, -- history of my submissions & decisions
        queue     = { [proposalId] = Proposal, ... },  -- archivists only: pending review
        syncState = { lastFullSync = <time>, digest = {...} },
      },
    },
  },
  profiles = { ... UI settings (AceDB profiles) ... },
}
```

- A character's **active bucket** is chosen from its current guild on `PLAYER_GUILD_UPDATE`
  / login. Alts in different guilds on the same account never see each other's data.
- A character with no guild has no active bucket: the UI shows "Join a guild to use FrontierScout".
- If you leave a guild, its bucket stays but is hidden. Options → "Purge data for guilds I'm no
  longer in".

### 3.3 Transport isolation

- AceComm prefixes (≤16 chars), registered with `C_ChatInfo.RegisterAddonMessagePrefix`:
  **`FScout`** for broadcasts and **`FScoutTo`** for messages to one player.
- Channels: a **private chat channel for the guild** (`FS<club id>`), with **`GUILD`** as the
  fallback. Never `WHISPER` (addon whispers to WoW Forever's "Name Surname" names are lost without
  an error, §4.5) or `PARTY`/`RAID`.
  - In the beta, one player's guild addon messages never reached anyone (no error, allowed to speak
    in guild chat), while everyone else's reached them. So every client joins the hidden channel
    (5 s after login, so the default channels keep their numbers), sends there once joined, and
    reads both. "Send over the guild channel only" in the options sends over `GUILD` instead (the
    channel is still read), and a message the game refuses on the channel is resent once over `GUILD`.
  - Anyone can join a chat channel, so a channel message is read only if its sender is in the
    guild roster (and it still needs the guild key `g`). An outsider who knows the club id could
    join or grab the channel first, which only denies service: clients that can't join send over
    `GUILD`, and the option does the same for everyone else.
- A `FScoutTo` message is `<recipient full name>\001<encoded payload>`. Everyone else skips it
  before rate limiting or decoding; the recipient is matched with `FS:IsMe` (roster and
  `UnitFullName` forms, ignoring realm, spaces and case).
- Every message envelope carries `v` (protocol version) and `g` (guildKey). Messages whose `g`
  doesn't match the receiver's active guildKey are dropped.

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
- Options → *Guild Setup* shows rank names next to each threshold and the resulting tag in a
  read-only text box to copy. **`SetGuildInfoText` is protected on Forever** (calling it from an
  addon raises "blocked from an action only available to the Blizzard UI"), so leadership pastes
  the tag into Guild Info by hand. The page then compares Guild Info with the chosen thresholds
  (`ACL.SetupStatus`: has these settings / other settings / no tag yet / too long) and has a
  **Check again** button.

**b) Officer notes: archivist designation.** An archivist's officer note contains the token
`{FS:A}` (6 chars; officer notes allow 31). Only ranks with "Edit Officer Note" can set it,
and only ranks with "View Officer Note" (`C_GuildInfo.CanViewOfficerNote()`) can read it.

### 4.4 Archivist verification

**Changed after the first beta tests:** archivists are chosen **by rank** by default: every member
of a selected archivist rank is an archivist. The tag keeps `ar` (lowest archivist rank, for older
clients) and adds `am` (bitmask of the selected ranks, bit *i* = rank *i*; overrides `ar`). The
officer-note check below is opt-in with `an=1` ("Also require {FS:A} in their officer note"). A
client that may read officer notes but receives no note text uses the rank check.

The permission tag is re-read from Guild Info whenever permissions are checked, and the last known
tag is saved per guild: Guild Info text can arrive after the roster at login, and falling back to the
defaults would briefly demote every archivist below rank 0.

Original hybrid design (now the `an=1` behaviour):

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
  `C_GuildInfo.GuildRoster()`, at most once per 15 s (Blizzard throttle), and every 60 s in the
  background; the Guild Info tag is re-read on each roster update.
- A rank's own/any rights combine: someone allowed to edit *any* entry may edit their own too.
- Stores `fullName (Name-Realm) → { rankIndex, officerNoteHasTag, online }`.
- All ACL and archivist checks go through the cache and use **current** rank at receive time.
- Names are always normalized to `Name-Realm` internally (`Ambiguate` only for display).
- **WoW Forever names** (found in the beta): characters are "Name Surname" (with a space). Whispers
  to `Name Surname-Realm` fail with "No player named … is currently playing", and addon whispers
  to `Name Surname` didn't arrive either, so the addon doesn't whisper at all (§3.3).
- The player is found in the roster **by GUID** (`GetGuildRosterInfo` 17th return vs.
  `UnitGUID("player")`), and that roster name is the player's identity, because `UnitFullName` can
  differ from the roster name.

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
- **Report outdated** is a proposal of its own in the review queue. An archivist fixes the entry
  (edit / delete) and marks the report **Resolved**, or **Dismisses** it with a reason. (The
  `flags` counter is not used.)
- Archivists re-check a proposal when it arrives and again when approving: the sender must be the
  proposal's author and in the roster, and the author's *current* rank must allow the action. A
  proposal that no longer applies (entry deleted, rank lowered) is rejected with the reason.
- Decisions are kept 30 days so offline authors and archivists catch up.
- An archivist's own create/edit/delete is **auto-approved** (still recorded with `approvedBy`).

### 5.5 Coordinates

- Captured with `C_Map.GetBestMapForUnit("player")` + `C_Map.GetPlayerMapPosition(map, "player")`.
- Map-click capture: **Ctrl + right-click** on the world map canvas (plain right-click already
  zooms out) opens the dialog at `ScrollContainer:GetNormalizedCursorPosition()` on the
  displayed map ID.
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

"WHISPER" below means a guild message addressed to that one player (`FScoutTo`, §3.3).

| Type | Channel | From → To | Payload | Purpose |
|---|---|---|---|---|
| `HELLO` | GUILD | any → all | `root, count, role, open` | Announce presence after login (15–45 s random delay); `open` = up to 50 ids of my queued, undecided proposals |
| `ARCH` | WHISPER / GUILD | archivist → member / all | `root, count` | Answer to `HELLO` by whisper; periodic beacon on GUILD (every 10 min) |
| `SYNCREQ` | WHISPER | member → archivist | `buckets[64]` | Ask for diff when root differs |
| `MANIFEST` | WHISPER | archivist → member | `{ [bucket] = { id=rev:approvedAt, ... } }` | Details for mismatched buckets only |
| `WANT` | WHISPER | member → archivist | `ids[]` | Request entries the member lacks or has older |
| `ENT` | WHISPER | archivist → member | `entries[]` (≤ 20 per msg), `done` on the last | Bulk transfer, `BULK` priority |
| `BUSY` | WHISPER | archivist → member | — | Already serving 2 members; retry another archivist or in 60–90 s |
| `PROP` | WHISPER | contributor → each online archivist | `Proposal` | Submit (resent at most once a minute until acked) |
| `PACK` | WHISPER | archivist → contributor | `pid` | Ack: `mine` shows "queued"; the proposal stays in `outbox` (not resent) until decided |
| `QMISS` | WHISPER | archivist → contributor | `pid` | Answer to an `open` id the archivist has neither queued nor decided: the contributor sends it again |
| `APPR` | GUILD | archivist → all | `Entry` (single) | Live push of a newly approved revision |
| `QDEC` | GUILD / WHISPER | archivist → all / author | `pid, s=approved\|rejected, r=reason, e=eid, a=author` | A decision. On GUILD it clears other archivists' queues and tells an online author; whispered for each `open` id in a later `HELLO` (replaces `REJ`) |
| `QSYNC` | WHISPER | archivist ↔ archivist | pending queue + decisions | Sent when archivists meet (`HELLO` role A / `ARCH`) |

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

**Transport on WoW Forever (from the beta):** addon whispers to "Name Surname" names are lost, so:
- `PROP` is **broadcast on GUILD**: every archivist that hears it queues it, everyone else ignores
  it. The member doesn't need to know who the archivists are.
- Every message for one player (the "WHISPER" rows in §6.4, bulk `MANIFEST`/`ENT`/`QSYNC`
  included) is an **addressed guild message** (§3.3).
- An author whose submission is approved but whose `APPR` hasn't arrived 15 s after the `QDEC`
  pulls from that archivist.
- An archivist credits a received proposal to its **sender** (server-verified), not to the author
  name inside it, which can differ on Forever and can't be forged this way.

**Implementation notes (M4)**

- An archivist answers a `HELLO` with an `ARCH` addressed to that player, so a login doesn't make every archivist
  talk on the guild channel. A `HELLO` with `role=A` from another archivist whose root differs
  makes the receiver pull from it too, so archivists converge in both directions.
- `WANT` goes in chunks of 100 ids; the archivist marks the last `ENT` of the last chunk `done`.
- A member that finds, in a mismatched bucket, a local entry the archivist doesn't list and that is
  older than the tombstone lifetime drops it: its deletion was already garbage-collected.
- Only archivists' writes are canonical (pushed with `APPR`); everyone else's writes are
  proposals (§5.4).

### 6.6 Limits & throttling

- ChatThrottleLib via AceComm: `ALERT` priority for control messages, `BULK` for `ENT`.
- Maximum outgoing `ENT` bandwidth per archivist: ~1 KB/s. At most **2 concurrent member syncs**
  per archivist; others are told to retry later (`BUSY`).
- Receive-side rate limit: messages from a single sender beyond 30/min are dropped (anti-spam),
  checked before decoding. The archivist a client is currently pulling from is exempt.
- Received messages are capped at 256 KB encoded / 1 MB decompressed and decoded in `pcall`.
- Sync is **paused** in combat / instances: outgoing messages are queued (up to 100) and sent on
  `PLAYER_REGEN_ENABLED` / `ZONE_CHANGED_NEW_AREA`, after which the client pulls again if an
  archivist's root differs.
- AceComm sends through ChatThrottleLib, which doesn't surface `Enum.SendAddonMessageResult`;
  lost messages are covered by timeouts (120 s per session) and the next `HELLO` / beacon.
- Hard caps: 5,000 entries per guild. Oversized fields are truncated on receipt.

---

## 7. User interface

### 7.1 World map pins

- HereBeDragons-Pins `AddWorldMapIconMap`, with one icon per category/subtype (Blizzard atlas
  icons, no custom art needed for v1).
- Hover: tooltip with title, subtype, description excerpt, author, "approved by", respawn/schedule.
- Click: opens the entry in the side panel. Shift-click: set waypoint. Right-click: context
  menu (Waypoint, Edit, Delete, Report outdated).
- Category toggles live in the side panel header (§7.3) and in Options; they filter both the
  pins and the panel list. Subtype filters: v1.1.
- Only the shown continent's entries get pin frames (rebuilt when the continent or the data
  changes), so thousands of entries don't mean thousands of frames.

### 7.2 Minimap pins

- HereBeDragons-Pins `AddMinimapIconMap`, same icons at smaller size, for the player's zone only
  (rebuilt on `ZONE_CHANGED_NEW_AREA`). Optional "keep on the minimap edge" for distant pins.
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
3. **Review Queue**: *archivists only*. Proposals with diff view, approve/reject (reason),
   "Show" (the entry, or a waypoint to a proposed new spot), reports, and a warnings log for
   untagged high-rank serving (§4.4). Bulk actions: v1.1.
4. **Sync**: last sync time, number of entries, archivists online, root hash (debug), "Sync now".

### 7.5 Add / Edit dialog

- Entry points: browser "New", map right-click "Add discovery here" (M2), `/fs add` and its key
  binding (uses the current target when there is one), and a **Scout** button on the merchant
  window (vendor + stock).
- Item links: shift-click an item while the description or items field has focus. Items are one
  per line, `<item link or ID> = <cost>`.
- Pre-fill: position, zone, target npcID/name, vendor stock, item link from cursor.
- Fields adapt to the category. Validation: title required, length limits.
- Buttons are disabled with a tooltip explaining the ACL when the player lacks the right.

### 7.6 Tooltip integration

- `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, …)`: when the unit's npcID
  has an entry, add a line: `FrontierScout: <title> (<subtype>)`.
- Same for items (`Enum.TooltipDataType.Item`) with notable-item entries.
- Skipped whenever values are secret.

### 7.7 Launcher & commands

- Addon Compartment entry (opens the browser) and two key bindings: toggle the browser, record a
  discovery here.
- `/fs` browser, `/fs add [title]` new at player position, `/fs waypoints auto|native|tomtom`,
  `/fs sync` force sync (M4), `/fs config` options (M3), `/fs debug` toggle debug log.

### 7.8 Options

- Display: enable world map / minimap pins, icon scale, minimap radius, per-category filters.
- Waypoints: `Auto (TomTom if loaded)` / `Native only` / `TomTom only`.
- Notifications: chat message and/or on-screen message (`UIErrorsFrame`) when new entries (not
  edits) arrive in my current zone; one summary line for a batch.
- Guild Setup (leadership): ACL thresholds with rank names, the tag to copy into Guild Info with
  a status line, and a checklist of how to tag archivists in officer notes.
- Options are split into tabs (Map, General, Guild Setup, Data) so no page overflows the window.
- Data: purge stale guild buckets, reset local data and resync (for archivists only while another
  archivist is online, so the guild's data can't be lost).

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
| A non-guild player sends fake data | Whispers are ignored; `GUILD` and private-channel messages need the envelope `g`, and channel senders must be in the guild roster |
| An outsider joins or takes over the private channel | Their messages are ignored (roster check); a takeover only blocks the channel, and "Send over the guild channel only" falls back to `GUILD` |
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
  Bindings.xml               -- key bindings (browser, record a discovery)
  Libs/                      -- vendored libraries (§2.1), see Libs/README.md
  Locales/enUS.lua           -- AceLocale-ready (esES etc. later)
  Core/
    Init.lua                 -- AceAddon, DB defaults, slash commands
    Categories.lua           -- categories, subtypes, labels (§5.2)
    Format.lua               -- text sanitizing, coordinates, money, item/tag lists
    Guild.lua                -- guildKey, roster cache, events
    ACL.lua                  -- Guild Info tag parse/write, rank checks, archivist check
    Store.lua                -- entries, proposals, tombstones, GC, validation
    Query.lua                -- search, filters, Continent -> Zone grouping
    Digest.lua               -- FNV-1a, 64-bucket digest
    Comm.lua                 -- envelope, send/recv, rate limit, pause rules
    Sync.lua                 -- HELLO/ARCH/SYNCREQ/MANIFEST/WANT/ENT
    Review.lua               -- PROP/PACK/APPR/REJ/QSYNC, approval logic
    Capture.lua              -- position/target/merchant capture
    Waypoint.lua             -- TomTom / native
  UI/
    Icons.lua
    Widgets.lua              -- list rows, buttons, detail text shared by browser and panel
    MapPins.lua              -- world map + minimap pins (HBD)
    MapPanel.lua             -- world map side panel
    Browser.lua              -- main window + tabs
    EditDialog.lua
    ReviewTab.lua            -- My submissions, Review queue and Sync tabs
    Tooltip.lua
    Options.lua              -- AceConfig, Guild Setup
  .pkgmeta                   -- BigWigs packager
  scripts/update-libs.sh     -- re-vendors Libs/ from pinned revisions
  .luacheckrc
  tests/                     -- busted specs: pure modules, WoW-facing modules on API stubs,
                             -- UI smoke tests on fake frames (tests/helpers/)
```

Pure logic (ACL parsing, digest, store, conflict resolution, sync state machine) is kept free of
WoW API calls so it can be unit-tested with **busted** outside the game. CI runs luacheck + busted.

---

## 11. Milestones

| # | Milestone | Scope | Exit criteria |
|---|---|---|---|
| M0 | Scaffold | TOC, libs, DB, slash cmd, luacheck/busted CI | Loads on Forever beta with no Lua errors |
| M1 | Local atlas | Store, capture, edit dialog, browser (Discoveries tab), waypoints | Can create, browse and waypoint local entries |
| M2 | Map surfaces | World map pins, minimap pins, side panel, tooltips, filters, display options | Entries visible on all four surfaces |
| M3 | Guild & ACL | guildKey isolation, roster cache, Guild Info tag, officer-note archivists, Guild Setup UI | ACL correctly gates UI in a 3-rank test guild (`tests/acl_spec.lua`, `tests/guildsetup_spec.lua`) |
| M4 | Sync | Digest, HELLO/ARCH, SYNCREQ…ENT, APPR live push | Two clients converge from empty and after divergent edits (`tests/sync_spec.lua`, over a simulated guild network with the real AceSerializer + LibDeflate) |
| M5 | Curation | Proposals, outbox, review queue, QSYNC, reports, tombstones | End-to-end submit → approve → all members see it (`tests/review_spec.lua`) |
| M6 | Polish | Notifications, "new since last login", data options, full esES/esMX locale, perf pass (5k entries), docs | Beta testers in one guild for a week without data loss (**pending**, docs/TESTING.md) |

**Performance (M6):** at 5,000 entries, `Store:Count` is kept incrementally (creating the cap
went from 1.6 s to 0.3 s in plain Lua), search text is cached per entry (a browser refresh is
~15 ms after the first search), world map pin frames are built for the shown zone only (the
whole continent only on a continent map), and `tests/polish_spec.lua` keeps budgets on these.

---

## 12. Open questions / to verify in beta

1. ~~The exact `## Interface:` value~~: **16001** on the beta (may change at launch). Whether
   Forever needs a separate TOC suffix: other authors ship a `_Camelot.toc`, but a plain `.toc`
   with 16001 loads.
2. Whether `C_Club.GetGuildClubId()` is available and stable.
3. The exact addon comms restrictions under Midnight rules on Forever: which contexts block
   `SendAddonMessage`, and what the throttle budgets are.
4. Whether `C_Map.CanSetUserWaypointOnMap` is true for all Forever zones.
5. Which Blizzard atlas icons exist for categories (fall back to bundled TGAs if needed).
6. ~~Whether addons may write Guild Info~~: **no**, `SetGuildInfoText` is protected (found in the
   beta); the tag is pasted by hand. Guild Info text length limit on Forever, to confirm there's
   room for the tag. The addon assumes
   500 characters (`ACL.MAX_INFO`) and refuses to write a tag that would exceed it.
7. Merchant window API on Forever: `C_MerchantFrame.GetItemInfo` vs. the older
   `GetMerchantItemInfo` (both handled), and whether the **Scout** button at the top right of
   `MerchantFrame` overlaps anything.
8. Shift-click link insertion: which of `ChatFrameUtil.InsertLink` / `ChatEdit_InsertLink` the
   client calls (the dialog hooks whichever exists).
