PIGEON 1.1  -  Leader to Leader Comms, Synced callouts and pins. 
INSTALL
 
 1. Prerequisite Addons : Libslash, MapMonster,
    Warband Lead Helper.
 2. Put this Pigeon folder in Interface\AddOns.
 
 

**HOW IT WORKS:**

Pigeon creates a bridge between Warband Lead Helper, MapMonster and other players using the addon. 

It uses the custom chat channels released 28/10/26 as a pipeline to send data to other addon users to relay WLH callouts and WarCommander style pins to other Warband Leaders in sync. 

Pigeon uses a small window as a updating noticeboard of Warband leaders, presenting their callout text from WLH. This text can be clicked on to interface with the other main pillar of Pigeon's system. 

These WLH callouts have map data associated with them like Warcommander, your callout to regroup on you finds your position using MapMonster's player data, and creates pins for other leaders to see where you are
and what you're doing in two ways. 

You can also use the Warcommander system of right clicking to create pins and arrows that other leaders should be able to see, but will not be repeated on the Pigeon notice board. 

A leader can press nothing but WLH buttons and make pins on the map with Right Clicks to get the full value out of the addon.

**HOUSEKEEPING**
This is my first time doing this so please don't be shy with identifying issues. 

IF SOMETHING DOES NOT WORK: type /pg debug and paste what it prints into a comment on the forum post and I'll see what i can do to fix it.

 The Debug list
 It shows the channel, the last line sent, what the
 Warband Lead Helper hook saw (the channel WLH used, the tag, and whether a place was found) and the last map pin result.
 

**THE CONTROLS** (a strip at the top of the Pigeon window.)
  + Player      : add the friendly player you have targeted to your leader roster.
 N waiting     : leaders waiting to link with you (strangers who posted in the channel, leaders announcing they are
                 leading, leaders suggested by a linked leader). With someone waiting it reads "+ Name":
                 LEFT click = add them, RIGHT click = dismiss them (not offered again for 30 minutes).
 
 Places for orders: a WLH BO call finds its position from WLH's zone data; attack/move/hold use where you stand;
 anything else can be placed with the map's right-click menu. Linking two leaders: both are in the channel, so A sees
 "+ B" appear when B's Pigeon posts; click it. Or target B and click + Player.
 If a message could not be sent to the other leaders, the window says "chat: NOT sent" and why. Again print the /pg debug text and upload it if this occurs. 

**THE SHARED CHANNEL** 
 A player can only be in ONE custom chat channel, so Pigeon uses the leaders channel "Command": on first run it
 sends /channeljoin Command once (channels persist across logouts) and posts to it with /9. 

If you were already in another custom channel the join fails (leave it with /channelleave <name>, then /channeljoin Command); 

Pigeon warns after 30 seconds if its own lines never come back. 

 * Anybody in the channel can post, so nothing is trusted until you click Add for that leader (yellow buttons).
   Only added leaders' messages are acted on; and trusted by the addon, to stop spoofing and spamming as much as possible. 

 * Pigeon's lines are readable, so everyone in the channel can follow them; only Pigeon reads the short tail:
     Take Monastery of Morr {pg1 WLH 90829 BO 106 35100 9900}
     HOLD, DO NOT ENGAGE {pg1 WLH 90830 HD 106 35100 9900}
     position: Festenplatz, Nordland {pg1 POS 90831 106 21000 15000}
     is leading a warband {pg1 PRS 90833 1}
 
   Anything people type in the channel without a tail is ordinary chat and is ignored by Pigeon.

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


**PINS**

Auto Pins: Pigeon will inhabit pins on your current map depending on your WLH callouts, Regroups and Moving calls will mark your position, BO and Keep callouts will mark those using MapMonster's map data. 

Manual pins: right-click the world map. Pigeon has a familiar list of Warcommander inspired pins pluse a couple more: Attack / Hold / Move / Regroup / Take BO here, "marker
for me only", and a switch "also tell my warband" (sends the order through WLH to your warband too, this kind of doesn't work at the moment).

Credits and licences: see CREDITS.txt (includes the MIT licence for the place data taken from WARCommander).


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
/pg map fix reset clears it. /pg where shows what MapMonster reports. - This is a useful thing for you, but tell me in a comment if this is happening and I can try to make a real fix for it.

Zones
-----
Pigeon's named places cover 62 zones. MapMonster's own data is missing for Ellyrion (zone 207): its zone file lists 207
twice and the second entry ("Garden of Qu'aph", marked bad) cancels Ellyrion. 
To fix it, open
Interface/AddOns/MapMonster/Source/MapMonster_ZoneData.lua, delete the line
    MapMonster.ZoneInfo[207] = { badZone = true } -- Garden of Qu'aph
and /reloadui. For any other zone whose position comes out wrong, calibrate it (see above).

"Clear pins" button removes only the pins and arrows you placed yourself, not other leaders'.

Resizing: drag the small square in the window's bottom-right corner; the size is remembered. This is a little broken right now

Position memory: MapMonster only knows where you are after you move (after a reload or zone change it knows nothing).
Pigeon now remembers your last position in the zone, so a WLH press while standing still still pins correctly.

Latest changes
--------------
* Layout editor: the Pigeon window can be moved and resized from the game's layout editor like other windows (our own
  resize square is hidden when the layout editor is available). The waiting window can be moved there too.
* Waiting list: the button now says "N waiting" (yellow when someone is waiting) and opens a sidebar window beside
  Pigeon. Left click a name to add that player as a leader, right click to dismiss.
* Receiving: orders (and WLH repeats, arrows, positions) are only accepted from someone who has announced they lead a
  warband. If one arrives before the announcement, Pigeon says it ignored it and asks the channel who is leading, so
  their next press goes through. /pg test on accepts anyone (for testing).
* Looking at an old order from a leader row no longer hides the newest pins: current pins sit above the temporary ones.


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

