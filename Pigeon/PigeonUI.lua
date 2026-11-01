-- PigeonUI: the window half of Pigeon (same add-on, called from Pigeon.Initialize).
--   /pgwin         show or hide the window
--   /pgwin info    report whether the window parts exist and how big they are
-- Read-only window: leader rows, order log. Everything is sent with the WLH buttons and the map menu.
-- Start the line with / to run a Pigeon command, e.g.  /order attack at Kazad Dammaz 5m
-- If this part fails, Pigeon keeps working through the normal chat box.

if not PigeonUI then PigeonUI = {} end
local UI = PigeonUI

local WIN, LOG, ROSTER = "PigeonWindow", "PigeonLog", "PigeonRoster"
local TITLEBAR_TEXT = WIN .. "TitleBarText"
local LOGNAME = "PigeonLog"
local ready = false

local function Say(msg)
    if Pigeon and Pigeon.Print then Pigeon.Print("[UI] " .. tostring(msg)) end
end

-- Coloured text uses the same <LINK color=...> markup Warband Lead Helper puts in chat.
local function Markup(segs)
    local out = {}
    for _, sg in ipairs(segs) do
        local t = string.gsub(tostring(sg[1]), '[<>"%c]', "")
        local c = sg[2] or { 235, 235, 235 }
        if t ~= "" then
            local data = "0"
            if type(sg[3]) == "string" and string.find(sg[3], "^PGN:%d+,%d+,%d+$") then data = sg[3] end   -- clickable coordinates
            out[#out + 1] = '<LINK data="' .. data .. '" color="' .. c[1] .. "," .. c[2] .. "," .. c[3] .. '" text="' .. t .. '">'
        end
    end
    return table.concat(out)
end

function UI.AddLine(line, segs)
    if not ready then return end
    local text = line
    if segs and Pigeon.Saved and Pigeon.Saved.colour then
        local ok, m = pcall(Markup, segs)
        if ok and m ~= "" then text = m end
    end
    local ok, err = pcall(TextLogAddEntry, LOGNAME, 0, towstring(text))
    if not ok then
        pcall(TextLogAddEntry, LOGNAME, 0, towstring(line))      -- markup was refused: show it plain
    end
end

-- A click on a coloured piece of text in the window. Pieces that carry coordinates open the map on them.
function UI.OnLink(link)
    local ok, err = pcall(function()
        local data = tostring(link or "")
        if string.find(data, "^PGN:") and Pigeon.Links and Pigeon.Links.OpenAt then
            Pigeon.Links.OpenAt(data)
        end
    end)
    if not ok then Say("link click failed: " .. tostring(err)) end
end

-- Drag the small square in the bottom-right corner to resize the window (size is remembered).
local grip
function UI.GripDown()
    if not ready then return end
    local ok, w, h = pcall(WindowGetDimensions, WIN)
    if not ok then return end
    grip = { mx = SystemData.MousePosition.x, my = SystemData.MousePosition.y, w = w, h = h }
    -- The window is centred on screen, so growing it moves the corner away at half speed. Pin the top-left
    -- corner where it is now; then the bottom-right corner (the grip) stays under the cursor.
    pcall(function()
        local sx, sy = WindowGetScreenPosition(WIN)
        local sc = (InterfaceCore and InterfaceCore.GetScale and InterfaceCore.GetScale()) or WindowGetScale(WIN) or 1
        if not sc or sc <= 0 then sc = 1 end
        WindowClearAnchors(WIN)
        WindowAddAnchor(WIN, "topleft", "Root", "topleft", sx / sc, sy / sc)
    end)
end

function UI.GripUp()
    if grip and Pigeon.Saved then
        local w, h = WindowGetDimensions(WIN)
        Pigeon.Saved.winSize = { w, h }
    end
    grip = nil
end

-- The layout editor resizes a window by scaling it, which blows the text up with it. Once the scale has stopped
-- changing (you let go of the handle), turn it into a real size change: back to the normal scale, with the
-- window as big as it looked, so the text keeps its size and only the frame grows.
local scaleSeen = {}
local function Unscale(name, minW, minH)
    if not (DoesWindowExist and DoesWindowExist(name)) then return end
    local base = (InterfaceCore and InterfaceCore.GetScale and InterfaceCore.GetScale()) or 1
    if not base or base <= 0 then base = 1 end
    local sc = WindowGetScale(name)
    if not sc then return end
    if math.abs(sc - base) < 0.005 then scaleSeen[name] = nil; return end
    local rec = scaleSeen[name]
    if not rec or math.abs(rec.sc - sc) > 0.0005 then
        scaleSeen[name] = { sc = sc, t = Pigeon.clock }           -- still changing (being dragged)
        return
    end
    if Pigeon.clock - rec.t < 0.6 then return end                  -- wait until it has settled
    local w, h = WindowGetDimensions(name)
    local r = sc / base
    WindowSetScale(name, base)
    WindowSetDimensions(name, math.max(minW, w * r), math.max(minH, h * r))
    scaleSeen[name] = nil
end

function UI.Tick()
    if ready and not grip then
        pcall(Unscale, WIN, 420, 340)
        pcall(Unscale, "PigeonWaiting", 270, 200)
    end
    if not (grip and ready) then return end
    local sc = 1
    pcall(function() sc = WindowGetScale(WIN) or 1 end)
    if sc <= 0 then sc = 1 end
    local w = math.max(420, math.min(900, grip.w + (SystemData.MousePosition.x - grip.mx) / sc))
    local h = math.max(340, math.min(900, grip.h + (SystemData.MousePosition.y - grip.my) / sc))
    WindowSetDimensions(WIN, w, h)
end

function UI.UpdateRoster()
    if UI.WaitingRefresh then pcall(UI.WaitingRefresh) end
    if not ready then return end
    local P = Pigeon
    local line1
    if P.ChannelOn and P.ChannelOn() then
        line1 = "Command " .. tostring(P.Saved and P.Saved.channel or "/9")
        if not P.chanOk then line1 = line1 .. " (unverified)" end      -- our own line has not come back yet
    else
        line1 = "Whispers (channel off)"
    end
    local names = {}
    for name, r in pairs(P.roster) do if r.active ~= false then names[#names + 1] = name end end
    table.sort(names)
    local n, shown = #names, {}
    for i = 1, math.min(n, 2) do shown[i] = names[i] end
    local line2 = n == 0 and "no leaders trusted yet" or (n .. " trusted: " .. table.concat(shown, ", ") .. (n > 2 and (" +" .. (n - 2)) or ""))
    LabelSetText(ROSTER, towstring(line1 .. "\n" .. line2))
end

-- Leader rows ------------------------------------------------------------------------
-- One row per approved leader (you first) showing their latest order. Left click opens the map on it,
-- right click lists their last five orders; picking one shows its pins on the map until you close it.
local ROWS, ROW_H, ROW_TOP, ROW_W = 8, 24, 82, 480
local function RowName(i) return "PigeonRow" .. i end
local rowNames = {}                     -- row index -> leader name currently shown

local function Age(o)
    local s = Pigeon.clock - (o.t or Pigeon.clock)
    if s < 60 then return "now" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    return math.floor(s / 3600) .. "h"
end

local function OrderText(o)
    local ok, text = pcall(Pigeon.DescribeOrder, o, true)
    return ok and text or tostring(o.text or "?")
end

function UI.CreateRows()
    for i = 1, ROWS do
        local n = RowName(i)
        if not DoesWindowExist(n) then CreateWindowFromTemplate(n, "Pigeon_Row_Template", WIN) end
        WindowSetDimensions(n, ROW_W, ROW_H - 2)
        WindowClearAnchors(n)
        WindowAddAnchor(n, "topleft", WIN, "topleft", 20, ROW_TOP + (i - 1) * ROW_H)
        WindowAddAnchor(n, "topright", WIN, "topright", -20, ROW_TOP + (i - 1) * ROW_H)     -- stretches with the window
        WindowSetTintColor(n .. "Background", 25, 45, 80)
        WindowSetAlpha(n .. "Background", 0.55)
        WindowSetShowing(n, false)
    end
end

function UI.RefreshRows()
    if not ready then return end
    local rows = Pigeon.Rows()
    for i = 1, ROWS do
        local n, r = RowName(i), rows[i]
        if DoesWindowExist(n) then
            if r then
                rowNames[i] = r.name
                local nc = r.you and { 255, 255, 255 } or (r.active and { 150, 220, 160 } or { 140, 140, 140 })
                local dim = (not r.you) and not r.active                     -- quiet / stepped down: greyed out
                WindowSetTintColor(n .. "Background", dim and 45 or 25, dim and 45 or 45, dim and 50 or 80)
                WindowSetAlpha(n .. "Background", dim and 0.3 or 0.55)
                LabelSetText(n .. "Name", towstring(r.you and "You" or r.name))
                LabelSetTextColor(n .. "Name", nc[1], nc[2], nc[3])
                local text, col
                if r.o then
                    text, col = OrderText(r.o), Pigeon.TagColour(r.o.tag or (r.o.verb and Pigeon.Verbs[r.o.verb] and Pigeon.Verbs[r.o.verb].tag))
                else
                    local why
                    if r.active then why = "no orders yet"
                    elseif r.state == "stepped" then why = "not leading right now"
                    elseif r.since then why = "offline? last heard " .. (r.since >= 60 and (math.floor(r.since / 60) .. "h") or (r.since .. "m")) .. " ago"
                    else why = "offline? not heard since you logged in" end
                    text, col = why, { 140, 140, 140 }
                end
                LabelSetText(n .. "Text", towstring(text))
                LabelSetText(n .. "Age", towstring(r.o and Age(r.o) or ""))      -- own label, always visible at the right edge
                if dim and r.o then col = { 150, 150, 150 } end               -- an old order from someone offline is dimmed too
                LabelSetTextColor(n .. "Age", 200, 200, 200)
                LabelSetTextColor(n .. "Text", col[1], col[2], col[3])
                WindowSetShowing(n, true)
            else
                rowNames[i] = nil
                WindowSetShowing(n, false)
            end
        end
    end
end

local function RowIndex()
    local name = SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    return tonumber(string.match(tostring(name or ""), "PigeonRow(%d+)"))
end

function UI.OnRowLMB()
    local ok, err = pcall(function()
        local who = rowNames[RowIndex()]
        local h = who and Pigeon.Hist[who]
        if not (h and h[1]) then Say("nothing to show yet"); return end
        Pigeon.Links.OpenOrder(h[1])
    end)
    if not ok then Say("row click failed: " .. tostring(err)) end
end

function UI.OnRowRMB()
    local ok, err = pcall(function()
        local who = rowNames[RowIndex()]
        local h = who and Pigeon.Hist[who]
        if not (h and #h > 0) then Say("no orders from " .. tostring(who or "that leader") .. " yet"); return end
        EA_Window_ContextMenu.CreateContextMenu("PigeonHistoryMenu")
        for _, o in ipairs(h) do
            local hasPlace = o.zone and o.zx and o.zy
            local label = Age(o) .. "   " .. OrderText(o)
            EA_Window_ContextMenu.AddMenuItem(towstring(label), function() Pigeon.Links.OpenOrder(o) end, not hasPlace, true)
        end
        EA_Window_ContextMenu.Finalize()
    end)
    if not ok then Say("history menu failed: " .. tostring(err)) end
end

function UI.OnCloseClicked()
    UI.Toggle()
end

function UI.IsShowing()
    if not ready then return false end
    local ok, r = pcall(WindowGetShowing, WIN)
    return ok and r == true
end

local function Describe(name)
    local ok, res = pcall(function()
        if DoesWindowExist and not DoesWindowExist(name) then return "does not exist" end
        local w, h = WindowGetDimensions(name)
        return "exists, showing=" .. tostring(WindowGetShowing(name))
            .. ", size=" .. tostring(w) .. "x" .. tostring(h)
    end)
    return ok and res or ("error: " .. tostring(res))
end

function UI.Info()
    Say("window: " .. Describe(WIN))
    Say("log: " .. Describe(LOG))
    Say("roster label: " .. Describe(ROSTER))
    Say("title bar text: " .. Describe(TITLEBAR_TEXT))
end

-- Waiting list: a sidebar window next to the main one (same frame). Left click a name = add as leader, right click = dismiss.
local WAITING, WAIT_ROWS = "PigeonWaiting", 8
local waitNames = {}

local function WaitRow(i) return "PigeonWaitRow" .. i end

function UI.WaitingRefresh()
    if not (ready and DoesWindowExist(WAITING)) then return end
    local list = Pigeon.Waiting and Pigeon.Waiting() or {}
    for i = 1, WAIT_ROWS do
        local n = WaitRow(i)
        if not DoesWindowExist(n) then
            CreateWindowFromTemplate(n, "Pigeon_Wait_Template", WAITING)
            WindowSetDimensions(n, 230, 22)
            WindowClearAnchors(n)
            WindowAddAnchor(n, "topleft", WAITING, "topleft", 20, 82 + (i - 1) * 24)
            WindowAddAnchor(n, "topright", WAITING, "topright", -20, 82 + (i - 1) * 24)
            WindowSetTintColor(n .. "Background", 60, 50, 20)
            WindowSetAlpha(n .. "Background", 0.55)
        end
        local w = list[i]
        waitNames[i] = w and w.name or nil
        if w then
            LabelSetText(n .. "Name", towstring(w.name))
            LabelSetText(n .. "Via", towstring(w.via or ""))
        end
        WindowSetShowing(n, w ~= nil)
    end
    local hint = #list == 0 and "Nobody is waiting to link." or "Left click a name: add as leader. Right click: dismiss."
    LabelSetText("PigeonWaitingHint", towstring(hint))
end

local function WaitIndex()
    local name = SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    return tonumber(string.match(tostring(name or ""), "PigeonWaitRow(%d+)"))
end

function UI.OnWaitLMB()
    local who = waitNames[WaitIndex() or 0]
    if who then pcall(Pigeon.AddLeader, who) end
    UI.WaitingRefresh()
end

function UI.OnWaitRMB()
    local who = waitNames[WaitIndex() or 0]
    if who then pcall(Pigeon.Dismiss, who) end
    UI.WaitingRefresh()
end

function UI.ToggleWaiting(show)
    if not (ready and DoesWindowExist(WAITING)) then return end
    if show == nil then show = not WindowGetShowing(WAITING) end
    if show then UI.WaitingRefresh() end
    WindowSetShowing(WAITING, show)
end

function UI.OnWaitingClose() UI.ToggleWaiting(false) end

function UI.WaitingShowing()
    return ready and DoesWindowExist(WAITING) and WindowGetShowing(WAITING) == true
end

function UI.Initialize()
    if not Pigeon then return end

    local ok, err = pcall(function()
        TextLogCreate(LOGNAME, 128)
        CreateWindow(WIN, true)
        LogDisplayAddLog(LOG, LOGNAME, false)
        LabelSetText(TITLEBAR_TEXT, L"Pigeon")
        ready = true

        pcall(CreateWindow, WAITING, false)
        pcall(LabelSetText, WAITING .. "TitleBarText", L"Waiting")
        -- The game's layout editor can then move AND resize both windows like any other (so our own resize
        -- square is only needed when there is no layout editor).
        UI.layoutEditor = false
        if LayoutEditor and LayoutEditor.RegisterWindow then
            local okL = pcall(function()
                LayoutEditor.RegisterWindow(WIN, L"Pigeon", L"Pigeon leader window.", true, true, true, nil)
                LayoutEditor.RegisterWindow(WAITING, L"Pigeon waiting list", L"Pigeon waiting list window.", false, false, true, nil)
            end)
            UI.layoutEditor = okL
        end
        if UI.layoutEditor then pcall(WindowSetShowing, "PigeonGrip", false) end
        local sz = Pigeon.Saved and Pigeon.Saved.winSize
        if not UI.layoutEditor and type(sz) == "table" and tonumber(sz[1]) and tonumber(sz[2]) then WindowSetDimensions(WIN, sz[1], sz[2]) end
        UI.CreateRows()
        UI.UpdateRoster()
        UI.RefreshRows()

        Pigeon.onComms = UI.AddLine
        Pigeon.onRoster = UI.UpdateRoster
        Pigeon.onRows = UI.RefreshRows
        Pigeon.mirrorToChat = false   -- window is open: don't double-print
    end)

    if not ok then
        ready = false
        Say("window failed to load: " .. tostring(err))
        return
    end

    if LibSlash then
        LibSlash.RegisterSlashCmd("pgwin", function(args) UI.SlashCmd(args) end)
    end
    Say("window ready. /pgwin toggles it.")
end

function UI.Toggle()
    if not ready then Say("window is not available"); return end
    local showing = WindowGetShowing(WIN)
    WindowSetShowing(WIN, not showing)
    if showing and UI.ToggleWaiting then UI.ToggleWaiting(false) end
    -- Hidden: send comms back to the normal chat box so nothing is missed.
    Pigeon.mirrorToChat = showing and true or false
    if PigeonBar and PigeonBar.Apply then pcall(PigeonBar.Apply) end   -- the button column follows the window
end

function UI.SlashCmd(args)
    args = tostring(args or "")
    local cmd = string.lower(string.match(args, "^(%S*)") or "")
    if cmd == "info" then UI.Info() else UI.Toggle() end
end
