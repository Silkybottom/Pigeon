-- PigeonBar: three small controls inside the Pigeon window, in the strip above the log.
--   Relay WB: ON/off : whether what you say to your warband with WLH's buttons is relayed to the other leaders
--   + Player      : add the friendly player you have targeted to your leader roster
--   N waiting     : leaders waiting to link with you. With someone waiting it reads "+ Name":
--                   left click = add them, right click = dismiss them.
-- The buttons are children of the Pigeon window, so they open, close and move with it.
-- If anything here fails, Pigeon still works from /pg.

if not PigeonBar then PigeonBar = {} end
local B = PigeonBar
local P -- Pigeon core, resolved at Initialize

local PARENT = "PigeonWindow"
local H, GAP = 22, 4
local CTRL = { clear = 1, addt = 2, wait = 3 }              -- id = button number
local WIDTH = { [1] = 92, [2] = 84, [3] = 96 }              -- left to right, ending at the window's right edge
local YELLOW, GREEN, RED, WHITE = { 255, 225, 120 }, { 110, 230, 120 }, { 240, 110, 110 }, { 255, 255, 255 }
local ready = false
B.waitingName = nil

local function Say(msg) if P and P.Print then P.Print("[bar] " .. tostring(msg)) end end
local function BtnName(id) return "PigeonBar_Btn_" .. id end
local function IdFromName(name) return tonumber(string.match(tostring(name or ""), "PigeonBar_Btn_(%d+)")) end

local function Skin(id)
    local name = BtnName(id)
    if DoesWindowExist(name) then
        WindowSetTintColor(name .. "Background", 25, 55, 100)
        WindowSetAlpha(name .. "Background", 0.8)
    end
end

local function SetLabel(id, text, colour)
    local lbl = BtnName(id) .. "Label"
    LabelSetText(lbl, towstring(text))
    colour = colour or WHITE
    LabelSetTextColor(lbl, colour[1], colour[2], colour[3])
end

local function MakeButton(id, offsetFromRight)
    local name = BtnName(id)
    if not DoesWindowExist(name) then CreateWindowFromTemplate(name, "Pigeon_Btn_Template", PARENT) end
    local w = WIDTH[id]
    WindowSetDimensions(name, w, H)
    WindowSetDimensions(name .. "Label", w, H)
    WindowClearAnchors(name)
    WindowAddAnchor(name, "topright", PARENT, "topright", -20 - offsetFromRight, 42)
    WindowSetShowing(name, true)
    Skin(id)
end

function B.RefreshWaiting()
    local list = P.Waiting and P.Waiting() or {}
    B.waitingName = list[1] and list[1].name or nil
    if #list > 0 then
        SetLabel(CTRL.wait, #list .. " waiting", YELLOW)
    else
        SetLabel(CTRL.wait, "0 waiting", WHITE)
    end
end

function B.Refresh()
    if not ready then return end
    SetLabel(CTRL.clear, "Clear pins", WHITE)
    SetLabel(CTRL.addt, "+ Player", WHITE)
    B.RefreshWaiting()
    if PigeonUI and PigeonUI.UpdateRoster then pcall(PigeonUI.UpdateRoster) end
end
B.Apply = B.Refresh                                          -- called when the window opens

function B.Press(id, rightClick)
    if not id or not ready then return end
    if id == CTRL.clear then
        local LK = P.Links
        if LK then
            if LK.ClearTemp then pcall(LK.ClearTemp) end
            LK.ClearPin(P.Me())          -- only the pins you placed yourself; other leaders' pins stay
            Say("your pins cleared (other leaders' pins are untouched)")
        end
    elseif id == CTRL.addt then
        P.AddTarget()
    elseif id == CTRL.wait then
        if PigeonUI and PigeonUI.ToggleWaiting then PigeonUI.ToggleWaiting() end
    end
    B.Refresh()
end

local function Click(rightClick)
    local id = IdFromName(SystemData.MouseOverWindow and SystemData.MouseOverWindow.name)
        or IdFromName(SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    local ok, err = pcall(B.Press, id, rightClick)
    if not ok then Say("error: " .. tostring(err)) end
end

function B.OnLMB() Click(false) end
function B.OnRMB() Click(true) end

local function HoveredButton()
    local name = SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    local id = IdFromName(name)
    return id, id and BtnName(id)
end

function B.OnMouseOver()
    local id, win = HoveredButton()
    if not id then return end
    pcall(function()
        WindowSetAlpha(win .. "Background", 1)
        local tip
        if id == CTRL.clear then tip = "Remove the pins and arrows YOU placed (other leaders' pins stay)."
        elseif id == CTRL.addt then tip = "Add the friendly player you have targeted to your leader roster (they must be using Pigeon)."
        elseif id == CTRL.wait then tip = "Players waiting to link as leaders: opens the waiting list next to this window."
        end
        if tip and Tooltips and Tooltips.CreateTextOnlyTooltip then
            Tooltips.CreateTextOnlyTooltip(win, nil)
            Tooltips.SetTooltipText(1, 1, towstring(tip))
            Tooltips.Finalize()
            Tooltips.AnchorTooltip({ Point = "bottom", RelativeTo = win, RelativePoint = "top", XOffset = 0, YOffset = 0 })
            Tooltips.SetTooltipAlpha(1)
        end
    end)
end

function B.OnMouseOut()
    local id, win = HoveredButton()
    if id then pcall(WindowSetAlpha, win .. "Background", 0.8) end
end

function B.Initialize()
    P = Pigeon
    if not P then return end
    local ok, err = pcall(function()
        if not DoesWindowExist(PARENT) then error("Pigeon window is missing") end
        MakeButton(CTRL.wait, 0)
        MakeButton(CTRL.clear, WIDTH[CTRL.wait] + WIDTH[CTRL.addt] + 2 * GAP)
        MakeButton(CTRL.addt, WIDTH[CTRL.wait] + GAP)
        ready = true
        B.Refresh()
    end)
    if not ok then
        ready = false
        Say("controls failed to load: " .. tostring(err))
    end
end

function B.Shutdown()
    if not ready then return end
    for _, id in pairs(CTRL) do
        if DoesWindowExist(BtnName(id)) then DestroyWindow(BtnName(id)) end
    end
end
