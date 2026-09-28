# In-game test plan

The automated specs (`busted`) cover the logic, the sync protocol over a simulated guild network,
and the UI on fake frames. They can't prove that Blizzard's API behaves as assumed on WoW
Forever. This checklist is for the beta: one guild, a few testers, about a week (SPEC §11, M6).

Install [BugSack](https://www.curseforge.com/wow/addons/bugsack) + BugGrabber to catch Lua errors,
and turn on `/fs debug` while testing.

## Setup (Guild Master or an officer with "Edit Guild Info")

1. `/fs config` → **Guild Setup**. Pick ranks for each action, copy the tag (click it, Ctrl+A,
   Ctrl+C) and paste it on its own line in Guild & Communities → Guild Info.
   - Back in Guild Setup, **Check again** says "Guild Info has these settings".
2. Add `{FS:A}` to one or two officers' officer notes (these are the archivists).
3. Everyone: `/reload`, then `/fs status` shows your rank, whether you're an archivist, and
   "Guild permissions" no longer says "not set up".

## Recording (M1)

| Step | Expected |
|---|---|
| `/fs add` somewhere in the open world | Dialog with your zone and coordinates filled in |
| Target a rare, `/fs add` | Category NPC, type Rare, NPC ID and name filled in |
| Open a vendor, click **Scout** (top right of the merchant window) | Vendor with its stock and prices |
| Shift-click an item from your bags while the description has focus | The item link is inserted |
| Save as an archivist | "Saved: …", entry appears in `/fs` |
| Save as a member | "Submitted for review: …", appears under **My submissions** |
| `/fs add` in combat / in a dungeon | Refused with a message |

## Browsing and waypoints (M1, M2)

- `/fs`: zones on the left, search, category toggles, **New since last login**.
- **Waypoint** with TomTom installed → TomTom arrow; without → Blizzard's map pin.
- World map: pins on the zone and continent maps; hover tooltip; click opens the **FS** side
  panel; shift-click sets a waypoint; right-click menu.
- **Ctrl + right-click** on the world map opens the dialog at that spot.
- Minimap: pins for your current zone.
- Mouse over an NPC or item that has a discovery → "FrontierScout:" line in the tooltip.

## Permissions (M3)

- A rank below "Submit" can't open the dialog, and **New** is greyed out with a tooltip.
- A member can edit their own discoveries but not others' (unless the ACL allows).
- Change a threshold, write it again: the change applies within about a minute for everyone
  (`/fs status`).

## Sharing (M4, M5)

| Step | Expected |
|---|---|
| Archivist adds a discovery | Every online member sees it within seconds; in-zone members get a chat line |
| Member submits while an archivist is online | Archivist's **Review** tab shows it; member's status "in the review queue" |
| Archivist approves | Everyone sees it; member gets "was approved" |
| Archivist rejects with a reason | Member gets the reason (also if they were offline, on next login) |
| Member submits with no archivist online | "waiting for an archivist"; sent automatically when one logs in |
| New member logs in for the first time | Within ~1 minute (15–45 s delay + transfer) gets the whole atlas; **Sync** tab shows "Last full sync" |
| Two archivists edit while one is offline | After both are online, the Sync tab data hash is identical |
| Report outdated | Shows in the archivists' queue; Dismiss sends the reason back |
| Alt in another guild | Sees none of the first guild's data |

## Open questions to answer (SPEC §12)

1. `/fs status`: interface number on the live client.
2. Is `C_Club.GetGuildClubId()` available? (With `/fs debug`, the guild bucket key starts with `club:`.)
3. Any addon messages lost around combat or instances? (Sync tab after leaving a dungeon.)
4. Are waypoints possible in every zone, including caves?
5. Do all icons show (no green squares)?
6. How long can Guild Info be?
7. Does the **Scout** button overlap anything on the merchant window?
8. Does shift-clicking an item insert its link into the dialog?

Please report issues with: what you did, what you expected, what happened, and any BugSack error.
