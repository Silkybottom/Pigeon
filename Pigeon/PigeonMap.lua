-- PigeonMap: manual map orders. Right-click the world map or the minimap and pick an order:
-- Pigeon puts a pin there for you, tells the other leaders (they get the pin and, if MapMonster
-- Navigator is on, a waypoint) and, if you switch it on, tells your own warband through WLH.
--
-- If WARCommander is loaded its right-click menu is reused: Pigeon's items are added to that same
-- menu so the two add-ons never fight over the click. Without WARCommander Pigeon opens its own menu.
-- Everything is guarded; if something is missing the menu simply does not appear. /pg map shows status.

if not PigeonMap then PigeonMap = {} end
local M = PigeonMap
local P

M.MAIN_WINDOW = "EA_Window_WorldMapZoneViewMapDisplay"
M.MINI_WINDOW = "EA_Window_OverheadMapMapDisplay"
M.MINI_SCALE = { 40.93, 29, 19.5 }       -- minimap zoom level -> world units per pixel
M.nearRadius = 3000                      -- "near <place>" only when a named place is this close
M.mode = "off"                           -- "warcommander" | "own" | "off"
M.mapZone = nil
M.click = nil
M.lastError = nil
local registered = {}

local function Say(msg) if P and P.Print then P.Print("[map] " .. tostring(msg)) end end
local function LK() return P and P.Links end

-- Mouse -> zone coordinates ----------------------------------------------------------
local function OwnMouseToZone(x, y, minimap)
    local win = minimap and (M.miniWindow or M.MINI_WINDOW) or M.MAIN_WINDOW
    local wx, wy = WindowGetDimensions(win)
    local sc = WindowGetScale(win)
    wx, wy = wx * sc, wy * sc
    local sx, sy = WindowGetScreenPosition(win)
    local ax, ay = x - sx, y - sy
    if minimap then
        local okp, pos = pcall(MapMonsterAPI.GetPlayerPosition)
        if not okp then pos = nil end
        if not (pos and pos.worldX) then return nil, "move a few steps first so the minimap knows where you are" end
        local zoom = GetOverheadMapZoomLevel()
        local k = M.MINI_SCALE[zoom + 1] or M.MINI_SCALE[1]
        local pin = { worldX = math.floor(pos.worldX + (ax - wx / 2) / sc * k),
                      worldY = math.floor(pos.worldY + (ay - wy / 2) / sc * k), zoneId = pos.zoneId }
        return MapMonsterAPI.WorldToZone(pin)
    end
    local zone = M.mapZone or (GameData and GameData.Player and tonumber(GameData.Player.zone))
    local info = zone and MapMonsterAPI.GetZoneData(zone)
    if not info or info.noMap then return nil, "no map data for the zone on screen" end
    return { zoneId = zone, zoneX = math.floor(ax * info.mapsizeX / wx), zoneY = math.floor(ay * info.mapsizeY / wy) }
end

local function MouseToZone(minimap)
    local x, y = SystemData.MousePosition.x, SystemData.MousePosition.y
    local pin, why
    if WARCommander and WARCommander.MouseCoordsToZone then
        local zone = minimap and 0 or (WARCommander.mapZoneId or M.mapZone)
        local ok, r = pcall(WARCommander.MouseCoordsToZone, x, y, zone, minimap)
        if ok and type(r) == "table" then pin = r end
    end
    if not pin then
        local ok, r, w = pcall(OwnMouseToZone, x, y, minimap)
        if ok then pin, why = r, w else why = r end
    end
    if type(pin) ~= "table" or not (pin.zoneId and pin.zoneX and pin.zoneY) then
        M.lastError = tostring(why or "could not work out where you clicked")
        return nil
    end
    return { zone = tonumber(pin.zoneId), zx = math.floor(pin.zoneX), zy = math.floor(pin.zoneY), minimap = minimap }
end

-- Actions ------------------------------------------------------------------------------
local function NearPlace(c)
    local lk = LK()
    if not (lk and lk.PlaceList) then return nil end
    local best, bd
    for _, pl in ipairs(lk.PlaceList(c.zone)) do
        local d = math.sqrt((pl.zx - c.zx) ^ 2 + (pl.zy - c.zy) ^ 2)
        if d <= M.nearRadius and (not bd or d < bd) then best, bd = pl.name, d end
    end
    return best
end

function M.Place(code, c, toWarband)
    if not c then Say("no map position for that click"); return end
    local label = (P.TagLabel and P.TagLabel(code)) or code
    local near = NearPlace(c)
    local text = near and (label .. " - near " .. near) or label
    P.SendWlh(code, text, c.zone, c.zx, c.zy)
    if toWarband then
        local lk = LK()
        local ok, how = pcall(lk.Relay, { text = label, tag = code, zone = c.zone, zx = c.zx, zy = c.zy }, nil)
        Say(ok and ("told your warband " .. tostring(how)) or ("could not tell your warband: " .. tostring(how)))
    end
end

-- Attack / move line from the remembered start to this click: one message, five pins on every map.
function M.Arrow(code, c)
    local st = M.arrowStart
    M.arrowStart = nil
    if not (st and c and st.zone == c.zone) then Say("arrow needs a start and an end in the same zone"); return end
    local label = (P.TagLabel and P.TagLabel(code)) or code
    local a, b = NearPlace(st), NearPlace(c)
    local text = label .. " ARROW"
    if a and b and a ~= b then text = label .. ": " .. a .. " to " .. b
    elseif b then text = label .. " ARROW to " .. b end
    P.SendArrow(code, text, c.zone, st.zx, st.zy, c.zx, c.zy)
    if P.Saved and P.Saved.mapToWb then
        local lk = LK()
        local ok, how = pcall(lk.Relay, { text = text, tag = code, zone = c.zone, zx = c.zx, zy = c.zy }, nil)
        Say(ok and ("told your warband " .. tostring(how)) or ("could not tell your warband: " .. tostring(how)))
    end
end

function M.PinOnly(c)
    if not c then return end
    local lk = LK()
    local o = { text = "My marker", zone = c.zone, zx = c.zx, zy = c.zy, t = P.clock }
    P.ShowOrder("(you) ", o)
    P.PinNote(lk.OnOrder(P.Me(), o))
end

-- MapMonster can place the player wrongly in some zones. Right-click your own arrow on the world map to teach
-- Pigeon the difference; it is remembered per zone and applied to every "my position" order.
function M.Fix(c)
    local zone, _, _, wx, wy = LK().RawPlayerPosition()
    if not (zone and wx and wy) then Say("MapMonster does not know where you are yet: take a few steps, then try again"); return end
    if zone ~= c.zone then Say("that map is not the zone you are standing in"); return end
    P.Saved.zoneFix = P.Saved.zoneFix or {}
    P.Saved.zoneFix[zone] = { wx - c.zx, wy - c.zy }      -- where this zone's map really starts in world units
    Say("position calibrated for this zone (/pg map fix reset undoes it)")
end

-- Menu ---------------------------------------------------------------------------------
local ORDERS = { { "AT", "Attack here" }, { "HD", "Hold here" }, { "MV", "Move here" }, { "RG", "Regroup here" }, { "BO", "Take BO here" } }
local GROUPS = { { "G1", "Group 1 - move here" }, { "G2", "Group 2 - move here" }, { "G3", "Group 3 - move here" }, { "G4", "Group 4 - move here" } }
local SPOTS  = { { "SW", "Warband spotted here" }, { "SG", "Group spotted here" }, { "CF", "Conflict here" } }

local function AddItem(text, fn)
    EA_Window_ContextMenu.AddMenuItem(towstring(text), fn, false, true)
end

local function Divider()
    if EA_Window_ContextMenu.AddMenuDivider then pcall(EA_Window_ContextMenu.AddMenuDivider) end
end

function M.AddItems(c)
    if not c then return end
    local toWb = P.Saved and P.Saved.mapToWb
    local function Group(list)
        for _, o in ipairs(list) do
            local code, name = o[1], o[2]
            AddItem(name, function() M.Place(code, c, P.Saved and P.Saved.mapToWb) end)
        end
    end
    Group(ORDERS); Divider()
    Group(GROUPS); Divider()
    Group(SPOTS); Divider()
    AddItem("Marker for me only", function() M.PinOnly(c) end)
    local st = M.arrowStart
    if st and st.zone == c.zone then
        AddItem("Attack arrow to here", function() M.Arrow("AT", c) end)
        AddItem("Move arrow to here", function() M.Arrow("MV", c) end)
        AddItem("Cancel arrow", function() M.arrowStart = nil end)
    else
        AddItem("Arrow starts here", function()
            M.arrowStart = c
            Say("arrow start set. Right-click where it should point and pick Attack arrow or Move arrow.")
        end)
    end
    Divider()
    if not c.minimap then
        AddItem("I am standing here (fix my position)", function() M.Fix(c) end)
    end
    AddItem("Also tell my warband - " .. (toWb and "ON" or "off"), function()
        if P.Saved then P.Saved.mapToWb = not P.Saved.mapToWb end
        Say("map orders also go to your warband: " .. ((P.Saved and P.Saved.mapToWb) and "ON" or "off"))
    end)
end

-- Own right-click handler (only used when WARCommander is not loaded).
function M.OnClickMap()
    local w = SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    local mini = (w == (M.miniWindow or M.MINI_WINDOW))
    if w ~= M.MAIN_WINDOW and not mini then return end
    local ok, err = pcall(function()
        local c = MouseToZone(mini)
        if not c then Say("cannot place a pin there: " .. tostring(M.lastError)); return end
        M.click = c
        EA_Window_ContextMenu.CreateContextMenu("PigeonMap_contextMenu")
        M.AddItems(c)
        EA_Window_ContextMenu.Finalize()
    end)
    if not ok then M.lastError = tostring(err); Say("menu error: " .. tostring(err)) end
end

-- With WARCommander: wrap its click handlers so our items go into the very same menu, just before it is finalized.
local function Extend(orig, mini)
    return function(...)
        local c
        pcall(function() c = MouseToZone(mini) end)
        M.click = c
        local real = EA_Window_ContextMenu.Finalize
        EA_Window_ContextMenu.Finalize = function(...)
            EA_Window_ContextMenu.Finalize = real
            if c then pcall(M.AddItems, c) end
            return real(...)
        end
        local ok, err = pcall(orig, ...)
        EA_Window_ContextMenu.Finalize = real
        if not ok then error(err) end
    end
end

local function Register(win)
    if registered[win] or not (DoesWindowExist and DoesWindowExist(win)) then return false end
    local ok = pcall(WindowRegisterEventHandler, win, SystemData.Events.R_BUTTON_DOWN_PROCESSED, "PigeonMap.OnClickMap")
    registered[win] = ok
    return ok
end

function M.Initialize()
    P = Pigeon
    if not (P and MapMonsterAPI and EA_Window_ContextMenu) then M.mode = "off"; return end
    if MiniMapMonster and MiniMapMonster.MINI_MAP_WINDOW then M.miniWindow = MiniMapMonster.MINI_MAP_WINDOW end
    if P.Saved and P.Saved.mapToWb == nil then P.Saved.mapToWb = false end

    -- remember which zone the world map shows (WARCommander does the same; hooks chain fine)
    if EA_Window_WorldMap and EA_Window_WorldMap.ShowZone and not M.hookShowZone then
        M.hookShowZone = EA_Window_WorldMap.ShowZone
        EA_Window_WorldMap.ShowZone = function(zoneId, ...)
            M.mapZone = zoneId
            return M.hookShowZone(zoneId, ...)
        end
    end

    if WARCommander and WARCommander.OnClickMap and not M.wrapped then
        WARCommander.OnClickMap = Extend(WARCommander.OnClickMap, false)
        if WARCommander.OnClickMiniMap then WARCommander.OnClickMiniMap = Extend(WARCommander.OnClickMiniMap, true) end
        M.wrapped = true
        M.mode = "warcommander"
    else
        local a = Register(M.MAIN_WINDOW)
        local b = Register(M.miniWindow or M.MINI_WINDOW)
        M.mode = (a or b) and "own" or "off"
    end
end

function M.Shutdown() end

-- /pg map ------------------------------------------------------------------------------
function M.Command(arg)
    arg = string.lower(tostring(arg or ""))
    if arg == "wb on" or arg == "wb off" then
        if P.Saved then P.Saved.mapToWb = (arg == "wb on") end
        Say("map orders also go to your warband: " .. (arg == "wb on" and "ON" or "off"))
    elseif arg == "fix reset" then
        if P.Saved then P.Saved.zoneFix = nil; P.Saved.posFix = nil end
        Say("position corrections cleared")
    elseif arg == "test" then
        local zone, zx, zy = P.Links.PlayerPosition()
        if not (zone and zx and zy) then Say("no position yet: move a few steps, then try again"); return end
        M.PinOnly({ zone = zone, zx = zx, zy = zy })
        Say("test marker placed where you stand. " .. tostring(P.Links.lastPin))
    else
        Say("right-click menu: " .. M.mode .. (M.mode == "warcommander" and " (items added to WARCommander's menu)" or ""))
        Say("last click: " .. (M.click and (M.click.zone .. " " .. M.click.zx .. "," .. M.click.zy) or "none") ..
            ", last problem: " .. tostring(M.lastError))
        Say("also tell warband: " .. ((P.Saved and P.Saved.mapToWb) and "ON" or "off") .. "  (/pg map wb on|off)")
        Say("/pg map test puts a marker where you stand to check pins work. /pg show flashes the newest pin.")
    end
end
