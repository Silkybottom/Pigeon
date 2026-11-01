-- Pigeon v1.1: leader-to-leader messages and orders for Return of Reckoning warband leaders.
-- (Successor to WBLeaderComms. Same tell-based design: one private whisper per roster member.)
--
-- Files:  Pigeon.lua (this, core + protocol)   PigeonLinks.lua (WLH / MapMonster / ZonepopLite)
--         PigeonUI.lua (window)                Pigeon.xml (window layout)
--
-- Safety rules built in:
--   * Only people YOU add to the roster are listened to. A stranger's hello is shown as a
--     request ("/pg add Name" to accept) and gets no reply, so nobody can enrol themselves.
--   * Every incoming field is checked (known order word, numbers in range). Bad lines are dropped.
--   * Incoming text has markup characters stripped before it is shown or relayed.
--   * Per-sender flood limit, send queue with a spacing delay, paused during loading screens.
--   * Nothing is ever sent to your warband unless you type /pg relay.

if not Pigeon then Pigeon = {} end
local P = Pigeon

-- Settings ---------------------------------------------------------------------
P.VERSION = "1.1"
P.PREFIX = "PGN1"              -- protocol tag + version
P.SEP = "|"
P.tellCmd = "/w"               -- same whisper command Warband Lead Helper and RoR Auto Inviter use
P.sendInterval = 1.0           -- seconds between queued whispers (WLH uses 2). Tune with /pg rate
P.maxQueue = 100
P.maxLen = 200                 -- payload cap (conservative)
P.maxRoster = 40
P.maxPending = 20
P.maxHistory = 50
P.expirySeconds = 300          -- orders fade after this long
P.posExpirySeconds = 120
P.seenSeconds = 120
P.floodMax = 20                -- lines accepted per sender per window
P.floodWindow = 10
P.noteMax = 60
P.textMax = 150
P.loading = false
P.dryRun = false
P.probe = false
P.CHANNEL_NAME = "Command"          -- the one custom channel a player may join; leaders talk and Pigeon posts here
P.CHANNEL_CMD = "/9"                -- first custom channel slot: the one custom channel a player may join is /9 (override with /pg channel /N)
P.discoverMax = 20             -- hellos per discovery run
P.presenceBeat = 600           -- seconds of silence before a 'still leading' announcement
P.presenceExpiry = 1500        -- a leader we have not heard from in this long is marked inactive
P.maxSuggest = 20
P.mirrorToChat = true          -- window turns this off while it is open
P.onComms = nil                -- hook set by the window
P.onRoster = nil

-- Order words. tag = Warband Lead Helper voice code, kind = map pin colour group.
P.Verbs = {
    attack    = { tag = "AT", text = "ATTACK",              kind = "attack" },
    push      = { tag = "PS", text = "PUSH",                kind = "attack" },
    objective = { tag = "BO", text = "TAKE OBJECTIVE",      kind = "attack" },
    hold      = { tag = "HD", text = "HOLD, DO NOT ENGAGE", kind = "defend" },
    holdline  = { tag = "HP", text = "HOLD THE LINE",       kind = "defend" },
    stay      = { tag = "ST", text = "STAY HERE",           kind = "defend" },
    regroup   = { tag = "RG", text = "REGROUP",             kind = "regroup" },
    release   = { tag = "RL", text = "RELEASE AND REGROUP", kind = "regroup" },
    move      = { tag = "MV", text = "MOVE OUT",            kind = "move" },
    zone      = { tag = "ZN", text = "CHANGE ZONE",         kind = "move" },
    retreat   = { tag = "BK", text = "FALL BACK",           kind = "move" },
    ready     = { tag = "RD", text = "GET READY",           kind = "other" },
    cancel    = { tag = "CX", text = "CANCEL",              kind = "other" },
    reinforce = { tag = "LF", text = "NEED REINFORCEMENTS", kind = "other" },
}

-- Warband Lead Helper voice tags. kind = map pin colour group, loc = the message is about a
-- place, so the sender's position (or the bar's Target) is attached and a pin is drawn.
P.Tags = {
    AT = { kind = "attack", loc = true }, PS = { kind = "attack", loc = true }, BO = { kind = "attack", loc = true },
    HD = { kind = "defend", loc = true }, HP = { kind = "defend", loc = true }, ST = { kind = "defend", loc = true },
    RG = { kind = "regroup", loc = true }, RL = { kind = "regroup", loc = true },   MV = { kind = "move", loc = true },
    BK = { kind = "move", loc = true },   ZN = { kind = "move" },
}
-- Map-menu markers (icons from WARCommander): four groups to send somewhere, and enemy sightings.
P.Tags.G1 = { kind = "group1", loc = true }; P.Tags.G2 = { kind = "group2", loc = true }
P.Tags.G3 = { kind = "group3", loc = true }; P.Tags.G4 = { kind = "group4", loc = true }
P.Tags.SW = { kind = "spotwb", loc = true };  P.Tags.SG = { kind = "spotgrp", loc = true }
P.Tags.CF = { kind = "conflict", loc = true }
for _, t in ipairs({ "BF", "RD", "CX", "CD", "LF", "BH", "OI", "EC", "LT", "RT", "CR", "CN", "MR", "MN" }) do
    P.Tags[t] = { kind = "other" }
end
P.wlhTextMax = 100

-- How Warband Lead Helper messages are shown: one short label and a colour per voice tag, using WLH's own
-- colour scheme (red attack, yellow hold, green move, blue regroup). keep = the message carries a name or a
-- number (BO name, zone, countdown seconds) so its own text is kept when no place could be matched.
local RED, YEL, GRN, BLU, WHT = { 240, 90, 90 }, { 255, 200, 90 }, { 110, 220, 120 }, { 120, 165, 255 }, { 235, 235, 235 }
local LABELS = {
    BF = { "CHECK BUFFS", WHT },          RD = { "GET READY", GRN },           MV = { "MOVE OUT - FOLLOW", GRN },
    BO = { "TAKE BO", GRN, true },        ZN = { "CHANGE ZONE", GRN, true },   RG = { "REGROUP", BLU },
    RL = { "RELEASE + REGROUP", BLU },    ST = { "STAY HERE", YEL },           HD = { "HOLD - DO NOT ENGAGE", YEL },
    PS = { "PREPARE TO PUSH", YEL },      AT = { "ATTACK", RED },              BH = { "ENEMY BEHIND", RED },
    OI = { "WATCH THE OIL", RED },        CD = { "COUNTDOWN", WHT, true },     CX = { "CANCELLED", WHT },
    LF = { "NEED REINFORCEMENTS", WHT },  LT = { "LEFT", WHT },                RT = { "RIGHT", WHT },
    CR = { "PREPARE TO CHANNEL", WHT },   CN = { "CHANNEL NOW", WHT },         MR = { "PREPARE MORALES", WHT },
    MN = { "MORALES NOW", WHT },          BK = { "FALL BACK", BLU },           EC = { "ENEMY CHARGE", RED },
    HP = { "HOLD THE LINE", YEL },
    G1 = { "GROUP 1 MOVE", { 100, 150, 200 } }, G2 = { "GROUP 2 MOVE", { 170, 90, 220 } },
    G3 = { "GROUP 3 MOVE", { 60, 190, 60 } },   G4 = { "GROUP 4 MOVE", { 220, 220, 60 } },
    SW = { "WARBAND SPOTTED", { 250, 70, 70 } }, SG = { "GROUP SPOTTED", { 250, 70, 70 } },
    CF = { "CONFLICT", { 250, 140, 40 } },
}
P.Hist = {}                 -- name -> that leader's last 5 orders, newest first
P.seenLeading = {}          -- name -> clock of their last 'is leading a warband' announcement (their own claim)
P.who = nil                 -- running /channelwho scan
P.Colours = { name = { 150, 190, 230 }, place = { 255, 215, 120 }, note = { 170, 170, 170 }, plain = WHT }
function P.TagLabel(tag) return LABELS[tag] and LABELS[tag][1] end
function P.TagColour(tag) return LABELS[tag] and LABELS[tag][2] or WHT end
function P.TagKeepsText(tag) return LABELS[tag] and LABELS[tag][3] == true end

-- State ------------------------------------------------------------------------
P.roster = {}                -- roster[name] = { t = lastHeardClock }
P.pending = {}                 -- pending[name] = clock (asked to join, not accepted)
P.dismissed = {}               -- dismissed[name] = clock (declined; not offered again for a while)
P.suggest = {}                 -- suggest[name] = { by = leader who mentioned them, t = clock }
P.helloed = {}                 -- names we sent a discovery hello to this session
P.leading = nil                -- am I a warband leader right now (nil = not checked yet)
P.lastBeat = 0
P.Board = {}                   -- latest order per leader
P.Positions = {}               -- latest reported position per leader
P.seen = {}
P.rate = {}
P.queue = {}
P.history = {}
P.clock = 0
P.seq = math.random(1000, 99999)
local sinceSend, sinceCheck, busy = 0, 0, false

-- Helpers ----------------------------------------------------------------------
local function Log(msg)
    TextLogAddEntry("Chat", 0, towstring("[Pigeon] " .. tostring(msg)))
end
P.Print = Log

-- segs (optional) = { { text, {r,g,b} }, ... } the same line split into coloured pieces for the window.
local function Comms(line, segs, rowOnly)
    P.history[#P.history + 1] = line
    if #P.history > P.maxHistory then table.remove(P.history, 1) end
    if P.mirrorToChat then Log(line) end
    if rowOnly then
        if P.onRows then pcall(P.onRows) end          -- orders live in the leader rows, not in the message area
    elseif P.onComms then
        pcall(P.onComms, line, segs)
    end
end
P.Comms = Comms

local function NotifyRoster()
    if P.onRoster then pcall(P.onRoster) end
    if P.onRows then pcall(P.onRows) end
    if PigeonBar and PigeonBar.Refresh then pcall(PigeonBar.Refresh) end
end

local function CleanName(n) return (string.gsub(tostring(n), "%^.*$", "")) end

function P.ValidName(name)
    name = tostring(name or "")
    return name ~= "" and string.len(name) <= 48 and not string.find(name, "[%c%s<>/|]")
end

local function Me()
    local ok, n = pcall(function() return tostring(GameData.Player.name) end)
    if ok and n and n ~= "" then return CleanName(n) end
    return "me"
end
P.Me = Me

-- Text going out: no separators or control characters.
local function WireField(v)
    local s = tostring(v == nil and "" or v)
    s = string.gsub(s, "[%c|]", " ")
    return s
end

-- Text coming in, before it is shown: no markup or control characters, bounded length.
local function DisplayText(s, max)
    s = tostring(s == nil and "" or s)
    s = string.gsub(s, "[%c<>]", "")
    max = max or 120
    if string.len(s) > max then s = string.sub(s, 1, max) end
    return s
end
P.DisplayText = DisplayText

-- Number field: returns value, nil for "-" or empty, and (nil, true) when malformed/out of range.
local function Num(s, lo, hi)
    if s == nil or s == "" or s == "-" then return nil, false end
    if not string.find(s, "^%d+$") or string.len(s) > 7 then return nil, true end
    local n = tonumber(s)
    if n < lo or n > hi then return nil, true end
    return n, false
end

local function Split(s, sep)
    local out, start = {}, 1
    while true do
        local i = string.find(s, sep, start, true)
        if not i then
            out[#out + 1] = string.sub(s, start)
            break
        end
        out[#out + 1] = string.sub(s, start, i - 1)
        start = i + 1
    end
    return out
end

local function LinkCall(name, ...)
    local LK = P.Links
    if LK and LK[name] then
        local ok, r = pcall(LK[name], ...)
        if ok then return r end
        Log("link error in " .. name .. ": " .. tostring(r))
    end
    return nil
end

local function CurrentPos()
    local LK = P.Links
    if LK and LK.PlayerPosition then
        local ok, zone, zx, zy = pcall(LK.PlayerPosition)
        if ok then return zone, zx, zy end
    end
    return nil, nil, nil
end

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Remembers an order as the leader's latest and keeps their last five.
function P.Record(name, o)
    P.Board[name] = o
    local h = P.Hist[name]
    if not h then h = {}; P.Hist[name] = h end
    table.insert(h, 1, o)
    while #h > 5 do table.remove(h) end
    if P.onRows then pcall(P.onRows) end
end

-- One row per approved leader (you first): { name, you, active, o = latest order or nil }.
function P.Rows()
    local me = Me()
    local rows = { { name = me, you = true, active = true, o = P.Hist[me] and P.Hist[me][1] } }
    local names = {}
    for name in pairs(P.roster) do names[#names + 1] = name end
    local function t(n) local h = P.Hist[n]; return h and h[1] and h[1].t or -1 end
    table.sort(names, function(a, b)
        local function live(n) local r = P.roster[n]; return r.active ~= false and r.heard ~= nil and P.clock - r.heard < P.presenceExpiry end
        local aa, ab = live(a), live(b)
        if aa ~= ab then return aa end
        if t(a) ~= t(b) then return t(a) > t(b) end
        return a < b
    end)
    for _, n in ipairs(names) do
        local r = P.roster[n]
        local state
        if r.active == false then state = "stepped"                                      -- said they stopped leading
        elseif r.heard and P.clock - r.heard < P.presenceExpiry then state = "live"      -- heard from recently
        else state = "quiet" end                                                         -- not heard (this session / for a while)
        local since = r.heard and math.floor((P.clock - r.heard) / 60) or nil
        rows[#rows + 1] = { name = n, active = (state == "live"), state = state, since = since, o = P.Hist[n] and P.Hist[n][1] }
    end
    return rows
end

function P.StatusLine()
    local n = 0
    for _, r in pairs(P.roster) do if r.active ~= false then n = n + 1 end end
    local where = P.ChannelOn() and P.Saved.channel or "whispers"
    return where .. "  -  " .. n .. " trusted"
end

function P.RosterString()
    local names = {}
    for name in pairs(P.roster) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then return "Leaders: none yet (use + Player or the yellow buttons)" end
    local extra = #names - 4
    while #names > 4 do table.remove(names) end
    return "Leaders: " .. table.concat(names, ", ") .. (extra > 0 and (" +" .. extra .. " more") or "")
end

-- Payload layout: PREFIX|TYPE|FROM|SEQ|field...
local function Build(msgType, seq, ...)
    local parts = { P.PREFIX, msgType, Me(), tostring(seq) }
    local args = { ... }
    for i = 1, select("#", ...) do parts[#parts + 1] = WireField(args[i]) end
    local payload = table.concat(parts, P.SEP)
    if string.len(payload) > P.maxLen then
        Log("message too long, not sent")
        return nil
    end
    return payload
end

-- Lifecycle --------------------------------------------------------------------
function P.Initialize()
    if type(P.Saved) ~= "table" then P.Saved = {} end
    -- A hand-edited or damaged saved file must not stop the addon from starting: keep only values of the right kind.
    if type(P.Saved.roster) ~= "table" then P.Saved.roster = {} end
    for _, k in ipairs({ "zoneShift", "zoneFix" }) do
        if P.Saved[k] ~= nil and type(P.Saved[k]) ~= "table" then P.Saved[k] = nil end
    end
    if P.Saved.posShift ~= nil and not (type(P.Saved.posShift) == "table" and tonumber(P.Saved.posShift[1]) and tonumber(P.Saved.posShift[2])) then P.Saved.posShift = nil end
    for _, k in ipairs({ "pinScale", "arrowScale" }) do
        local v = tonumber(P.Saved[k])
        if P.Saved[k] ~= nil and not (v and v >= 0.3 and v <= 5) then P.Saved[k] = nil end
    end
    if P.Saved.lastPos ~= nil and type(P.Saved.lastPos) ~= "table" then P.Saved.lastPos = nil end
    -- the channel must be one of the numbered chat slots: anything else (/camp, /g ...) would run as a command
    if P.Saved.channel ~= nil and not string.find(tostring(P.Saved.channel), "^/[1-9]$") then P.Saved.channel = nil end
    if P.Saved.pins == nil then P.Saved.pins = true end
    if P.Saved.parrot == nil then P.Saved.parrot = true end
    if P.Saved.presence == nil then P.Saved.presence = true end
    if P.Saved.colour == nil then P.Saved.colour = true end
    if P.Saved.discover == nil then P.Saved.discover = true end
    if P.Saved.accept == nil then P.Saved.accept = "known" end   -- off | friends | guild | known
    if P.Saved.channel == "/pigeondata" or P.Saved.channel == "/command" then P.Saved.channel = nil end   -- earlier guesses; the custom channel is /9
    if P.Saved.channel == nil and not P.Saved.channelOff then P.Saved.channel = P.CHANNEL_CMD end
    for name in pairs(P.Saved.roster) do
        if P.ValidName(name) then P.roster[name] = { t = P.clock } end
    end

    RegisterEventHandler(SystemData.Events.CONVERSATION_TEXT_ARRIVED, "Pigeon.OnConversation")
    if SystemData.Events.CHAT_TEXT_ARRIVED then
        RegisterEventHandler(SystemData.Events.CHAT_TEXT_ARRIVED, "Pigeon.OnChat")
    end
    if SystemData.Events.LOADING_BEGIN then
        RegisterEventHandler(SystemData.Events.LOADING_BEGIN, "Pigeon.OnLoadingBegin")
        RegisterEventHandler(SystemData.Events.LOADING_END, "Pigeon.OnLoadingEnd")
    end
    -- Our own copy of where the player is (same game event MapMonster listens to), for when MapMonster has lost track.
    if SystemData.Events.PLAYER_POSITION_UPDATED then
        RegisterEventHandler(SystemData.Events.PLAYER_POSITION_UPDATED, "Pigeon.OnPlayerPosition")
    end
    if SystemData.Events.PLAYER_ZONE_CHANGED then
        RegisterEventHandler(SystemData.Events.PLAYER_ZONE_CHANGED, "Pigeon.OnPlayerZone")
    end

    if LibSlash then
        LibSlash.RegisterSlashCmd("pigeon", function(args) P.SlashCmd(args) end)
        LibSlash.RegisterSlashCmd("pg", function(args) P.SlashCmd(args) end)
    end

    -- Optional add-on bridges. A failure here must never stop messaging.
    if P.Links and P.Links.Init then
        local ok, err = pcall(P.Links.Init)
        if not ok then Log("integrations failed to start: " .. tostring(err)) end
    end
    if PigeonUI and PigeonUI.Initialize then
        local ok, err = pcall(PigeonUI.Initialize)
        if not ok then Log("window failed: " .. tostring(err)) end
    end
    if PigeonBar and PigeonBar.Initialize then
        local ok, err = pcall(PigeonBar.Initialize)
        if not ok then Log("button bar failed: " .. tostring(err)) end
    end
    if PigeonMap and PigeonMap.Initialize then
        local ok, err = pcall(PigeonMap.Initialize)
        if not ok then Log("map menu failed: " .. tostring(err)) end
    end
    Log("v" .. P.VERSION .. " loaded. Controls are at the top of the Pigeon window; type /pg for commands.")
end

function P.OnPlayerPosition(x, y)
    local z
    pcall(function() z = tonumber(GameData.Player.zone) end)
    if tonumber(x) and tonumber(y) then P.world = { x = tonumber(x), y = tonumber(y), zone = z, t = P.clock } end
end
function P.OnPlayerZone() P.world = nil end          -- the next position event starts fresh in the new zone
function P.OnLoadingBegin() P.loading = true; P.world = nil end
function P.OnLoadingEnd()
    P.loading = false
    sinceSend = 0
    if PigeonBar and PigeonBar.Refresh then pcall(PigeonBar.Refresh) end   -- zone may have changed
end

function P.Shutdown()
    if PigeonBar and PigeonBar.Shutdown then pcall(PigeonBar.Shutdown) end
    if PigeonMap and PigeonMap.Shutdown then pcall(PigeonMap.Shutdown) end
    LinkCall("Shutdown")
    UnregisterEventHandler(SystemData.Events.CONVERSATION_TEXT_ARRIVED, "Pigeon.OnConversation")
    if SystemData.Events.CHAT_TEXT_ARRIVED then
        UnregisterEventHandler(SystemData.Events.CHAT_TEXT_ARRIVED, "Pigeon.OnChat")
    end
    if SystemData.Events.PLAYER_POSITION_UPDATED then
        UnregisterEventHandler(SystemData.Events.PLAYER_POSITION_UPDATED, "Pigeon.OnPlayerPosition")
    end
    if SystemData.Events.PLAYER_ZONE_CHANGED then
        UnregisterEventHandler(SystemData.Events.PLAYER_ZONE_CHANGED, "Pigeon.OnPlayerZone")
    end
    if SystemData.Events.LOADING_BEGIN then
        UnregisterEventHandler(SystemData.Events.LOADING_BEGIN, "Pigeon.OnLoadingBegin")
        UnregisterEventHandler(SystemData.Events.LOADING_END, "Pigeon.OnLoadingEnd")
    end
end

local sinceTemp = 0
function P.OnUpdate(elapsed)
    elapsed = elapsed or 0
    P.clock = P.clock + elapsed
    if PigeonUI and PigeonUI.Tick then pcall(PigeonUI.Tick) end
    sinceTemp = (sinceTemp or 0) + elapsed
    if sinceTemp >= 0.2 then
        sinceTemp = 0
        if P.Links and P.Links.TempTick then pcall(P.Links.TempTick, P.clock) end
    end

    sinceSend = sinceSend + elapsed
    if sinceSend >= P.sendInterval and #P.queue > 0 and not P.loading then
        sinceSend = 0
        local line = table.remove(P.queue, 1)
        P.lastSentLine, P.lastSentAt = line, P.clock
        if P.dryRun then
            Log("DRY " .. line)
        else
            SendChatText(towstring(line), L"")
        end
    end

    sinceCheck = sinceCheck + elapsed
    if sinceCheck >= 10 then
        sinceCheck = 0
        for name, o in pairs(P.Board) do
            if P.clock - o.t > P.expirySeconds then P.Board[name] = nil end
        end
        for name, h in pairs(P.Hist) do
            for i = #h, 1, -1 do if P.clock - h[i].t > 1800 then table.remove(h, i) end end
            if #h == 0 then P.Hist[name] = nil end
        end
        if P.onRows then pcall(P.onRows) end                  -- ages tick up
        for name, p in pairs(P.Positions) do
            if P.clock - p.t > P.posExpirySeconds then P.Positions[name] = nil end
        end
        for key, t in pairs(P.seen) do
            if P.clock - t > P.seenSeconds then P.seen[key] = nil end
        end
        for name, r in pairs(P.rate) do
            if P.clock - r.t > 60 then P.rate[name] = nil end
        end
        for name, t in pairs(P.pending) do
            if P.clock - t > 600 then P.pending[name] = nil; NotifyRoster() end
        end
        for name, sg in pairs(P.suggest) do
            if P.clock - sg.t > 900 then P.suggest[name] = nil; NotifyRoster() end
        end
        for name, r in pairs(P.roster) do
            if r.pres and P.clock - r.t > P.presenceExpiry then
                r.active, r.pres = false, nil
                P.Board[name] = nil
                P.Positions[name] = nil
                LinkCall("ClearPin", name)
                Log(name .. " has gone quiet and is marked inactive")
                NotifyRoster()
            end
        end
        pcall(P.ChannelSetup)
        if P.who and P.clock > P.who.untilT then pcall(P.WhoFinish) end
        if P.Saved.autowho ~= false and P.ChannelOn() and P.chanOk and not P.who and P.clock > 60
           and P.clock - (P.lastWho or -10000) > 900 and P.IsLeader() then
            P.lastWho = P.clock
            P.WhoScan(true)
        end
        local okp, errp = pcall(P.PresenceTick)
        if not okp then Log("presence check failed: " .. tostring(errp)) end
        LinkCall("Tick", P.clock)
    end
end

-- Roster -----------------------------------------------------------------------
local function QueueTell(to, payload)
    if not P.ValidName(to) or #P.queue >= P.maxQueue then return end
    P.queue[#P.queue + 1] = P.tellCmd .. " " .. to .. " " .. payload
end

-- Channel transport: one line to a shared chat channel instead of one whisper per leader.
-- P.Saved.channel is the slash command of the channel, e.g. "/pigeondata" (nil = whispers only).
function P.ChannelOn()
    local c = P.Saved and P.Saved.channel
    return type(c) == "string" and string.find(c, "^/%w+$") ~= nil
end

local function QueueChannel(payload)
    if #P.queue >= P.maxQueue then return end
    if not P.chanSentAt then P.chanSentAt = P.clock end
    P.lastChannelSend = P.clock
    P.queue[#P.queue + 1] = P.Saved.channel .. " " .. payload
end

-- Readable channel lines: leaders read plain English, Pigeon reads the short {pg1 ...} tail.
--   Take the BO at Festenplatz {pg1 WLH 4821 BO 106 35100 9900}
-- Only the tail matters to Pigeon; people in the channel can ignore it.
local function ChannelText(s, max)
    s = tostring(s == nil and "" or s)
    s = string.gsub(s, "[%c|{}<>]", " ")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    if string.len(s) > max then s = string.sub(s, 1, max) end
    return s
end

local function TailField(v)
    v = tostring(v == nil and "-" or v)
    if not string.find(v, "^[%w%-]+$") then return "-" end
    return v
end

-- Returns the text to say in the channel, or nil if this message type has no channel form.
function P.ChannelLine(msgType, seq, ...)
    local a = { ... }
    local function tail(...)
        local parts = { "{pg1", msgType, tostring(seq) }
        for i = 1, select("#", ...) do parts[#parts + 1] = TailField((select(i, ...))) end
        return table.concat(parts, " ") .. "}"
    end
    if msgType == "TXT" then
        return ChannelText(a[1], P.textMax)                      -- plain talk, nothing to decode
    elseif msgType == "ORD" then                                 -- a typed order is sent as a tagged message
        local v = P.Verbs[a[1]]
        if not v then return nil end
        local text = v.text
        if a[5] and a[5] ~= "-" then text = text .. " ETA " .. a[5] .. "m" end
        if a[6] and a[6] ~= "" then text = text .. " - " .. a[6] end
        return P.ChannelLine("WLH", seq, v.tag, a[2], a[3], a[4], text)
    elseif msgType == "WLH" then
        local human = ChannelText(a[5], P.wlhTextMax)
        if human == "" then return nil end
        return human .. " " .. tail(a[1] or "-", a[2], a[3], a[4])
    elseif msgType == "ARW" then
        local human = ChannelText(a[7], P.wlhTextMax)
        if human == "" then return nil end
        return human .. " " .. tail(a[1] or "-", a[2], a[3], a[4], a[5], a[6])
    elseif msgType == "POS" then
        local place = LinkCall("PlaceText", tonumber(a[1]), tonumber(a[2]), tonumber(a[3]))
        place = ChannelText(place, 60)
        if place == "" then place = "zone " .. tostring(a[1]) end
        return "position: " .. place .. " " .. tail(a[1], a[2], a[3])
    elseif msgType == "PRQ" then
        return "who is leading a warband? " .. tail()
    elseif msgType == "PRS" then
        return (tostring(a[1]) == "1" and "is leading a warband" or "stepped down as warband leader") .. " " .. tail(a[1])
    end
    return nil
end

-- Joins the default channel once (channels persist across logouts) and warns if our own lines never
-- come back, which usually means the channel was not joined or its slash command differs.
function P.ChannelSetup()
    if P.loading or not P.ChannelOn() or P.clock < 12 then return end
    if P.Saved.channel == P.CHANNEL_CMD and P.Saved.joined ~= P.CHANNEL_NAME then
        table.insert(P.queue, 1, "/channeljoin " .. P.CHANNEL_NAME)
        P.Saved.joined = P.CHANNEL_NAME
        Log("joining chat channel " .. P.CHANNEL_NAME .. " (" .. P.CHANNEL_CMD .. "). A player can only be in ONE custom channel: if you were already in another, leave it with /channelleave <name>, then /pg channel on. /pg channel off to opt out.")
    end
    if P.chanSentAt and not P.chanOk and not P.chanWarned and P.clock - P.chanSentAt > 30 then
        P.chanWarned = true
        Log("I have not seen my own line come back from " .. tostring(P.Saved.channel) ..
            ". Check /channellist. If you are in another custom channel, /channelleave <name> then /pg channel on; or set the right command with /pg channel /command.")
    end
end

function P.SendHello(to)
    P.seq = P.seq + 1
    local payload = Build("HLO", P.seq)
    if payload then QueueTell(to, payload) end
end

function P.AddLeader(name, quiet)
    name = CleanName(name)
    if not P.ValidName(name) then
        if not quiet then Log("not a valid player name: " .. tostring(name)) end
        return false
    end
    if name == Me() then return false end
    local isNew = (P.roster[name] == nil)
    local isNew0 = isNew
    if isNew and Count(P.roster) >= P.maxRoster then
        Log("roster is full (" .. P.maxRoster .. ")")
        return false
    end
    P.roster[name] = { t = P.clock }
    local wasWaiting = P.pending[name] ~= nil or P.suggest[name] ~= nil
    P.pending[name] = nil
    P.suggest[name] = nil
    if P.Saved then P.Saved.roster[name] = true end
    if wasWaiting and not isNew0 then NotifyRoster() end
    if isNew then
        Log("added leader " .. name)
        NotifyRoster()
        if not P.ChannelOn() then P.SendHello(name) end   -- whisper mode: they see a request and must add you back
    end
    return isNew
end

function P.RemoveLeader(name)
    name = CleanName(name)
    P.roster[name] = nil
    P.Hist[name] = nil
    P.Board[name] = nil
    P.Positions[name] = nil
    if P.Saved then P.Saved.roster[name] = nil end
    LinkCall("ClearPin", name)
    Log("removed " .. name)
    NotifyRoster()
end

function P.ShowRoster()
    local n = 0
    for name, r in pairs(P.roster) do
        n = n + 1
        Log(name .. (r.active == false and " [not leading]" or (r.pres and " [leading]" or "")) ..
            " (last heard " .. math.floor(P.clock - r.t) .. "s ago)")
    end
    if n == 0 then Log("roster empty") end
end

function P.ShowPending()
    local n = 0
    for name in pairs(P.pending) do
        n = n + 1
        Log(name .. " asked to join. /pg add " .. name .. " to accept")
    end
    if n == 0 then Log("no pending requests") end
end

local function NotePending(sender)
    local why = P.AutoAcceptReason and P.AutoAcceptReason(sender)
    if why then
        if P.AddLeader(sender, true) then Log("auto-linked " .. sender .. " (" .. why .. ")") end
        return
    end
    if P.pending[sender] or Count(P.pending) >= P.maxPending then return end
    if P.dismissed[sender] and P.clock - P.dismissed[sender] < 1800 then return end
    P.pending[sender] = P.clock
    Log(sender .. " is using Pigeon and wants to link. Click Add on the Pigeon bar, or type /pg add " .. sender .. ".")
    NotifyRoster()
end

-- Presence: who is leading a warband right now -----------------------------------
-- Leadership check as Warband Lead Helper does it: in a warband, group leader, not an assistant.
function P.IsLeader()
    local ok, r = pcall(function()
        if type(IsWarBandActive) ~= "function" or not IsWarBandActive() then return false end
        local pl = GameData and GameData.Player
        return pl ~= nil and pl.isGroupLeader == true and pl.isWarbandAssistant ~= true
    end)
    return ok and r == true
end

-- state 1 = leading, 0 = not any more. heartbeatOnly: skip leaders we think are offline.
function P.SendPresence(state, to, heartbeatOnly)
    P.seq = P.seq + 1
    local payload = Build("PRS", P.seq, state)
    if not payload then return end
    if P.ChannelOn() then
        QueueChannel(P.ChannelLine("PRS", P.seq, state))   -- everyone in the channel sees it; only people who trust you act on it
    elseif to then
        QueueTell(to, payload)
    else
        for name, r in pairs(P.roster) do
            if not (heartbeatOnly and r.active == false) then QueueTell(name, payload) end
        end
    end
    P.lastBeat = P.clock
end

function P.PresenceTick()
    if P.loading or not (P.Saved and P.Saved.presence) then return end
    local now = P.IsLeader()
    if P.leading == nil then
        P.leading = now
        if now then
            P.SendPresence(1)
            P.Discover(false)
        elseif P.Saved.wasLeader then
            P.SendPresence(0)                 -- we left as a leader last time
        end
    elseif now ~= P.leading then
        P.leading = now
        P.SendPresence(now and 1 or 0)
        if now then P.Discover(false) end
    elseif now and P.clock - P.lastBeat >= P.presenceBeat
        and not (P.ChannelOn() and P.lastChannelSend and P.clock - P.lastChannelSend < P.presenceBeat) then
        P.SendPresence(1, nil, true)              -- only after a quiet spell: other lines already show we are around
    end
    P.Saved.wasLeader = now
end

-- Finding other leaders: friends list and guild only -------------------------------
local function NameList(fn)
    local out = {}
    local ok, data = pcall(fn)
    if ok and type(data) == "table" then
        for _, v in pairs(data) do
            if type(v) == "table" and v.name ~= nil then
                local n = CleanName(tostring(v.name))
                if P.ValidName(n) then
                    local z = tonumber(v.zoneID or v.zoneId or v.zone)
                    out[#out + 1] = { name = n, zone = z }
                end
            end
        end
    end
    return out
end

P.Sources = {
    friends = function() return NameList(function() return GetFriendsList() end) end,
    guild   = function() return NameList(function() return GetGuildMemberData() end) end,
}

local function InList(list, name)
    local low = string.lower(name)
    for _, e in ipairs(list) do
        if string.lower(e.name) == low then return true end
    end
    return false
end

-- Returns "friend" / "guild" when /pg accept allows linking this name automatically.
function P.AutoAcceptReason(name)
    local mode = P.Saved and P.Saved.accept or "off"
    if mode == "off" then return nil end
    if (mode == "friends" or mode == "known") and InList(P.Sources.friends(), name) then return "on your friends list" end
    if (mode == "guild" or mode == "known") and InList(P.Sources.guild(), name) then return "in your guild" end
    if mode == "leaders" and P.seenLeading[name] and P.clock - P.seenLeading[name] < 1500 then return "announced it is leading a warband" end
    return nil
end

-- Says hello to online friends and guildmates so linked leaders can find each other.
-- Friends are always tried; guildmates only when the list says they are online (zone shown),
-- so a big guild is not whispered. Each name is tried once per session.
function P.Discover(manual)
    if not manual and (P.ChannelOn() or not (P.Saved and P.Saved.discover)) then return 0 end
    local sent = 0
    local function try(list, needZone)
        for _, e in ipairs(list) do
            if sent >= P.discoverMax then return end
            local n = e.name
            if n ~= Me() and not P.roster[n] and not P.pending[n] and not P.helloed[n] then
                local online = true
                if e.zone ~= nil then online = e.zone ~= 0 elseif needZone then online = false end
                if online then
                    P.helloed[n] = true
                    P.SendHello(n)
                    sent = sent + 1
                end
            end
        end
    end
    try(P.Sources.friends(), false)
    try(P.Sources.guild(), true)
    if manual then Log("discovery: hello sent to " .. sent .. " friend(s)/guildmate(s)") end
    return sent
end

-- Introductions: tell a newly linked leader who else you are linked with (they approve each) ----
function P.Introduce(to)
    if P.ChannelOn() then return end        -- the channel already lets everyone find everyone
    local names = {}
    for name, r in pairs(P.roster) do
        if name ~= to and r.linked and r.active ~= false then names[#names + 1] = name end
    end
    table.sort(names)
    local i = 1
    while i <= #names and i <= 12 do
        local chunk = {}
        for j = i, math.min(i + 3, #names, 12) do chunk[#chunk + 1] = names[j] end
        P.seq = P.seq + 1
        local payload = Build("INT", P.seq, table.concat(chunk, ","))
        if payload then QueueTell(to, payload) end
        i = i + 4
    end
end

local function MarkLinked(sender, entry)
    if entry.linked then return end
    entry.linked = true
    P.Introduce(sender)
    if P.leading then P.SendPresence(1, sender) end
end

-- Everyone waiting for a yes/no: strangers who asked to link first, then introductions.
function P.Waiting()
    local out = {}
    local names = {}
    for name in pairs(P.pending) do names[#names + 1] = name end
    table.sort(names, function(a, b) return P.pending[a] < P.pending[b] end)
    for _, name in ipairs(names) do out[#out + 1] = { name = name, via = "asked to link" } end
    names = {}
    for name in pairs(P.suggest) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do out[#out + 1] = { name = name, via = "suggested by " .. P.suggest[name].by } end
    return out
end

function P.Dismiss(name)
    P.pending[name] = nil
    P.suggest[name] = nil
    P.dismissed[name] = P.clock
    NotifyRoster()
end

-- Name of the friendly player you have targeted (nil if none).
function P.TargetName()
    local ok, n = pcall(function()
        local w = TargetInfo:UnitName("selffriendlytarget")
        return w and tostring(w) or nil
    end)
    if ok and n and n ~= "" then return CleanName(n) end
    return nil
end

function P.AddTarget()
    local name = P.TargetName()
    if not name then Log("target a friendly player first"); return false end
    if P.roster[name] then Log(name .. " is already on your roster"); return false end
    return P.AddLeader(name)
end

function P.AddSuggested()
    local n = 0
    for name in pairs(P.suggest) do
        if P.AddLeader(name, true) then n = n + 1 end
    end
    P.suggest = {}
    Log("linked with " .. n .. " suggested leader(s)")
end

-- Sending ----------------------------------------------------------------------
-- Orders and WLH repeats may only come from someone who is actually leading a warband (anyone can still say hello,
-- add leaders etc.). /pg test on lifts this so the addon can be tried out alone.
local LEADER_ONLY = { ORD = true, WLH = true, ARW = true, POS = true }
function P.Broadcast(msgType, ...)
    if LEADER_ONLY[msgType] and not (P.Saved and P.Saved.testMode) and not P.IsLeader() then
        return false, "you are not leading a warband (/pg test on to try it out alone)"
    end
    P.seq = P.seq + 1
    local payload = Build(msgType, P.seq, ...)
    if not payload then return false, "message too long" end
    if P.ChannelOn() then
        local line = P.ChannelLine(msgType, P.seq, ...)
        if not line or line == "" then return false, "nothing readable to say in the channel" end
        if string.len(line) > P.maxLen then          -- shorten the readable part, never cut the {pg1 ...} tail
            local human, tailPart = string.match(line, "^(.-)%s*({pg1 .*)$")
            if human and tailPart then
                line = string.sub(human, 1, math.max(5, P.maxLen - string.len(tailPart) - 1)) .. " " .. tailPart
            else
                line = string.sub(line, 1, P.maxLen)
            end
        end
        if #P.queue >= P.maxQueue then return false, "send queue is full" end
        QueueChannel(line)
        return true
    end
    local n = 0
    for name, r in pairs(P.roster) do
        if r.active ~= false then          -- leaders who stepped down are skipped
            QueueTell(name, payload)
            n = n + 1
        end
    end
    if n == 0 then Log(next(P.roster) and "no active leaders on your roster" or "roster empty, nobody to send to") end
    return n > 0, (n == 0) and "no active leaders to send to" or nil
end

function P.DescribeOrder(o, brief)
    local v = o.verb and P.Verbs[o.verb]
    local base, colour
    if o.text then              -- a message the leader sent to their warband through Warband Lead Helper
        base, colour = o.text, P.TagColour(o.tag)
    else
        base = v and v.text or tostring(o.verb)
        colour = v and P.TagColour(v.tag) or P.Colours.plain
    end
    local link
    if o.zone and o.zx and o.zy then       -- clicking the text opens the map on it (arrows: on the end point)
        link = "PGN:" .. o.zone .. "," .. (o.zx2 or o.zx) .. "," .. (o.zy2 or o.zy)
    end
    local segs = { { base, colour, link } }
    local parts = { base }
    local function add(text, c, lnk)
        parts[#parts + 1] = text
        segs[#segs + 1] = { " " .. text, c, lnk }
    end
    local place = LinkCall("PlaceText", o.zone, o.zx, o.zy)
    if place and place ~= "" and o.zx then
        local first = string.match(place, "^([^,]+)")
        if not (first and string.find(string.lower(base), string.lower(first), 1, true)) then   -- not twice
            add("at " .. place, P.Colours.place, link)
        end
    end
    if o.eta then add("(ETA " .. o.eta .. "m)", P.Colours.place) end
    if o.note and o.note ~= "" then add("- " .. o.note, P.Colours.note) end
    local lock = (not brief) and LinkCall("LockText", o.zone)
    if lock and lock ~= "" then add("[" .. DisplayText(lock, 40) .. "]", P.Colours.note) end
    return table.concat(parts, " "), segs
end

-- Shows an order in the window: "prefix" in the name colour, then the coloured pieces, then what the map did.
-- One grey line under an order saying what the map did (so a missing pin is never a mystery).
function P.PinNote(note)
    local good = note and (string.find(note, "^pin placed") or string.find(note, "^arrow placed"))
    if good and not (P.Saved and P.Saved.verbose) then return end        -- success is the pin itself; say only what went wrong
    if note and note ~= "" then Comms("   map: " .. note, { { "   map: " .. note, P.Colours.note } }) end
end

-- Only speaks up when the other leaders did NOT get your message, so a silent failure is never a mystery.
function P.SendNote(delivered, why)
    P.lastSendOk, P.lastSendWhy = delivered and true or false, why
    if not delivered then
        local line = "   chat: NOT sent to the other leaders (" .. tostring(why or "unknown reason") .. ")"
        Comms(line, { { line, { 240, 110, 110 } } })
    end
end

function P.ShowOrder(prefix, o)
    local text, segs = P.DescribeOrder(o)
    local all = { { prefix, P.Colours.name } }
    for _, sg in ipairs(segs) do all[#all + 1] = sg end
    Comms(prefix .. text, all, true)
end

function P.SendOrder(verb, zone, zx, zy, eta, note)
    if not P.Verbs[verb] then Log("unknown order word: " .. tostring(verb)); return false end
    note = DisplayText(note, P.noteMax)
    if not P.Broadcast("ORD", verb, zone or "-", zx or "-", zy or "-", eta or "-", note) then return false end
    local o = { verb = verb, zone = zone, zx = zx, zy = zy, eta = eta, note = note, t = P.clock }
    P.Record(Me(), o)
    P.ShowOrder("(you) ", o)
    P.PinNote(LinkCall("OnOrder", Me(), o))
    return true
end

-- Repeats what this leader just told their own warband (via Warband Lead Helper) to the other leaders.
function P.SendWlh(tag, text, zone, zx, zy)
    local sent
    for _, max in ipairs({ P.wlhTextMax, 70, 40 }) do
        local t = DisplayText(text, max)
        if t == "" then return false end
        local payload = Build("WLH", P.seq + 1, tag or "-", zone or "-", zx or "-", zy or "-", t)
        if payload then sent = t; break end
    end
    local delivered, why
    if sent then
        delivered, why = P.Broadcast("WLH", tag or "-", zone or "-", zx or "-", zy or "-", sent)
    else
        sent, delivered, why = DisplayText(text, 40), false, "message too long"
        if sent == "" then return false end
    end
    local o = { tag = tag, text = sent, zone = zone, zx = zx, zy = zy, t = P.clock }
    P.Record(Me(), o)
    P.ShowOrder("(you, warband) ", o)
    P.PinNote(LinkCall("OnOrder", Me(), o))      -- your own pin is placed even when nobody is on your roster yet
    P.SendNote(delivered, why)
    return delivered
end

-- An attack line from (zx,zy) to (zx2,zy2) in one zone. Leaders get five pins that count as one.
function P.SendArrow(tag, text, zone, zx, zy, zx2, zy2)
    if not (zone and zx and zy and zx2 and zy2) then return false end
    local sent
    for _, max in ipairs({ P.wlhTextMax, 70, 40 }) do
        local t = DisplayText(text, max)
        if t == "" then return false end
        if Build("ARW", P.seq + 1, tag or "-", zone, zx, zy, zx2, zy2, t) then sent = t; break end
    end
    if not sent then return false end
    local delivered, why = P.Broadcast("ARW", tag or "-", zone, zx, zy, zx2, zy2, sent)
    local o = { tag = tag, text = sent, zone = zone, zx = zx, zy = zy, zx2 = zx2, zy2 = zy2, arrow = true, t = P.clock }
    P.Record(Me(), o)
    P.ShowOrder("(you, arrow) ", o)
    P.PinNote(LinkCall("OnArrow", Me(), o))
    P.SendNote(delivered, why)
    return delivered
end

function P.SendText(message)
    message = DisplayText(message, P.textMax)
    if message == "" then return false end
    if P.Broadcast("TXT", message) then
        Comms("(you) " .. message)
        return true
    end
    return false
end

function P.SendPos(auto)
    local zone, zx, zy = CurrentPos()
    if not (zone and zx and zy) then
        if not auto then Log("no map position yet. Move a few steps (needs MapMonster and map data for this zone).") end
        return false
    end
    if Count(P.roster) == 0 then return false end
    if not P.Broadcast("POS", zone, zx, zy) then return false end
    P.Positions[Me()] = { zone = zone, zx = zx, zy = zy, t = P.clock }
    LinkCall("OnPos", Me(), P.Positions[Me()])
    if not auto then Log("position sent") end
    return true
end

-- Receiving --------------------------------------------------------------------
local TYPES = { PRQ = true, ARW = true, HLO = true, HAK = true, TXT = true, ORD = true, POS = true, WLH = true, PRS = true, INT = true }

local function Flooded(sender)
    local r = P.rate[sender]
    if not r or P.clock - r.t > P.floodWindow then
        r = { t = P.clock, n = 0 }
        P.rate[sender] = r
    end
    r.n = r.n + 1
    return r.n > P.floodMax
end

-- Returns true if the line was ours (handled or deliberately dropped).
P.gateNoted = {}
function P.SenderMayCommand(sender)
    if P.Saved and P.Saved.testMode then return true end
    local t = P.seenLeading[sender]
    return t ~= nil and P.clock - t < 1500
end

function P.Parse(sender, text)
    -- Readable channel line: "<text> {pg1 TYPE SEQ fields}" is rewritten into the canonical form below.
    local human, ctype, cseq, crest = string.match(text, "^(.-)%s*{pg1 (%u+) (%d+)([^}]*)}")
    if ctype then
        if not P.ValidName(sender) then return true end
        local cf = {}
        for w in string.gmatch(crest, "%S+") do cf[#cf + 1] = w end
        human = string.gsub(human, "[|%c]", " ")
        if ctype == "WLH" and #cf >= 4 then
            text = table.concat({ P.PREFIX, "WLH", sender, cseq, cf[1], cf[2], cf[3], cf[4], human }, P.SEP)
        elseif ctype == "ARW" and #cf >= 6 then
            text = table.concat({ P.PREFIX, "ARW", sender, cseq, cf[1], cf[2], cf[3], cf[4], cf[5], cf[6], human }, P.SEP)
        elseif ctype == "POS" and #cf >= 3 then
            text = table.concat({ P.PREFIX, "POS", sender, cseq, cf[1], cf[2], cf[3] }, P.SEP)
        elseif ctype == "PRQ" then
            text = table.concat({ P.PREFIX, "PRQ", sender, cseq }, P.SEP)
        elseif ctype == "PRS" and #cf >= 1 then
            text = table.concat({ P.PREFIX, "PRS", sender, cseq, cf[1] }, P.SEP)
        else
            return true
        end
    end
    local at = string.find(text, P.PREFIX .. P.SEP, 1, true)
    if not at then return false end

    local f = Split(string.sub(text, at), P.SEP)
    local msgType, from, seq = f[2], f[3], f[4]
    if not msgType or not TYPES[msgType] or not from or not seq or not string.find(seq, "^%d+$") then
        return true
    end

    -- Echoes of our own outgoing whispers.
    if sender == "" or sender == Me() or from == Me() then return true end
    if Flooded(sender) then return true end

    local entry = P.roster[sender]
    if msgType == "PRS" then                              -- anyone's own claim of leading, kept for the /pg who list
        P.seenLeading[sender] = (f[5] == "1") and P.clock or nil
    elseif msgType == "PRQ" then                          -- "who is leading?": answer if we are
        if P.IsLeader() and P.ChannelOn() and P.clock - (P.lastPrqReply or -100) > 20 then
            P.lastPrqReply = P.clock
            P.SendPresence(1)
        end
        return true
    end
    if msgType == "HLO" then
        if entry then
            entry.t = P.clock
            P.seq = P.seq + 1
            local reply = Build("HAK", P.seq)
            if reply then QueueTell(sender, reply) end
            MarkLinked(sender, entry)
        else
            NotePending(sender)       -- never auto-added, never answered
        end
        return true
    end
    if not entry then
        if msgType ~= "HAK" then NotePending(sender) end
        return true
    end

    local key = sender .. ":" .. seq
    if P.seen[key] then return true end
    P.seen[key] = P.clock
    entry.t = P.clock
    entry.heard = P.clock                  -- really heard from them (a saved roster entry has not been)

    if entry.active == false and msgType ~= "HAK" and msgType ~= "PRS" and msgType ~= "INT" then
        entry.active, entry.pres = true, true       -- they are speaking, so they are around
        NotifyRoster()
    end

    if msgType == "HAK" then
        MarkLinked(sender, entry)

    elseif msgType == "PRS" then
        if f[5] == "1" then
            local was = entry.active
            entry.active, entry.pres = true, true
            if was ~= true then Comms(sender .. " is now leading a warband"); NotifyRoster() end
        elseif f[5] == "0" then
            entry.active, entry.pres = false, nil
            P.Board[sender] = nil
            P.Positions[sender] = nil
            LinkCall("ClearPin", sender)
            Comms(sender .. " is no longer leading a warband")
            NotifyRoster()
        end

    elseif msgType == "INT" then
        local n = 0
        for raw in string.gmatch(f[5] or "", "[^,]+") do
            n = n + 1
            if n > 4 then break end
            local name = CleanName(raw)
            if P.ValidName(name) and name ~= Me() and not P.roster[name] and not P.suggest[name]
               and not (P.dismissed[name] and P.clock - P.dismissed[name] < 1800)
               and Count(P.suggest) < P.maxSuggest then
                P.suggest[name] = { by = sender, t = P.clock }
                Comms(sender .. " also works with " .. name .. ". Click Add on the Pigeon bar, or /pg add " .. name)
                NotifyRoster()
            end
        end

    elseif msgType == "TXT" then
        local msg = DisplayText(f[5], P.textMax)
        if msg ~= "" then Comms(sender .. ": " .. msg) end

    elseif LEADER_ONLY[msgType] and not P.SenderMayCommand(sender) then
        -- Orders only count from someone who has announced that they lead a warband (their own claim, see PRS).
        -- Not heard yet? Ask the channel who is leading, so their next press goes through.
        if P.clock - (P.gateNoted[sender] or -100) > 60 then
            P.gateNoted[sender] = P.clock
            Comms(sender .. " sent an order but has not announced that they lead a warband, so it was ignored (/pg test on accepts anyone).")
        end
        if P.ChannelOn() and P.clock - (P.lastPresenceAsk or -100) > 20 then
            P.lastPresenceAsk = P.clock
            P.seq = P.seq + 1
            local line = P.ChannelLine("PRQ", P.seq)
            if line then QueueChannel(line) end
        end
        return true

    elseif msgType == "ORD" then
        local verb = f[5]
        if not verb or not P.Verbs[verb] then return true end
        local zone, b1 = Num(f[6], 1, 999)
        local zx, b2 = Num(f[7], 0, 70000)
        local zy, b3 = Num(f[8], 0, 70000)
        local eta, b4 = Num(f[9], 0, 99)
        if b1 or b2 or b3 or b4 then return true end
        if (zx == nil) ~= (zy == nil) then return true end
        if zx and not zone then return true end
        local o = { verb = verb, zone = zone, zx = zx, zy = zy, eta = eta,
                    note = DisplayText(f[10], P.noteMax), t = P.clock }
        P.Record(sender, o)
        P.ShowOrder(sender .. ": ", o)
        P.PinNote(LinkCall("OnOrder", sender, o))

    elseif msgType == "WLH" then
        local tag = f[5]
        if tag == "-" then tag = nil
        elseif not tag or not P.Tags[tag] then return true end
        local zone, b1 = Num(f[6], 1, 999)
        local zx, b2 = Num(f[7], 0, 70000)
        local zy, b3 = Num(f[8], 0, 70000)
        if b1 or b2 or b3 then return true end
        if (zx == nil) ~= (zy == nil) then return true end
        if zx and not zone then return true end
        local text = DisplayText(f[9], P.wlhTextMax)
        if text == "" then return true end
        local o = { tag = tag, text = text, zone = zone, zx = zx, zy = zy, t = P.clock }
        P.Record(sender, o)
        P.ShowOrder(sender .. " (warband): ", o)
        P.PinNote(LinkCall("OnOrder", sender, o))

    elseif msgType == "ARW" then
        local tag = f[5]
        if tag == "-" then tag = nil
        elseif not tag or not P.Tags[tag] then return true end
        local zone, b1 = Num(f[6], 1, 999)
        local x1, b2 = Num(f[7], 0, 70000)
        local y1, b3 = Num(f[8], 0, 70000)
        local x2, b4 = Num(f[9], 0, 70000)
        local y2, b5 = Num(f[10], 0, 70000)
        if b1 or b2 or b3 or b4 or b5 or not (zone and x1 and y1 and x2 and y2) then return true end
        local text = DisplayText(f[11], P.wlhTextMax)
        if text == "" then return true end
        local o = { tag = tag, text = text, zone = zone, zx = x1, zy = y1, zx2 = x2, zy2 = y2, arrow = true, t = P.clock }
        P.Record(sender, o)
        P.ShowOrder(sender .. " (arrow): ", o)
        P.PinNote(LinkCall("OnArrow", sender, o))

    elseif msgType == "POS" then
        local zone, b1 = Num(f[5], 1, 999)
        local zx, b2 = Num(f[6], 0, 70000)
        local zy, b3 = Num(f[7], 0, 70000)
        if b1 or b2 or b3 or not (zone and zx and zy) then return true end
        local old = P.Positions[sender]
        P.Positions[sender] = { zone = zone, zx = zx, zy = zy, t = P.clock }
        if not old or old.zone ~= zone then
            local place = LinkCall("PlaceText", zone, zx, zy) or ""
            Comms(sender .. " is at " .. place)
        end
        LinkCall("OnPos", sender, P.Positions[sender])
    end
    return true
end

-- Common entry for whispers and channel lines. A line that already arrived by the other route is skipped.
function P.Ingest(sender, text)
    local seq = string.match(text, P.PREFIX .. "|%a+|[^|]*|(%d+)") or string.match(text, "{pg1 %u+ (%d+)")
    if seq and P.seen[sender .. ":" .. seq] then return end
    P.Parse(sender, text)
end

local function Handle(eventName)
    if busy then return end
    busy = true
    local ok, err = pcall(function()
        local cd = GameData.ChatData
        if P.probe then
            Log("probe: event " .. eventName)
            for k, v in pairs(cd) do Log("  " .. tostring(k) .. " = " .. tostring(v)) end
        end
        P.Ingest(CleanName(cd.name), tostring(cd.text))
    end)
    busy = false
    if not ok then Log("error in handler: " .. tostring(err)) end
end

function P.OnConversation() Handle("conversation") end

-- Lines from chat channels (and anything else that is not a whisper). Only lines carrying our tag are looked at.
function P.OnChat()
    if busy then return end
    busy = true
    local ok, err = pcall(function()
        local cd = GameData.ChatData
        local text = tostring(cd.text)
        if P.who and P.clock <= P.who.untilT and not string.find(text, "{pg1 ", 1, true)
           and not string.find(text, P.PREFIX .. P.SEP, 1, true) then
            P.WhoLine(text, CleanName(cd.name), cd.type)
        end
        if not (string.find(text, P.PREFIX .. P.SEP, 1, true) or string.find(text, "{pg1 ", 1, true)) then return end
        if P.probe then
            Log("probe: channel line, chat type " .. tostring(cd.type) .. ", from " .. tostring(cd.name))
        end
        if CleanName(cd.name) == Me() and P.ChannelOn() then P.chanOk = true end
        P.Ingest(CleanName(cd.name), text)
    end)
    busy = false
    if not ok then Log("error in channel handler: " .. tostring(err)) end
end


-- Channel scan: /channelwho + a "who is leading?" request --------------------------------------
-- Green = on your roster, yellow = says it is leading a warband and waits for your Add (also on the bar),
-- grey = in the channel but has not said it leads a warband. Leadership is the player's own claim:
-- the game does not let anyone see whether a player in ANOTHER warband leads it.
local STOP = { channel = 1, channels = 1, members = 1, member = 1, ["in"] = 1, the = 1, online = 1, you = 1, are = 1,
               players = 1, player = 1, who = 1, joined = 1, list = 1, of = 1, ["and"] = 1, is = 1, total = 1,
               users = 1, user = 1, command = 1, currently = 1, there = 1, ["for"] = 1, has = 1, have = 1 }

function P.WhoLine(text, speaker, ctype)
    local w = P.who
    if not w or (speaker ~= "" and speaker ~= nil) then return end        -- system output has no speaker
    local plain = string.gsub(tostring(text), "<[^>]*>", " ")
    w.raw[#w.raw + 1] = string.sub(plain, 1, 120)
    for tok in string.gmatch(plain, "[%a\128-\255][%w'\128-\255%-]+") do
        local len = string.len(tok)
        if len >= 3 and len <= 16 and string.find(tok, "^[%u\128-\255]") and not STOP[string.lower(tok)] then
            tok = CleanName(tok)
            if tok ~= Me() and not w.names[tok] and Count(w.names) < 60 then w.names[tok] = true end
        end
    end
end

function P.WhoScan(quiet)
    if not P.ChannelOn() then if not quiet then Log("channel mode is off (/pg channel /9)") end; return end
    P.who = { start = P.clock, untilT = P.clock + 14, raw = {}, names = {}, quiet = quiet }
    table.insert(P.queue, "/channelwho")
    P.seq = P.seq + 1
    local line = P.ChannelLine("PRQ", P.seq)
    if line then QueueChannel(line) end
    if P.IsLeader() then P.SendPresence(1) end
    if not quiet then Log("asking the channel who is here and who is leading...") end
end

function P.WhoFinish()
    local w = P.who
    P.who = nil
    if not w then return end
    local GREEN, YEL, GREY = { 110, 220, 120 }, { 255, 225, 120 }, { 150, 150, 150 }
    local all = {}
    for name in pairs(w.names) do all[name] = true end
    for name, t in pairs(P.seenLeading) do if t >= w.start - 1 and name ~= Me() then all[name] = true end end
    local names = {}
    for name in pairs(all) do names[#names + 1] = name end
    table.sort(names)
    local segs, plain = { { "Channel: ", P.Colours.name } }, {}
    local added = 0
    for _, name in ipairs(names) do
        local colour, tag
        if P.roster[name] then colour, tag = GREEN, ""
        elseif P.seenLeading[name] and P.clock - P.seenLeading[name] < 1500 then
            colour, tag = YEL, " (leading)"
            if not P.pending[name] and not P.suggest[name]
               and not (P.dismissed[name] and P.clock - P.dismissed[name] < 1800) then
                local why = P.AutoAcceptReason(name)
                if why then
                    if P.AddLeader(name, true) then colour, tag = GREEN, "" end
                else
                    P.suggest[name] = { by = "the channel", t = P.clock }; added = added + 1
                end
            end
        else colour, tag = GREY, "" end
        segs[#segs + 1] = { name .. tag .. "  ", colour }
        plain[#plain + 1] = name .. tag
    end
    if #names == 0 then
        if not w.quiet then
            Log("channel scan: nothing readable came back" .. (#w.raw > 0 and (" (it said: " .. w.raw[1] .. ")") or "") ..
                ". Try /channelwho yourself and tell me what it prints.")
        end
        return
    end
    Comms("Channel: " .. table.concat(plain, ", "), segs)
    if not w.quiet then
        Comms("   green = on your roster, yellow = leading and waiting for you (yellow bar buttons), grey = here but not announced as leading",
              { { "   green = on your roster, yellow = leading and waiting for you, grey = in the channel, not announced as leading", P.Colours.note } })
        if #w.raw > 0 then Log("channelwho said: " .. w.raw[1]) end
    end
    if added > 0 then NotifyRoster() end
end

-- Display ----------------------------------------------------------------------
function P.ShowBoard()
    local n = 0
    for name, o in pairs(P.Board) do
        n = n + 1
        Log(name .. ": " .. P.DescribeOrder(o) .. " (" .. math.floor(P.clock - o.t) .. "s ago)")
    end
    if n == 0 then Log("board empty") end
end

function P.ShowVerbs()
    local names = {}
    for k in pairs(P.Verbs) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
        Log("  " .. k .. "  =  " .. P.Verbs[k].text .. "  [" .. P.Verbs[k].tag .. "]")
    end
end

-- Offline self test: nothing is sent, nothing is saved. Returns pass, fail.
function P.Selftest()
    local pass, fail = 0, 0
    local function check(name, cond)
        if cond then pass = pass + 1 else fail = fail + 1; Log("FAIL: " .. name) end
    end
    local savedQueue, savedMirror = P.queue, P.mirrorToChat
    local savedSaved = P.Saved
    P.queue = {}
    P.Saved = { roster = {}, pins = false }
    P.mirrorToChat = false

    local savedSeen = P.seenLeading
    P.seenLeading = { TestA = P.clock, TestB = P.clock, ChanA = P.clock }   -- the test senders have announced they are leading
    P.AddLeader("TestA", true)
    P.AddLeader("TestB", true)
    check("roster has 2", Count(P.roster) == 2)
    check("add queues a hello", #P.queue == 2)

    local ord = P.PREFIX .. "|ORD|TestA|1|attack|106|20000|15000|5|east gate"
    check("valid order accepted", P.Parse("TestA", ord) == true and P.Board["TestA"] ~= nil)
    check("order fields", P.Board["TestA"] and P.Board["TestA"].eta == 5 and P.Board["TestA"].zx == 20000)
    P.Board["TestA"] = nil
    P.Parse("TestA", ord)
    check("duplicate dropped", P.Board["TestA"] == nil)

    P.Parse("TestA", P.PREFIX .. "|ORD|TestA|2|selfdestruct|106|1|1|5|x")
    check("unknown order word dropped", P.Board["TestA"] == nil)
    P.Parse("TestA", P.PREFIX .. "|ORD|TestA|3|attack|99999|1|1|5|x")
    check("zone out of range dropped", P.Board["TestA"] == nil)
    P.Parse("TestA", P.PREFIX .. "|ORD|TestA|4|attack|106|abc|1|5|x")
    check("non-numeric coordinate dropped", P.Board["TestA"] == nil)
    P.Parse("TestA", P.PREFIX .. "|ORD|TestA|5|attack|106|100|-|5|x")
    check("half a coordinate dropped", P.Board["TestA"] == nil)
    P.Parse("TestA", P.PREFIX .. "|ORD|TestA|6|attack|-|-|-|-|zone-less ok")
    check("zone-less order accepted", P.Board["TestA"] ~= nil)

    local before = #P.history
    P.Parse("TestB", P.PREFIX .. "|TXT|TestB|1|hello <LINK data=1 text=x> there")
    check("text shown", #P.history == before + 1)
    check("markup stripped", not string.find(P.history[#P.history], "<", 1, true))

    before = #P.history
    P.Parse("Stranger", P.PREFIX .. "|TXT|Stranger|1|let me in")
    P.Parse("Stranger", P.PREFIX .. "|ORD|Stranger|2|attack|106|1|1|5|x")
    check("stranger ignored", #P.history == before and P.Board["Stranger"] == nil)
    check("stranger becomes pending, not roster", P.pending["Stranger"] ~= nil and P.roster["Stranger"] == nil)
    local q = #P.queue
    P.Parse("Stranger", P.PREFIX .. "|HLO|Stranger|3")
    check("stranger hello gets no reply", #P.queue == q and P.roster["Stranger"] == nil)
    P.Parse("TestB", P.PREFIX .. "|HLO|TestB|9")
    check("roster hello gets a reply", #P.queue == q + 1)

    P.Parse(Me(), P.PREFIX .. "|TXT|" .. Me() .. "|1|echo")
    check("own echo ignored", true)
    check("normal chat is not ours", P.Parse("Someone", "just chatting") == false)

    local base = #P.history
    for i = 1, 40 do P.Parse("TestB", P.PREFIX .. "|TXT|TestB|" .. (100 + i) .. "|spam " .. i) end
    check("flood limited", #P.history - base <= P.floodMax)

    -- what a leader told their warband through Warband Lead Helper
    P.Board["TestA"] = nil
    P.Parse("TestA", P.PREFIX .. "|WLH|TestA|20|AT|106|20000|15000|Attack now! <b>go</b>")
    check("wlh message accepted", P.Board["TestA"] ~= nil and P.Board["TestA"].tag == "AT")
    check("wlh markup stripped", P.Board["TestA"] and not string.find(P.Board["TestA"].text, "<", 1, true))
    P.Board["TestA"] = nil
    P.Parse("TestA", P.PREFIX .. "|WLH|TestA|21|ZZ|106|1|1|bad tag")
    check("wlh unknown tag dropped", P.Board["TestA"] == nil)
    P.Parse("TestA", P.PREFIX .. "|WLH|TestA|22|-|-|-|-|Check your buffs")
    check("untagged, positionless wlh message accepted", P.Board["TestA"] and P.Board["TestA"].tag == nil)
    P.Parse("TestA", P.PREFIX .. "|WLH|TestA|23|AT|106|9|-|half a coordinate")
    check("wlh half coordinate: old entry kept", P.Board["TestA"] and P.Board["TestA"].text == "Check your buffs")

    -- presence: stepping down, coming back, expiry
    P.rate, P.seen = {}, {}
    P.queue = {}
    P.Parse("TestA", P.PREFIX .. "|PRS|TestA|60|0")
    check("presence 0 marks inactive", P.roster["TestA"].active == false)
    P.Broadcast("TXT", "hello")
    check("broadcast skips inactive leader", #P.queue == 1 and string.find(P.queue[1], "TestB", 1, true))
    P.Parse("TestA", P.PREFIX .. "|PRS|TestA|61|1")
    check("presence 1 marks active", P.roster["TestA"].active == true)
    P.Parse("TestA", P.PREFIX .. "|PRS|TestA|62|0")
    P.Parse("TestA", P.PREFIX .. "|TXT|TestA|63|I am back")
    check("speaking reactivates", P.roster["TestA"].active == true)
    P.Parse("Stranger2", P.PREFIX .. "|PRS|Stranger2|64|1")
    check("stranger presence ignored", P.roster["Stranger2"] == nil)

    -- introductions need approval
    P.Parse("TestB", P.PREFIX .. "|INT|TestB|70|Newbie,Bad Name,TestA," .. Me() .. ",Other,Third,Fourth,Fifth")
    check("introduced name suggested", P.suggest["Newbie"] ~= nil and P.roster["Newbie"] == nil)
    check("invalid, known and own names skipped", P.suggest["Bad"] == nil and P.suggest["TestA"] == nil and P.suggest[Me()] == nil)
    check("at most 4 names per introduction", P.suggest["Fifth"] == nil)
    P.AddSuggested()
    check("addall links suggestions", P.roster["Newbie"] ~= nil)

    -- mutual link triggers an introduction of already linked leaders
    P.roster["TestA"].linked = true
    P.queue = {}
    P.roster["TestB"].linked = nil
    P.Parse("TestB", P.PREFIX .. "|HLO|TestB|71")
    local intro = 0
    for _, line in ipairs(P.queue) do if string.find(line, "|INT|", 1, true) then intro = intro + 1 end end
    check("link sends introduction", intro >= 1)

    -- automatic linking of friends / guildmates
    local savedSources = P.Sources
    P.Sources = {
        friends = function() return { { name = "PalFriend" }, { name = "Online", zone = 106 }, { name = "Offline", zone = 0 } } end,
        guild = function() return { { name = "GuildPal", zone = 5 }, { name = "GuildAway", zone = 0 }, { name = "GuildUnknown" } } end,
    }
    P.Saved.accept = "off"
    P.Parse("PalFriend", P.PREFIX .. "|HLO|PalFriend|80")
    check("accept off: friend only pending", P.roster["PalFriend"] == nil and P.pending["PalFriend"] ~= nil)
    P.pending = {}
    P.Saved.accept = "friends"
    P.Parse("PalFriend", P.PREFIX .. "|HLO|PalFriend|81")
    check("accept friends: friend linked", P.roster["PalFriend"] ~= nil)
    P.Parse("GuildPal", P.PREFIX .. "|HLO|GuildPal|82")
    check("accept friends: guildmate still pending", P.roster["GuildPal"] == nil and P.pending["GuildPal"] ~= nil)
    P.Saved.accept = "known"
    P.Parse("GuildPal", P.PREFIX .. "|HLO|GuildPal|83")
    check("accept known: guildmate linked", P.roster["GuildPal"] ~= nil)
    P.Parse("Nobody", P.PREFIX .. "|HLO|Nobody|84")
    check("accept known: stranger still pending", P.roster["Nobody"] == nil and P.pending["Nobody"] ~= nil)
    P.RemoveLeader("PalFriend"); P.RemoveLeader("GuildPal")

    -- discovery: online friends and guildmates only
    P.queue, P.helloed, P.pending = {}, {}, {}
    local sentHellos = P.Discover(true)
    check("discovery skips offline and unknown-guild entries", sentHellos == 3)   -- PalFriend (zone unknown), Online, GuildPal (online)
    check("discovery says each name once", P.Discover(true) == 0)
    P.Sources = savedSources

    -- presence announcements follow leadership
    local savedIsLeader, savedLeading = P.IsLeader, P.leading
    P.Saved.presence = true
    P.leading = nil
    P.queue = {}
    P.IsLeader = function() return true end
    P.PresenceTick()
    local prs1 = 0
    for _, line in ipairs(P.queue) do if string.find(line, "|PRS|", 1, true) and string.find(line, "|1", 1, true) then prs1 = prs1 + 1 end end
    check("becoming leader announces to every roster member", prs1 == Count(P.roster))
    P.queue = {}
    P.PresenceTick()
    check("no repeat before the heartbeat", #P.queue == 0)
    P.clock = P.clock + P.presenceBeat + 1
    P.PresenceTick()
    check("heartbeat while leading", #P.queue > 0)
    P.IsLeader = function() return false end
    P.queue = {}
    P.PresenceTick()
    local prs0 = 0
    for _, line in ipairs(P.queue) do if string.find(line, "|PRS|", 1, true) then prs0 = prs0 + 1 end end
    check("stepping down announces", prs0 > 0 and P.leading == false)
    P.IsLeader, P.leading = savedIsLeader, savedLeading

    -- waiting list, dismiss, add target (what the bar buttons call)
    P.pending, P.suggest, P.dismissed = {}, {}, {}
    P.Parse("Zed", P.PREFIX .. "|HLO|Zed|90")
    P.Parse("TestB", P.PREFIX .. "|INT|TestB|91|Yan")
    local w = P.Waiting()
    check("waiting lists stranger then suggestion", #w == 2 and w[1].name == "Zed" and w[2].name == "Yan")
    P.Dismiss("Zed")
    check("dismiss removes from waiting", #P.Waiting() == 1)
    P.Parse("Zed", P.PREFIX .. "|HLO|Zed|92")
    check("dismissed name not offered again", P.pending["Zed"] == nil)
    P.AddLeader("Yan", true)
    check("adding clears waiting entry", #P.Waiting() == 0 and P.roster["Yan"] ~= nil)
    local savedTarget = P.TargetName
    P.TargetName = function() return "Tgt" end
    P.AddTarget()
    check("add target links targeted player", P.roster["Tgt"] ~= nil)
    P.TargetName = function() return nil end
    check("add target with nothing targeted does nothing", P.AddTarget() == false)
    P.TargetName = savedTarget
    P.RemoveLeader("Yan"); P.RemoveLeader("Tgt")

    -- channel transport
    P.rate, P.seen, P.pending = {}, {}, {}
    P.Saved.channel = "/pigeondata"
    P.AddLeader("ChanA", true)
    check("channel mode: add sends no whisper", #P.queue == 0 or not string.find(P.queue[#P.queue], "/w ChanA", 1, true))
    P.queue = {}
    P.Broadcast("TXT", "hi all")
    check("channel text is plain talk", #P.queue == 1 and P.queue[1] == "/pigeondata hi all")
    P.queue = {}
    P.SendPresence(1)
    check("channel presence is one readable line", #P.queue == 1 and string.find(P.queue[1], "^/pigeondata is leading a warband {pg1 PRS %d+ 1}$"))
    P.Parse("ChanStranger", P.PREFIX .. "|PRS|ChanStranger|200|1")
    check("channel stranger offered, not trusted", P.pending["ChanStranger"] ~= nil and P.roster["ChanStranger"] == nil)
    P.Board = {}
    P.Parse("ChanA", P.PREFIX .. "|WLH|ChanA|201|AT|106|1|1|via channel")
    check("trusted leader's channel order accepted", P.Board["ChanA"] ~= nil)
    -- readable lines: what one leader says is decoded by another
    P.queue = {}
    P.SendWlh("BO", "Take the <b>BO</b> | now {x}", 106, 35100, 9900)
    local line = string.gsub(P.queue[1] or "", "^/pigeondata ", "")
    check("wlh line reads as plain text", string.find(line, "^Take the bBO/b now x {pg1 WLH %d+ BO 106 35100 9900}$") ~= nil)
    check("wlh line has no raw separators", not string.find(line, "|", 1, true) and not string.find(line, "<", 1, true))
    P.Board = {}
    P.Parse("ChanA", line)
    check("readable wlh line decodes", P.Board["ChanA"] and P.Board["ChanA"].tag == "BO" and P.Board["ChanA"].zx == 35100)
    P.queue = {}
    P.SendOrder("attack", 106, 20000, 15000, 5, "east gate")
    line = string.gsub(P.queue[1] or "", "^/pigeondata ", "")
    check("typed order reads as plain text", string.find(line, "^ATTACK ETA 5m %- east gate {pg1 WLH") ~= nil)
    P.Board = {}
    P.Parse("ChanA", line)
    check("typed order decodes with tag and place", P.Board["ChanA"] and P.Board["ChanA"].tag == "AT" and P.Board["ChanA"].zx == 20000)
    P.queue = {}
    P.SendPos(false)
    line = string.gsub(P.queue[1] or "", "^/pigeondata ", "")
    check("position line decodes", string.find(line, "{pg1 POS") ~= nil)
    P.roster["ChanA"].active = nil
    P.Parse("ChanA", "stepped down as warband leader {pg1 PRS 9001 0}")
    check("readable presence decodes", P.roster["ChanA"].active == false)
    P.Parse("ChanA", "is leading a warband {pg1 PRS 9002 1}")
    check("readable presence back", P.roster["ChanA"].active == true)
    P.Board = {}
    P.Parse("ChanA", "rubbish {pg1 WLH 9003 ZZ 106 1 1}")
    P.Parse("ChanA", "rubbish {pg1 WLH 9004 AT 106 5}")
    P.Parse("ChanA", "rubbish {pg1 XXX 9005 1}")
    check("bad tag, short tail, unknown type dropped", P.Board["ChanA"] == nil)
    P.Parse("ChanStranger", "Take the keep {pg1 WLH 9006 AT 106 1 1}")
    check("stranger's readable line only offered", P.Board["ChanStranger"] == nil and P.pending["ChanStranger"] ~= nil)
    P.Saved.channel = "/bad channel"
    check("bad channel command rejected", P.ChannelOn() == false)
    P.Saved.channel = nil
    P.RemoveLeader("ChanA")
    P.pending = {}

    P.RemoveLeader("TestA")
    P.RemoveLeader("TestB")
    P.RemoveLeader("Newbie")
    P.suggest, P.helloed, P.dismissed = {}, {}, {}
    P.pending = {}
    P.rate = {}
    P.seen = {}
    P.Board = {}
    P.queue = savedQueue
    P.seenLeading = savedSeen
    P.Saved = savedSaved
    P.mirrorToChat = savedMirror
    Log("self test: " .. pass .. " passed, " .. fail .. " failed")
    return pass, fail
end

-- One report to paste when something does not work.
function P.Debug()
    local LK = P.Links or {}
    Log("--- Pigeon debug v" .. P.VERSION .. " ---")
    Log("channel: " .. (P.ChannelOn() and P.Saved.channel or "off (whispers)") ..
        ", own line seen coming back: " .. tostring(P.chanOk == true) ..
        ", joined flag: " .. tostring(P.Saved and P.Saved.joined))
    Log("queue: " .. #P.queue .. " waiting, loading screen: " .. tostring(P.loading) .. ", dry run: " .. tostring(P.dryRun) ..
        ", send gap " .. P.sendInterval .. "s")
    Log("last line sent: " .. (P.lastSentLine and ("[" .. math.floor(P.clock - P.lastSentAt) .. "s ago] " .. P.lastSentLine) or "nothing yet"))
    Log("trusted leaders: " .. Count(P.roster) .. ", waiting to link: " .. #P.Waiting())
    Log("WLH hook: wlh " .. tostring(wbLeadHelper ~= nil and wbLeadHelper.chat ~= nil) .. ", hooked " .. tostring(LK.hooked) ..
        ", parrot " .. tostring(LK.parrot))
    if LK.trace and #LK.trace > 0 then
        Log("what the WLH hook saw (newest last):")
        for _, t in ipairs(LK.trace) do Log("   " .. t) end
    else
        Log("the WLH hook has not seen any message yet (press a WLH button, then /pg debug again)")
    end
    local zone = LK.PlayerPosition and select(1, LK.PlayerPosition())
    Log("zone: " .. tostring(zone) .. ", WARCommander loaded: " .. tostring(PointsOfInterest ~= nil) .. ", named places here: " .. (LK.PlaceList and #LK.PlaceList(zone) or 0) ..
        ", MapMonster pins ready: " .. tostring(LK.pinsReady) .. ", pins on: " .. tostring(LK.pinsEnabled))
    Log("last pin result: " .. tostring(LK.lastPin))
end

-- Slash commands ---------------------------------------------------------------
local function Help()
    Log("/pg add Name | addtarget | remove Name | roster | pending | suggest | addall | hello")
    Log("/pg channel [on|off|/command]   Pigeon talks in the shared channel "..P.CHANNEL_NAME.." (" .. P.CHANNEL_CMD .. ") by default; off = whispers (now: " .. tostring(P.Saved and P.Saved.channel or "whispers") .. ")")
    Log("/pg presence on|off   announce when you start/stop leading a warband")
    Log("/pg accept off|friends|guild|known   auto-link people from your friends list / guild who use Pigeon (now: " .. tostring(P.Saved and P.Saved.accept) .. ")")
    Log("/pg discover [on|off|fields]   say hello to online friends/guildmates (fields = show what the lists contain)")
    Log("/pg say text...    send to every leader on your roster")
    Log("/pg order <word> [at <place>] [5m] [; note]    e.g. /pg order attack at Kazad Dammaz 5m east gate")
    Log("/pg verbs | board | pos | track on|off | places | zone")
    Log("/pg parrot on|off|party   repeat what you tell your warband through Warband Lead Helper to the other leaders (party = also /p)")
    Log("/pg colour on|off   coloured text in the Pigeon window")
    Log("/pg relay [name]    repeat that leader's order to YOUR warband (with the WLH voice tag)")
    Log("/pg debug   one report to paste when something does not work")
    Log("/pg pins on|off | status | rate <sec> | dry on|off | probe on|off | test")
    Log("/pgwin shows or hides the Pigeon window (it also accepts /order ...).")
end

local function OrderCmd(rest)
    local words = {}
    for w in string.gmatch(rest, "%S+") do words[#words + 1] = w end
    local verb = string.lower(words[1] or "")
    if not P.Verbs[verb] then
        Log("usage: /pg order <word> [at <place>] [5m] [; note]   (/pg verbs lists the words)")
        return
    end

    local zone, zx, zy = CurrentPos()
    if not zone then pcall(function() zone = tonumber(GameData.Player.zone) end) end
    local i, eta = 2, nil
    local placeWords, noteWords = {}, {}

    if words[2] and string.lower(words[2]) == "at" then
        i = 3
        while words[i] and words[i] ~= ";" and not string.find(words[i], "^%d+m$") do
            placeWords[#placeWords + 1] = words[i]
            i = i + 1
        end
        if #placeWords == 0 then Log("say where: /pg order " .. verb .. " at <place name>"); return end
        local LK = P.Links
        if not (LK and LK.FindPlace) then Log("place names need WARCommander installed"); return end
        local ok, px, py, pname = pcall(LK.FindPlace, zone, table.concat(placeWords, " "))
        if not ok or not px then
            Log("place not found: " .. table.concat(placeWords, " ") .. " (" .. tostring(ok and py or px) .. ")  Try /pg places")
            return
        end
        zx, zy = px, py
    end

    while words[i] do
        local w = words[i]
        if w == ";" and #noteWords == 0 then
            -- separator only
        elseif not eta and string.find(w, "^%d+m$") and #noteWords == 0 then
            eta = tonumber(string.sub(w, 1, -2))
            if eta > 99 then eta = 99 end
        else
            noteWords[#noteWords + 1] = w
        end
        i = i + 1
    end
    P.SendOrder(verb, zone, zx, zy, eta, table.concat(noteWords, " "))
end

function P.SlashCmd(args)
    args = tostring(args or "")
    local cmd, rest = string.match(args, "^(%S*)%s*(.*)$")
    cmd = string.lower(cmd or "")

    if cmd == "add" then P.AddLeader(rest)
    elseif cmd == "remove" then P.RemoveLeader(rest)
    elseif cmd == "suggest" then
        local n = 0
        for name, sg in pairs(P.suggest) do n = n + 1; Log(name .. " (via " .. sg.by .. ")  /pg add " .. name) end
        if n == 0 then Log("no suggestions") end
    elseif cmd == "addall" then P.AddSuggested()
    elseif cmd == "channel" then
        local c = string.lower(rest)
        if c == "" then
            Log("channel: " .. (P.ChannelOn() and (P.Saved.channel .. (P.chanOk and " (own lines seen, working)" or " (no echo seen yet)")) or "off, using whispers"))
        elseif c == "off" then
            P.Saved.channel, P.Saved.channelOff = nil, true
            Log("channel off, using whispers (/pg channel on to turn it back on)")
        elseif c == "on" or c == "join" then
            P.Saved.channel, P.Saved.channelOff, P.Saved.joined = P.CHANNEL_CMD, nil, nil
            P.chanOk, P.chanWarned, P.chanSentAt = nil, nil, nil
            Log("channel on: " .. P.CHANNEL_CMD)
        elseif string.find(c, "^/[1-9]$") then
            P.Saved.channel, P.Saved.channelOff = c, nil
            P.chanOk, P.chanWarned, P.chanSentAt = nil, nil, nil
            Log("Pigeon messages now go to " .. c .. ". Everyone must join that channel and use the same slot.")
        elseif string.find(c, "^/") then
            Log("only the numbered chat slots /1 to /9 can be used (anything else would run as a game command or talk in say/guild)")
        else
            Log("usage: /pg channel [on|off|/1../9]")
        end
    elseif cmd == "presence" then
        local on = (rest ~= "off")
        if P.Saved then P.Saved.presence = on end
        P.leading = nil
        Log("leader presence announcements " .. (on and "ON" or "off") .. " (leading now: " .. tostring(P.IsLeader()) .. ")")
    elseif cmd == "accept" then
        local m = string.lower(rest)
        if m == "off" or m == "friends" or m == "guild" or m == "known" or m == "leaders" then
            if P.Saved then P.Saved.accept = m end
            Log("auto-link from: " .. m)
        else
            Log("usage: /pg accept off|friends|guild|known|leaders   (leaders = anyone in the channel who announces it leads a warband; convenient, but anyone can claim that)   (now " .. tostring(P.Saved and P.Saved.accept) .. ")")
        end
    elseif cmd == "discover" then
        local arg = string.lower(rest)
        if arg == "on" or arg == "off" then
            if P.Saved then P.Saved.discover = (arg == "on") end
            Log("discovery hellos " .. arg)
        elseif arg == "fields" then
            for _, src in ipairs({ "friends", "guild" }) do
                local ok, data = pcall(function()
                    if src == "friends" then return GetFriendsList() else return GetGuildMemberData() end
                end)
                local first = ok and type(data) == "table" and select(2, next(data))
                if type(first) == "table" then
                    Log(src .. ": fields of first entry:")
                    for k, v in pairs(first) do Log("   " .. tostring(k) .. " = " .. tostring(v)) end
                else
                    Log(src .. ": nothing returned (" .. tostring(ok and "empty list" or data) .. ")")
                end
            end
        else
            P.Discover(true)
        end
    elseif cmd == "roster" then P.ShowRoster()
    elseif cmd == "pending" then P.ShowPending()
    elseif cmd == "hello" then
        for name in pairs(P.roster) do P.SendHello(name) end
        Log("hello sent to " .. Count(P.roster) .. " leader(s)")
    elseif cmd == "say" then P.SendText(rest)
    elseif cmd == "order" then OrderCmd(rest)
    elseif cmd == "verbs" then P.ShowVerbs()
    elseif cmd == "board" then P.ShowBoard()
    elseif cmd == "pos" then P.SendPos(false)
    elseif cmd == "icons" then
        local m = string.lower(rest)
        if m == "classic" or m == "varied" then
            if P.Saved then P.Saved.icons = m end
            if P.Links then P.Links.InitPins() end
            Log("pin icons: " .. m .. " (existing Pigeon pins were cleared)")
        else
            Log("usage: /pg icons varied|classic   (varied = sword / shield / flag per order type, now " .. tostring(P.Saved and P.Saved.icons or "varied") .. ")")
        end
    elseif cmd == "flash" then
        local on = (rest ~= "off")
        if P.Saved then P.Saved.flash = on end
        Log("new orders flash on the map when it is open: " .. (on and "ON" or "off"))
    elseif cmd == "verbose" then
        local on = (rest ~= "off")
        if P.Saved then P.Saved.verbose = on end
        Log("map notes for every order: " .. (on and "ON" or "off (only problems are shown)"))
    elseif cmd == "who" then P.lastWho = P.clock; P.WhoScan(false)
    elseif cmd == "autowho" then
        local on = (rest ~= "off")
        if P.Saved then P.Saved.autowho = on end
        Log("automatic channel scan every 15 minutes while you lead: " .. (on and "ON" or "off"))
    elseif cmd == "shift" then
        -- /pg shift X Y   this zone only (offsets differ between zones)   /pg shift all X Y   every zone without its own
        -- /pg shift reset   forget this zone's   /pg shift reset all   forget all (back to the default)   /pg shift off
        local zone = P.Links and select(1, P.Links.PlayerPosition())
        local word = string.lower(tostring(rest or ""))
        P.Saved.zoneShift = P.Saved.zoneShift or {}
        local all1, all2 = string.match(word, "^all%s+(%-?%d+)%s+(%-?%d+)$")
        local a1, a2 = string.match(word, "^(%-?%d+)%s+(%-?%d+)$")
        if all1 then P.Saved.posShift = { tonumber(all1), tonumber(all2) }
        elseif a1 and zone then P.Saved.zoneShift[zone] = { tonumber(a1), tonumber(a2) }
        elseif word == "reset all" then P.Saved.posShift = nil; P.Saved.zoneShift = {}
        elseif word == "reset" and zone then P.Saved.zoneShift[zone] = nil
        elseif word == "off" and zone then P.Saved.zoneShift[zone] = { 0, 0 } end
        local sh = P.Links.GlobalShift(zone)
        local g = P.Links.GlobalShift(nil)
        Log("position shift here (zone " .. tostring(zone) .. "): " .. sh[1] .. "," .. sh[2] .. "; other zones: " .. g[1] .. "," .. g[2] ..
            "   (/pg shift X Y = this zone, /pg shift all X Y = other zones, /pg shift reset [all], /pg shift off)")
    elseif cmd == "fixes" then
        local n = 0
        for z, f in pairs(P.Saved.zoneFix or {}) do n = n + 1; Log("zone " .. z .. ": calibrated by right-click, map starts at world " .. f[1] .. "," .. f[2]) end
        for z, f in pairs(P.Saved.zoneShift or {}) do n = n + 1; Log("zone " .. z .. ": shift " .. f[1] .. "," .. f[2]) end
        local g = P.Links.GlobalShift(nil)
        Log((n == 0 and "no per-zone settings. " or "") .. "default shift for other zones: " .. g[1] .. "," .. g[2])
    elseif cmd == "where" then
        local gz = GameData and GameData.Player and GameData.Player.zone
        if P.Links and P.Links.zoneMismatch then Log("MapMonster was stuck on zone " .. tostring(P.Links.zoneMismatch.mm) .. " while you are in zone " .. tostring(P.Links.zoneMismatch.game) .. " - repaired; move a few steps") end
        if P.Links and (P.Links.zoneRepairs or 0) > 0 then Log("MapMonster zone-change errors repaired this session: " .. P.Links.zoneRepairs) end
        local pos
        if MapMonsterAPI and MapMonsterAPI.GetPlayerPosition then
            local okp, res = pcall(MapMonsterAPI.GetPlayerPosition)
            if okp then pos = res else Log("MapMonster itself fails here (" .. tostring(res) .. ") - it has no usable map data for zone " .. tostring(gz)) end
        end
        if type(pos) ~= "table" then
            Log("MapMonster has no player position (" .. tostring(pos) .. ")")
            local okz, zd = false, nil
            if MapMonsterAPI and MapMonsterAPI.GetZoneData then okz, zd = pcall(MapMonsterAPI.GetZoneData, tonumber(gz)) end
            Log("MapMonster zone data for " .. tostring(gz) .. ": " .. ((okz and type(zd) == "table") and ("offset " .. tostring(zd.offsetX) .. "," .. tostring(zd.offsetY) .. (zd.badZone and " (flagged badZone)" or "")) or "none"))
            return
        end
        Log("game zone " .. tostring(gz) .. ", MapMonster zone " .. tostring(pos.zoneId) ..
            ", world " .. tostring(pos.worldX) .. "," .. tostring(pos.worldY) ..
            ", zone coords " .. tostring(pos.zoneX) .. "," .. tostring(pos.zoneY))
        do
            local z0, rx, ry = P.Links.RawPlayerPosition()
            local z1, sx, sy = P.Links.PlayerPosition()
            Log("MapMonster raw zone coords " .. tostring(rx) .. "," .. tostring(ry) .. "  ->  Pigeon uses " .. tostring(sx) .. "," .. tostring(sy))
            local notes = {}
            if P.Links.ownCalc then notes[#notes + 1] = "position worked out by Pigeon from MapMonster's zone offsets (MapMonster had none)" end
            if P.Links.usingLastPos then notes[#notes + 1] = "REMEMBERED position (MapMonster knows nothing yet: take a few steps)" end
            local zf = P.Saved.zoneFix and P.Saved.zoneFix[z0]
            if zf then notes[#notes + 1] = "calibrated by right-click (" .. zf[1] .. "," .. zf[2] .. ")" end
            local zs = P.Saved.zoneShift and P.Saved.zoneShift[z0]
            if zs then notes[#notes + 1] = "zone shift " .. zs[1] .. "," .. zs[2] end
            if not zf and not zs then
                local g = P.Links.GlobalShift(z0)
                notes[#notes + 1] = (P.Links.ZONE_SHIFT[z0] and "built-in zone shift " or "default shift ") .. g[1] .. "," .. g[2]
            end
            Log("applied: " .. table.concat(notes, "; "))
        end
        Log("Pigeon would send: " .. tostring(P.Links and P.Links.PlaceText and P.Links.PlaceText(P.Links.PlayerPosition()) or "?"))
        Log("Stand still, type /mm new, and compare MapMonster's pin with the Pigeon pin on the map")
    elseif cmd == "pinsize" then
        local n = tonumber(rest)
        if not n or n < 0.3 or n > 5 then Log("pin size now " .. tostring(P.Links and P.Links.pinScale) .. ". Use /pg pinsize 1.75 (0.875 is the normal MapMonster size)")
        elseif P.Links then
            P.Links.pinScale = n
            if P.Saved then P.Saved.pinScale = n end
            P.Links.InitPins()
            Log("pin size set to " .. n .. " (existing Pigeon pins were cleared)")
        end
    elseif cmd == "test" then
        local on = string.lower(tostring(rest or ""))
        if on == "on" or on == "off" then P.Saved.testMode = (on == "on") end
        Log("test mode " .. ((P.Saved and P.Saved.testMode) and "ON: you can send orders without leading a warband" or "off: only a warband leader can send orders") .. "  (/pg test on|off)")
    elseif cmd == "arrowsize" then
        local n = tonumber(rest)
        if not n or n < 0.3 or n > 5 then Log("arrow pin size now " .. tostring(P.Links and P.Links.arrowScale) .. ". Use /pg arrowsize 0.875 (normal) or bigger")
        elseif P.Links then
            P.Links.arrowScale = n
            if P.Saved then P.Saved.arrowScale = n end
            P.Links.InitPins()
            Log("arrow pin size set to " .. n .. " (existing Pigeon pins were cleared)")
        end
    elseif cmd == "show" then
        if not (P.Links and P.Links.Highlight and P.Links.Highlight()) then Log("no pin to show yet") end
    elseif cmd == "waypoints" then
        local on = (rest ~= "off")
        if P.Saved then P.Saved.waypoints = on end
        if P.Links then P.Links.waypoints = on end
        Log("waypoints for other leaders' orders: " .. (on and "ON (needs MapMonster Navigator)" or "off"))
    elseif cmd == "map" then
        if PigeonMap then PigeonMap.Command(rest) end
    elseif cmd == "parrot" then
        if rest == "party" then
            local on = not (P.Links and P.Links.parrotParty)
            if P.Saved then P.Saved.parrotParty = on end
            if P.Links then P.Links.parrotParty = on end
            Log("also repeating WLH messages sent to party chat: " .. (on and "ON" or "off"))
        else
            local on = (rest ~= "off")
            if P.Saved then P.Saved.parrot = on end
            if P.Links then P.Links.parrot = on end
            Log("repeating your Warband Lead Helper warband messages to the other leaders: " .. (on and "ON" or "off"))
        end
    elseif cmd == "colour" or cmd == "color" then
        local on = (rest ~= "off")
        if P.Saved then P.Saved.colour = on end
        Log("coloured window text: " .. (on and "ON" or "off") .. " (turn off if you see raw <LINK ...> text)")
    elseif cmd == "track" then
        if P.Links then P.Links.track = (rest == "on") end
        Log("position sharing every " .. (P.Links and P.Links.trackInterval or 60) .. "s: " .. ((rest == "on") and "ON" or "off"))
    elseif cmd == "places" then
        local zone = CurrentPos()
        local list = LinkCall("ListPlaces", zone)
        Log(list or "no place list for this zone (needs WARCommander)")
    elseif cmd == "zone" then
        local zone = CurrentPos()
        Log((LinkCall("PlaceText", zone) or "?") .. " " .. (LinkCall("LockText", zone) or ""))
    elseif cmd == "relay" then
        local name = CleanName(rest)
        local o, who
        if name ~= "" then
            o, who = P.Board[name], name
        else
            for n, ord in pairs(P.Board) do
                if not o or ord.t > o.t then o, who = ord, n end
            end
        end
        if not o then Log("no order on the board to relay"); return end
        local ok, how = pcall(P.Links.Relay, o, who)
        if ok and how then Log("relayed to your warband: " .. tostring(how))
        else Log("relay failed: " .. tostring(how)) end
    elseif cmd == "pins" then
        local on = (rest ~= "off")
        if P.Saved then P.Saved.pins = on end
        if P.Links then P.Links.pinsEnabled = on; if not on then LinkCall("ClearAllPins") end end
        Log("map pins " .. (on and "on" or "off"))
    elseif cmd == "debug" then P.Debug()
    elseif cmd == "status" then
        for _, line in ipairs(LinkCall("Status") or { "integrations unavailable" }) do Log(line) end
    elseif cmd == "rate" then
        local secs = tonumber(rest)
        if secs and secs >= 0.2 and secs <= 5 then
            P.sendInterval = secs
            Log("send interval " .. secs .. "s")
        else
            Log("usage: /pg rate <0.2 to 5>  (now " .. P.sendInterval .. ")")
        end
    elseif cmd == "dry" then P.dryRun = (rest == "on"); Log("dry run " .. tostring(P.dryRun))
    elseif cmd == "probe" then P.probe = (rest == "on"); Log("probe " .. tostring(P.probe))
    elseif cmd == "test" then P.Selftest()
    else Help() end
end
