[README.md](https://github.com/user-attachments/files/34238823/README.md)
PIGEON 1.1  -  Leader to Leader Comms, Synced callouts and pins. 
INSTALL
 
 1. Prerequisite Addons : Libslash, MapMonster (+MiniMapMonster),
    Warband Lead Helper.
 2. Put this Pigeon folder in Interface\AddOns.
 
 

HOW IT WORKS:

Pigeon creates a bridge between Warband Lead Helper, MapMonster and other players using the addon. 

It uses the custom chat channels released 28/10/26 as a pipeline to send data to other addon users to relay WLH callouts and WarCommander style pins to other Warband Leaders in sync. 

Pigeon uses a small window as a updating noticeboard of Warband leaders, presenting their callout text from WLH. This text can be clicked on to interface with the other main pillar of Pigeon's system. 

These WLH callouts have map data associated with them like Warcommander, your callout to regroup on you finds your position using MapMonster's player data, and creates pins for other leaders to see where you are
and what you're doing in two ways. 

You can also use the Warcommander system of right clicking to create pins and arrows that other leaders should be able to see, but will not be repeated on the Pigeon notice board. 

A leader can press nothing but WLH buttons and make pins on the map with Right Clicks to get the full value out of the addon.

HOUSEKEEPING
This is my first time doing this so please don't be shy with identifying issues. 

IF SOMETHING DOES NOT WORK: type /pg debug and paste what it prints into a comment on the forum post and I'll see what i can do to fix it.

 The Debug list
 It shows the channel, the last line sent, what the
 Warband Lead Helper hook saw (the channel WLH used, the tag, and whether a place was found) and the last map pin result.
 

THE CONTROLS (a strip at the top of the Pigeon window.)
  + Player      : add the friendly player you have targeted to your leader roster.
 N waiting     : leaders waiting to link with you (strangers who posted in the channel, leaders announcing they are
                 leading, leaders suggested by a linked leader). With someone waiting it reads "+ Name":
                 LEFT click = add them, RIGHT click = dismiss them (not offered again for 30 minutes).
 
 Places for orders: a WLH BO call finds its position from WLH's zone data; attack/move/hold use where you stand;
 anything else can be placed with the map's right-click menu. Linking two leaders: both are in the channel, so A sees
 "+ B" appear when B's Pigeon posts; click it. Or target B and click + Player.
 If a message could not be sent to the other leaders, the window says "chat: NOT sent" and why. Again print the /pg debug text and upload it if this occurs. 

THE SHARED CHANNEL (on by default)
 A player can only be in ONE custom chat channel, so Pigeon uses the leaders channel "Command": on first run it
 sends /channeljoin Command once (channels persist across logouts) and posts to it with /9. 

If you were already in another custom channel the join fails (leave it with /channelleave <name>, then /channeljoin Command); 

Pigeon warns after 30 seconds if its own lines never come
 back. 

 * Anybody in the channel can post, so nothing is trusted until you click Add for that leader (yellow buttons).
   Only added leaders' messages are acted on; and trusted by the addon, to stop spoofing and spamming as much as possible. 

 * Pigeon's lines are readable, so everyone in the channel can follow them; only Pigeon reads the short tail:
     Take Monastery of Morr {pg1 WLH 90829 BO 106 35100 9900}
     HOLD, DO NOT ENGAGE {pg1 WLH 90830 HD 106 35100 9900}
     position: Festenplatz, Nordland {pg1 POS 90831 106 21000 15000}
     is leading a warband {pg1 PRS 90833 1}
 
   Anything people type in the channel without a tail is ordinary chat and is ignored by Pigeon.

FINDING AND KEEPING LEADERS (automatic)
 * When you become a warband leader (in a warband, group leader, not an assistant) Pigeon tells the leaders on your
   roster. When you stop leading it says so, and while you lead it repeats "still leading" only after 10 quiet minutes. Leaders
   who stop leading are skipped for messages and pins and shown as [not leading] in /pg roster, but they stay on
   your list, so nobody has to re-add anyone. Someone not heard from for 25 minutes while marked leading goes inactive.
   If you never lead (for example when testing chat between two characters), nothing is announced and everything
   works as before. /pg presence off turns the announcements off.
 * Becoming a leader also sends a hello to your ONLINE friends (and guildmates the guild list shows online), once
   per name per session, up to 20. Anyone without Pigeon will see a line of coded text, so /pg discover off stops it.
 * /pg accept off|friends|guild|known (default known): a hello from someone on your friends list or in your guild is
   linked automatically. Everyone else is still only "pending" until you type /pg add Name.
 * When two leaders link they tell each other who else they are linked with. Those names appear as suggestions,
   never added by themselves: /pg suggest lists them, /pg add Name or /pg addall accepts.
 * /pg discover fields prints what the friends and guild lists contain (please send me that if discovery
   misses people). /pg discover sends the hellos right now.

FIRST TESTS - This need 2+ players (potentially up to 8)

As this is a networked addon, if you encounter problems, getting some of these commands to test the addon might help me solve them long term. 

 /pg test            offline self test, expect "67 passed, 0 failed"
 /pg status          shows which bridges were found
 /pgwin              opens the window
 A: target B, click + Target   (or /pg add B)     B sees "Add A" on the bar, clicks it   (/pg add A)
 A: /pg say hello    B should see it in the window
 A: press a WLH button (e.g. Attack)   B should see it with the tag and place
 A: /pg order attack at <place> 5m east gate     (/pg places lists names in your zone, needs WARCommander)
 B: /pg board        shows A's order; with MapMonster open the map and look for the pin
 B: /pg relay        repeats the order to B's own warband with the WLH voice tag (only when you type it)

COMMANDS  (/pg or /pigeon) - These are testing commands and won't be present in the real release. 
 add/remove Name, roster, pending, hello, say text, order <word> [at <place>] [5m] [; note],
 addtarget, verbs, board, channel /command|off, parrot on|off, presence on|off, accept <mode>, discover [on|off|fields], suggest, addall, pos, track on|off, places, zone, relay [name], pins on|off, status,
 rate <sec>, dry on|off (shows whispers instead of sending), probe on|off, test

NOT VERIFIED IN THE REAL CLIENT: control bar layout and clicks, the WLH hook (wbLeadHelper.chat wrapper), window layout, Enter key, whisper sender name format, channel sending and receiving (CHAT_TEXT_ARRIVED),
 leader detection (IsWarBandActive / isGroupLeader), the friends and guild list fields, MapMonster pin creation on 1.4.8, WLH relay, Report what you see.


BO names (TAKE BO)
------------------
For BO / hold / attack / move orders Pigeon reads the battlefield objective name from Warband Lead
Helper's own data for the zone WLH says you are in, so the other leaders see "TAKE BO - <name>".
The name is then matched (ignoring case, punctuation and a leading "The") against WARCommander's
place list to attach a map position. Objectives WLH lists with a zone prefix (e.g. "TC - Monastery
of Morr", which belongs to the neighbouring zone) are shown by name without a pin. The grey "map:"
line and /pg debug say what matched.


Map pins and map orders
-----------------------
WLH buttons: every place-type button (attack, hold, move, regroup, take BO...) now drops a pin on YOUR map,
and on every other leader's map, where you were standing when you pressed it. If the message names a BO
(from WLH's zone data) or you picked a place with the "@" button, the pin goes there instead. The pin shows
in the Pigeon window with a grey "map:" line saying what happened. Other leaders' orders also become a
MapMonster Navigator waypoint (/pg waypoints off to stop that).

Manual pins: right-click the world map or the minimap. Pigeon adds items to the menu (to WARCommander's own
menu if you have it, otherwise a menu of its own): Attack / Hold / Move / Regroup / Take BO here, "marker
for me only", and a switch "also tell my warband" (sends the order through WLH to your warband too).
Orders say "near <place>" when WARCommander knows a place close to the click.

Checks: /pg map  (status + last click),  /pg map test  (marker where you stand),  /pg show  (flash newest pin).

Named places: Pigeon now carries its own list of BOs, keeps and warcamps per zone (data from WARCommander's
PointsOfInterest.lua by Flimgoblin, MIT licence), used when WARCommander's list isn't loaded. This is what lets
"Go to BO - Kurlov's Armory" from WLH become a pin on the map without needing WARCommander.

Credits and licences: see CREDITS.txt (includes the MIT licence for the place data taken from WARCommander).

Clicking coordinates, pins, arrows, channel scan (this version)
---------------------------------------------------------------
* Click an order line in the Pigeon window (any coloured text that has a place): the world map opens on it with
  a temporary pin, which is removed when you close the map. Arrow lines open on the arrow's end point.
* Each leader can have up to 5 pins on your map at once (orders and arrows; oldest drop off first), plus one
  position pin. Pins are twice the normal MapMonster size: /pg pinsize 0.875 for normal, /pg pinsize 1.75 default.
* Attack arrows: right-click the map > "Arrow starts here", then right-click the end > "Attack arrow to here"
  (or "Move arrow"). Everyone gets a green arrow: a stem of four pins in a line and a chevron ">" of five pins
  at the head. Nine pins that count as ONE object: delete one and all nine go.
* /pg who (and automatically every 15 minutes while you lead, /pg autowho off to stop) runs /channelwho and asks
  the channel who is leading a warband. Green = on your roster, yellow = says it leads a warband and waits for
  your Add (also on the yellow waiting button), grey = in the channel but has not said it leads. Friends/guild
  are added automatically (/pg accept). Leadership is each player's own claim; the game cannot show whether a
  player in another warband leads it.


Leader rows, history and icons (this version)
---------------------------------------------
* The Pigeon window now shows one row per APPROVED leader (you first), each with their latest order in its
  colour and how long ago. Left click a row: the map opens on that order with its pins until you close the map.
  Right click: their last five orders (orders and arrows); pick one to show its pins the same way.
  The area underneath is only for system messages and problems ("chat: NOT sent ...", "map: no pin ..."). Orders no
  longer scroll there; /pg verbose on also prints a "map:" note for every order.
* The control "Relay WB (green = on, red = off)" (was "Parrot") controls whether what you tell YOUR warband with WLH is relayed to
  the other leaders. It does not send anything to your own warband.
* Pins have an icon per order type (sword = attack, shield = hold, waypoint = move, shout = other, flag =
  leader), using the same MapMonster icons WARCommander uses: /pg icons varied|classic.
* A new order from another leader pulses on the map (MapMonster's own highlight) if the world map is already open
  on that zone. It never opens the map by itself. /pg flash off to stop it.
* /pg accept leaders : automatically approve anyone in the channel who announces they lead a warband. Convenient,
  but anyone can make that claim, so the default stays "known" (friends and guildmates).

Command channel note
--------------------
Pigeon assumes the "Command" channel is your /9 slot (the first custom channel).
The window header line shows "Command /9 (unverified)" until one of your
own lines has come back through it, then "Command /9". If your slot
differs, use /pg channel /8 (or whichever number) - and tell your leaders.

If your position is wrong on the map
------------------------------------
MapMonster sometimes places the player wrongly in a zone. Stand still, open the world
map, right-click your own arrow and pick "I am standing here (fix my position)".
Pigeon remembers the difference for that zone and uses it for every "my position" order.
/pg map fix reset clears it. /pg where shows what MapMonster reports.

Zones
-----
Pigeon's named places cover 62 zones. MapMonster's own data is missing for Ellyrion (zone 207): its zone file lists 207
twice and the second entry ("Garden of Qu'aph", marked bad) cancels Ellyrion. To fix it, open
Interface/AddOns/MapMonster/Source/MapMonster_ZoneData.lua, delete the line
    MapMonster.ZoneInfo[207] = { badZone = true } -- Garden of Qu'aph
and /reloadui. For any other zone whose position comes out wrong, calibrate it (see above).

Relay and typing (shelved for now)
----------------------------------
Relaying your WLH warband messages to the other leaders is always ON when the game starts (the Relay WB button is
gone). /pg parrot off still switches it off until the next reload. The text box and Send button are gone too:
the window is for reading orders and clicking leaders; everything is sent with WLH's buttons or the map menu.

Position shift (test)
---------------------
MapMonster's player position came out about 3500 units off on the map in Praag, so Pigeon adds 5500,4500 to
"my position" for every zone by default. /pg shift X Y sets the amount for the zone you are in (zones differ: Praag looked like ~3500,3500 earlier, 5500,4500 later), /pg shift all X Y sets it for zones without their own, /pg shift off removes it, /pg shift
reset / reset all restore the default (5500,4500, tuned in game). A zone calibrated with "I am standing here" ignores the shift.

"Clear pins" button removes only the pins and arrows you placed yourself, not other leaders'.

Resizing: drag the small square in the window's bottom-right corner; the size is remembered.

Position memory: MapMonster only knows where you are after you move (after a reload or zone change it knows nothing).
Pigeon now remembers your last position in the zone, so a WLH press while standing still still pins correctly.

Latest changes
--------------
* Layout editor: the Pigeon window can be moved and resized from the game's layout editor like other windows (our own
  resize square is hidden when the layout editor is available). The waiting window can be moved there too.
* Waiting list: the button now says "N waiting" (yellow when someone is waiting) and opens a sidebar window beside
  Pigeon. Left click a name to add that player as a leader, right click to dismiss.
* Only a warband leader can send orders: orders, WLH repeats, arrows and positions are refused unless you are the
  leader of an active warband, and you get a "NOT sent" line saying why. /pg test on lifts this for solo testing
  (/pg test off restores it). Note: Pigeon cannot check what other people send; trust is still your roster.
* Arrow pins are back to the normal MapMonster size (/pg arrowsize 0.875; bigger numbers = bigger).
* Receiving: orders (and WLH repeats, arrows, positions) are only accepted from someone who has announced they lead a
  warband. If one arrives before the announcement, Pigeon says it ignored it and asks the channel who is leading, so
  their next press goes through. /pg test on accepts anyone (for testing).
* Looking at an old order from a leader row no longer hides the newest pins: current pins sit above the temporary ones.
* Layout editor resizing now keeps the text size: when you let go of the resize handle, the scale change is turned into a
  real window size change (text stays the same, the frame gets bigger).
* Leader rows show activity: a leader you have not heard from this session (or for 25 minutes) is greyed out with a dimmer
  bar and "offline? ..." text; leaders announcing they lead show green. The age ("now", "5m") has its own spot at the
  right edge so it is never cut off.

* /pg shift X Y now applies to the zone you are standing in only; /pg shift all X Y changes the default for every other zone.

Map right-click menu (grouped)
------------------------------
Orders:    Attack / Hold / Move / Regroup / Take BO here
Groups:    Group 1 - move here ... Group 4 (WARCommander's icons: fist, moon, shield, sun)
Sightings: Warband spotted here (flag), Group spotted here (shout), Conflict here (orange shout)
Then: Marker for me only, the arrow items, "I am standing here", and "Also tell my warband".
These go to the other leaders like any order and are pinned with their icon on everyone's map.

MapMonster zone-change bug (repaired by Pigeon)
-----------------------------------------------
If the zone you just left has no MapMonster data (flying through an unmapped zone, a city...), MapMonster's zone-change
handler errors out and keeps using the OLD zone for your position until you reload. That gives wrong or missing player
positions after travelling, and "/mm new" failing with a zone error. Pigeon now repairs this automatically; /pg where
says when it had to. (If it still happens, /reloadui fixes it for MapMonster itself.)

Player position when MapMonster has none
----------------------------------------
In some zones MapMonster's POIs and pins work but it never reports where YOU are. Pigeon now listens to the same
game position event itself and, when MapMonster gives no position, works your zone coordinates out from the world
position minus MapMonster's own offset for the zone (the same sum MapMonster does). Your per-zone corrections
(/pg map fix, /pg shift) still apply on top. /pg where says "position worked out by Pigeon" when this is in use.

Built-in per-zone position shifts
---------------------------------
The shifts measured in game for 26 zones are now built in (LK.ZONE_SHIFT in PigeonLinks.lua), so the player pin and
"on my position" orders land correctly without any setup. Your own /pg shift for a zone still overrides the built-in
value; /pg shift reset puts it back. Zones not in the list (Keep zones, Ellyrion, scenarios) use the default 5500,4500.

/pg where in zones MapMonster cannot handle
-------------------------------------------
In a zone MapMonster has flagged unusable (Ellyrion), MapMonster's own GetPlayerPosition throws an error. /pg where
now catches that and reports it, together with what MapMonster knows about the zone, instead of showing a Lua error.

Icon sizes and clipping
-----------------------
Every pin icon is a rectangle cut from a big shared picture sheet. A pin window bigger than its icon shows the
neighbouring pictures from the sheet (stray bits next to the icon), and a smaller one cuts the icon off. Pigeon now sizes
each pin window to exactly its icon (LK.SLICE_BASE in PigeonLinks.lua holds how big each picture is), with no spare room.
- MapMonster's own editor, pin list and tooltips get the normal icon size; Pigeon draws the real size on the map itself.
- Sizes: Move 0.75, Regroup (cyan orb, own icon) 0.95, Warband spotted 0.85, Group spotted (green flag) 0.5, Conflict 1.2,
  all relative to the standard Pigeon pin size. /pg pinsize still scales them all together.


Privacy and safety 
-------------------
- The "Command" channel has no security: anyone on your faction can join it and read it. Everything Pigeon posts there
  (your callouts, the place you press them at, whether you lead a warband) is visible to every member of the channel.
- Pigeon only ACTS on lines from leaders on your roster, and orders only count from someone who has announced that they
  lead a warband. Strangers appear in the "waiting" list; nothing happens until you click Add.
- /pg accept leaders adds anyone in the channel who claims to lead a warband. That claim cannot be checked, so only use it
  among people you trust; the default only links friends and guildmates.
- Pigeon reads: your zone and position (from MapMonster), your warband leader status, and the Warband Lead Helper
  messages you send to /wb. It sends: short lines to the Command channel (/9 by default). 
  It never sends anything to say, guild or party chat. 

