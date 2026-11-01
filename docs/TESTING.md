# In-game test plan

The automated specs (`busted`) cover the logic, the sync protocol over a simulated guild network,
and the UI on fake frames. They can't prove that Blizzard's API behaves as assumed on WoW
Forever. This checklist is for the beta: one guild, a few testers, about a week (SPEC §11, M6).

If something about names or permissions looks wrong, `/fs whoami` prints every name the game
reports for you and how the roster sees you: include its output in the report. For anything that
doesn't arrive, include the `/fs debug` lines from both the sender and the receiver, and the
**Data hash** from both players' **Sync** tab.

Install [BugSack](https://www.curseforge.com/wow/addons/bugsack) + BugGrabber to catch Lua errors,
and turn on `/fs debug` while testing.

## Setup (Guild Master or an officer with "Edit Guild Info")

1. `/fs config` → **Guild Setup**. Pick ranks for each action, copy the tag (click it, Ctrl+A,
   Ctrl+C) and paste it on its own line in Guild & Communities → Guild Info.
   - Back in Guild Setup, **Check again** says "Guild Info has these settings".
2. In the same panel, tick the ranks that act as archivists (for example Guild Master and Officer)
   before copying the tag. Only if "Also require {FS:A} in their officer note" is on, add `{FS:A}`
   to those players' officer notes.
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

## When messages don't arrive

`/fs commtest` checks that addon messages travel both ways between you and every other online
FrontierScout user, on the guild channel and on the private channel. It uses the game API directly,
on its own prefix (`FScoutPing`), without AceComm, serialization, compression or FrontierScout's
filters, so a missing reply points at the game or the server, not at the addon.

1. Everyone involved updates and `/reload`s, then waits ~5 s (joining the private channel).
2. One player runs `/fs commtest`. It prints:
   - `Account:` level, trial / restricted / squelched / silenced, can speak in guild chat;
   - `Prefixes:` whether FrontierScout's prefixes are registered, and how many all addons use
     (a client has a limit);
   - `Sent over GUILD / CHANNEL:` what the game answered (`accepted` or `refused (reason)`).
3. Every other online user sees "*X is testing FrontierScout messages: received over …*" and
   replies automatically.
4. After 10 s the tester sees `Replies over GUILD: …` and `Replies over CHANNEL: …`.
5. The other players run it too, to check the other direction.

The same test without the addon (paste one line at a time):

```
/run F=F or CreateFrame("Frame")print("FSTest reg:",C_ChatInfo.RegisterAddonMessagePrefix("FSTest"))F:RegisterEvent("CHAT_MSG_ADDON")F:SetScript("OnEvent",function(_,_,p,m,d,s)if p=="FSTest"then print("GOT",m,"via",d,"from",s)end end)
/run print("guild:",C_ChatInfo.SendAddonMessage("FSTest","hi-guild","GUILD"))
/run print("channel:",C_ChatInfo.SendAddonMessage("FSTest","hi-chan","CHANNEL",(GetChannelName("FS22965401"))))
```

(The listener line goes first, on every client; replace `22965401` with your guild's club id from
`/fs whoami` or the `/fs debug` "guild bucket" line.)

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
