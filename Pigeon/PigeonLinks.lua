-- Pigeon integrations. Every bridge to another add-on is optional and guarded:
-- if the add-on is missing, that feature quietly switches off. Nothing here copies
-- another add-on's code; it only calls the functions those add-ons expose.
--
--   Warband Lead Helper  -> everything you say to your warband with WLH's buttons is repeated to the
--                           other leaders (parrot); /pg relay repeats a leader's order to YOUR warband
--   MapMonster           -> orders and positions become short-lived map pins (type "Pigeon")
--   WARCommander         -> named places (PointsOfInterest) for "/pg order attack at <place>"
--   ZonepopLite          -> lock timer text appended to orders for that zone
--
-- Rule: MapMonsterAPI.CreatePin / DeletePin are always looked up at call time, never cached,
-- because MiniMapMonster wraps them to draw pins on the minimap.

if not Pigeon then Pigeon = {} end
local P = Pigeon
P.Links = P.Links or {}
local LK = P.Links

LK.pinType = "Pigeon"
LK.pins = {}                 -- pins[leaderName] = { id = pinId, expires = clock }
LK.pinsReady = false
LK.pinsEnabled = true
LK.track = false
LK.trackInterval = 60
LK.parrotParty = false      -- also repeat messages WLH sends to party chat (/pg parrot party)
LK.parrot = true             -- repeat WLH warband messages to the other leaders
LK.hooked = false
LK.trace = {}               -- last things the WLH hook saw, shown by /pg debug
LK.lastPin = "none yet"
LK.waypoints = true          -- orders from other leaders also become MapMonster Navigator waypoints
LK.lastPinId = nil
LK.pinScale = 1.75           -- icon size (WARCommander uses 0.875); /pg pinsize <n>
LK.arrowScale = 0.875        -- arrows use many pins, so they stay small (normal MapMonster size); /pg arrowsize <n>
LK.temp = nil
LK.bigPins = {}              -- pin window name -> pixels to pull back so a bigger icon stays centred
LK.relaying = false          -- true while WE are saying something to our warband (never parrot that back)
local lastTrack = -1000

-- Map pin colour groups: one sub type each.
-- Each kind has its own icon (the same ones WARCommander uses) so orders can be told apart without reading.
local KINDS = {
    attack   = { label = "Attack",   tint = { r = 220, g = 60,  b = 60  }, tex = "EA_HUD_01",     slice = "PartyMarker-Sword" },
    defend   = { label = "Hold",     tint = { r = 70,  g = 190, b = 90  }, tex = "EA_HUD_01",     slice = "PartyMarker-Shield" },
    move     = { label = "Move",     tint = { r = 80,  g = 140, b = 230 }, tex = "map_markers01", slice = "Waypoint-Large", mult = 0.75 },
    regroup  = { label = "Regroup",  tint = { r = 90,  g = 220, b = 235 }, tex = "EA_Apothecary01_d5", slice = "White-Orb", mult = 0.95 },
    other    = { label = "Order",    tint = { r = 230, g = 200, b = 60  }, tex = "map_markers01", slice = "Shout-Incoming" },
    -- WARCommander's own icons for the four groups and the enemy sightings (kept in their original colours)
    group1   = { label = "Group 1",  tint = { r = 255, g = 255, b = 255 }, tex = "EA_HUD_01",     slice = "PartyMarker-Fist" },
    group2   = { label = "Group 2",  tint = { r = 255, g = 255, b = 255 }, tex = "EA_HUD_01",     slice = "PartyMarker-Moon" },
    group3   = { label = "Group 3",  tint = { r = 255, g = 255, b = 255 }, tex = "EA_HUD_01",     slice = "PartyMarker-Shield" },
    group4   = { label = "Group 4",  tint = { r = 255, g = 255, b = 255 }, tex = "EA_HUD_01",     slice = "PartyMarker-Sun" },
    spotwb   = { label = "Warband spotted", tint = { r = 255, g = 255, b = 255 }, tex = "EA_HUD_01", slice = "RvR-Flag", mult = 0.85 },
    spotgrp  = { label = "Group spotted",   tint = { r = 70,  g = 210, b = 90 },  tex = "EA_HUD_01", slice = "RvR-Flag", mult = 0.5 },
    conflict = { label = "Conflict",        tint = { r = 255, g = 120, b = 60 },  tex = "map_markers01", slice = "Shout-Incoming", mult = 1.2 },
    position = { label = "Leader",   tint = { r = 255, g = 255, b = 255 }, tex = "EA_HUD_01",     slice = "RvR-Flag" },
}

-- Every icon is a rectangle cut out of a big shared texture (an atlas). A pin window that is larger than its icon shows the
-- neighbouring pictures from the atlas, and one that is smaller cuts the icon off. SLICE_BASE is the scale at which the
-- picture fills MapMonster's standard 28 pixel pin window (taken from the sizes MapMonster and WARCommander use for them),
-- so a pin at scale s needs a window of 28 * s / base pixels - exactly the picture, nothing more or less.
LK.SLICE_BASE = {
    ["Waypoint-Large"] = 0.875, ["RvR-Flag"] = 0.65, ["Shout-Incoming"] = 1.2, ["White-Orb"] = 1.3,
    ["PartyMarker-Fist"] = 0.9, ["PartyMarker-Moon"] = 0.9, ["PartyMarker-Shield"] = 0.9, ["PartyMarker-Sun"] = 0.9,
    ["PartyMarker-Sword"] = 0.9, ["PartyMarker-Skull"] = 0.9,
}
LK.subSlice = {}

local ARROW_TINT = { r = 80, g = 230, b = 100 }

local function Log(msg) P.Print(msg) end

function LK.ErrCode()
    local code = MapMonster and MapMonster.ERROR_CODE
    return tostring(code)
end

local function ZoneName(zone)
    if not zone then return "" end
    local ok, n = pcall(function() return tostring(GetZoneName(zone)) end)
    if ok and n and n ~= "" then
        n = string.gsub(n, "%^.*$", "")
        return n
    end
    return "zone " .. tostring(zone)
end

-- Position / places ------------------------------------------------------------
-- Returns zoneId, zoneX, zoneY (the last two are nil until MapMonster knows them).
-- Tell MapMonster which zone we are really in (it keeps its own copy and can get stuck on an old one).
function LK.RepairZone(zone)
    zone = tonumber(zone) or (GameData and GameData.Player and tonumber(GameData.Player.zone))
    if not (zone and zone > 0 and MapMonster and MapMonster.GetTruePosition) then return false end
    local ok, tp = pcall(MapMonster.GetTruePosition)
    if not (ok and type(tp) == "table") then return false end
    if tp.zoneId ~= zone then
        tp.zoneId = zone
        tp.worldX, tp.worldY, tp.zoneX, tp.zoneY = nil, nil, nil, nil     -- position is unknown until you move
        return true
    end
    return false
end

function LK.PlayerPosition()
    local zone, zx, zy, wx, wy = LK.RawPlayerPosition()
    local fix = zone and P and P.Saved and P.Saved.zoneFix and P.Saved.zoneFix[zone]
    if fix and wx and wy then
        zx, zy = math.floor(wx - fix[1]), math.floor(wy - fix[2])     -- the player's own calibration beats MapMonster's zone data
    end
    if zx and zy and not (fix and wx and wy) then
        local sh = LK.GlobalShift(zone)
        zx, zy = zx + sh[1], zy + sh[2]
    end
    return zone, zx, zy
end

-- MapMonster's player position looks consistently off by about this much on the world map (measured in Praag:
-- 2502,3906 and roughly 3100,3000 from a screenshot). Applied to every zone until the player calibrates that zone.
LK.DEFAULT_SHIFT = { 5500, 4500 }
-- Measured in game, per zone (zone id = {x, y}). Your own /pg shift for a zone still wins over these.
LK.ZONE_SHIFT = {
    [1]   = { 4500, 4500 },  -- Marshes of Madness
    [2]   = { 4500, 4500 },  -- The Badlands
    [3]   = { 4000, 4000 },  -- Black Crag
    [5]   = { 4000, 4000 },  -- Thunder Mountain
    [6]   = { 6500, 3000 },  -- Ekrund
    [7]   = { 3500, 4500 },  -- Barak Varr
    [8]   = { 4500, 3000 },  -- Black Fire Pass
    [9]   = { 4000, 4000 },  -- Kadrin Valley
    [11]  = { 1500, 2500 },  -- Mount Bloodhorn
    [100] = { 5500, 5500 },  -- Norsca
    [101] = { 4000, 4000 },  -- Troll Country
    [102] = { 4500, 4500 },  -- High Pass
    [103] = { 4500, 4500 },  -- Chaos Wastes
    [105] = { 3500, 4500 },  -- Praag
    [106] = { 4000, 4000 },  -- Nordland
    [107] = { 4000, 3000 },  -- Ostland
    [108] = { -1000, 4500 }, -- Talabecland
    [109] = { 3000, 4500 },  -- Reikland
    [200] = { 5500, 5500 },  -- The Blighted Isle
    [201] = { 5500, 5500 },  -- The Shadowlands
    [202] = { 5500, 4500 },  -- Avelorn
    [203] = { 3500, 4500 },  -- Caledor
    [205] = { -23000, -9000 }, -- Dragonwake
    [206] = { 5500, 4000 },  -- Chrace
    [208] = { 5500, 4000 },  -- Saphery
    [209] = { 5000, 3500 },  -- Eataine
}
function LK.GlobalShift(zone)
    local zs = zone and P and P.Saved and P.Saved.zoneShift and P.Saved.zoneShift[zone]
    if type(zs) == "table" and tonumber(zs[1]) and tonumber(zs[2]) then return { tonumber(zs[1]), tonumber(zs[2]) } end
    local bz = zone and LK.ZONE_SHIFT[zone]
    if bz then return { bz[1], bz[2] } end
    local sv = P and P.Saved and P.Saved.posShift
    if type(sv) == "table" and tonumber(sv[1]) and tonumber(sv[2]) then return { tonumber(sv[1]), tonumber(sv[2]) } end
    return LK.DEFAULT_SHIFT
end

-- What MapMonster says (zone, zoneX, zoneY, worldX, worldY); the zone coordinates are nil when it could not convert them.
function LK.RawPlayerPosition()
    local zone, zx, zy, wx, wy
    LK.usingLastPos = false
    pcall(function() zone = tonumber(GameData.Player.zone) end)
    if MapMonsterAPI and MapMonsterAPI.GetPlayerPosition then
        local ok, pos = pcall(MapMonsterAPI.GetPlayerPosition)
        if ok and type(pos) == "table" then
            local gz = zone
            zone = tonumber(pos.zoneId) or zone
            if gz and zone ~= gz then
                -- MapMonster is stuck on another zone: its coordinates belong to that zone, so they are no good here
                LK.zoneMismatch = { game = gz, mm = zone }
                LK.RepairZone(gz)
                zone, zx, zy, wx, wy = gz, nil, nil, nil, nil
                pos = {}
            else
                LK.zoneMismatch = nil
            end
            if pos.zoneX and pos.zoneY then
                zx = math.floor(pos.zoneX)
                zy = math.floor(pos.zoneY)
            end
            if pos.worldX and pos.worldY then wx, wy = pos.worldX, pos.worldY end
        end
    end
    -- MapMonster has no usable position (lost track after travelling, or could not convert it): work it out
    -- ourselves from the world position the game reported and MapMonster's own offset for this zone.
    LK.ownCalc = false
    if not (zx and zy) and P and P.world and zone and P.world.zone == zone
       and MapMonsterAPI and MapMonsterAPI.GetZoneData then
        local okz, info = pcall(MapMonsterAPI.GetZoneData, zone)
        if okz and type(info) == "table" and info.offsetX and info.offsetY then
            local x, y = P.world.x, P.world.y
            local cx, cy = tonumber(info.chunkX), tonumber(info.chunkY)
            if cx and cy and cx > 0 and cy > 0 then          -- same wrap as MapMonster, but cannot loop forever on bad data
                if x > cx then x = x - cx * math.floor((x - 1) / cx) end
                if y > cy then y = y - cy * math.floor((y - 1) / cy) end
            end
            zx, zy = math.floor(x - info.offsetX), math.floor(y - info.offsetY)
            wx, wy = P.world.x, P.world.y
            LK.ownCalc = true
        end
    end
    if P and P.Saved then
        if wx and wy then
            P.Saved.lastPos = { zone = zone, zx = zx, zy = zy, wx = wx, wy = wy }     -- remembered for the next reload
        else
            -- MapMonster only learns where you are once you move (after a reload or zone change it knows nothing).
            -- Standing still means the old position is still right, so use the last one seen in this zone.
            local lp = P.Saved.lastPos
            if lp and zone and lp.zone == zone and lp.wx and lp.wy then
                zx, zy, wx, wy = lp.zx, lp.zy, lp.wx, lp.wy
                LK.usingLastPos = true
            end
        end
    end
    return zone, zx, zy, wx, wy
end

function LK.PlaceText(zone, zx, zy)
    if not zone then return "" end
    local zname = ZoneName(zone)
    if zx and zy then
        if PointsOfInterest and PointsOfInterest.FindNearbyPoint then
            local ok, poi = pcall(PointsOfInterest.FindNearbyPoint,
                { zoneId = zone, zoneX = zx, zoneY = zy }, true, false)
            if ok and type(poi) == "table" and poi.description then
                return tostring(poi.description) .. ", " .. zname
            end
        end
        return zname .. " (" .. zx .. "," .. zy .. ")"
    end
    return zname
end

function LK.LockText(zone)
    if not (zone and ZonepopLite and ZonepopLite.GetLockTimerText) then return "" end
    local ok, r = pcall(ZonepopLite.GetLockTimerText, zone)
    if not ok or r == nil or r == false then return "" end
    return tostring(r)
end

-- Named places of a zone: WARCommander's list when it is loaded, otherwise Pigeon's built-in list.
function LK.Points(zone)
    if not zone then return nil end
    local l = PointsOfInterest and PointsOfInterest.points and PointsOfInterest.points[zone]
    if type(l) == "table" and next(l) then return l end
    l = Pigeon and Pigeon.Places and Pigeon.Places[zone]
    if type(l) == "table" and next(l) then return l end
    return nil
end

function LK.ListPlaces(zone)
    local list = LK.Points(zone)
    if not list then return nil end
    local names = {}
    for _, poi in pairs(list) do names[#names + 1] = tostring(poi.name) end
    table.sort(names)
    return ZoneName(zone) .. ": " .. table.concat(names, ", ")
end

-- Sorted array of { name, zx, zy } for a zone, or an empty array. Used by the button bar.
function LK.PlaceList(zone)
    local out = {}
    local list = LK.Points(zone)
    if not list then return out end
    for _, poi in pairs(list) do
        if poi.zoneX and poi.zoneY then
            out[#out + 1] = { name = tostring(poi.name), zx = math.floor(poi.zoneX), zy = math.floor(poi.zoneY) }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Returns zoneX, zoneY, name  or  nil, reason
function LK.FindPlace(zone, query)
    local list = LK.Points(zone)
    if not list then return nil, "no named places known for this zone" end
    local q = string.lower(query)
    local exact, partial = nil, {}
    for _, poi in pairs(list) do
        local n = string.lower(tostring(poi.name))
        if n == q then exact = poi; break end
        if string.find(n, q, 1, true) then partial[#partial + 1] = poi end
    end
    local hit = exact or (#partial == 1 and partial[1]) or nil
    if hit and hit.zoneX and hit.zoneY then
        return math.floor(hit.zoneX), math.floor(hit.zoneY), tostring(hit.name)
    end
    if #partial > 1 then return nil, "more than one place matches" end
    return nil, "no such place here"
end

-- Map pins ---------------------------------------------------------------------
function LK.InitPins()
    LK.pinsReady = false
    if not (MapMonsterAPI and MapMonsterAPI.CreatePin and MapMonsterAPI.CreatePinType
            and MapMonsterAPI.PinTypeIsRegistered and MapMonsterAPI.ZoneToWorld) then
        LK.initError = "MapMonster API missing"
        return false, "MapMonster not found"
    end
    local ok, err = pcall(function()
        -- Remove anything left behind by a previous session or a crash.
        local old = MapMonsterAPI.GetPinsByType(LK.pinType)
        if type(old) == "table" then
            for id in pairs(old) do MapMonsterAPI.DeletePin(id) end
        end
        -- Recreate the type every session so icon size changes take effect (MapMonster remembers old ones).
        if MapMonsterAPI.DeletePinType then pcall(MapMonsterAPI.DeletePinType, LK.pinType) end
        if not MapMonsterAPI.PinTypeIsRegistered(LK.pinType) then
            if not MapMonsterAPI.CreatePinType(LK.pinType, { label = towstring("Pigeon") }, true) then
                error("CreatePinType failed, MapMonster error " .. LK.ErrCode())
            end
        end
        LK.subScale = {}
        local classic = P.Saved and P.Saved.icons == "classic"
        -- MapMonster uses the registered scale in its own editor, pin list and tooltips, where a big icon is cut off by
        -- its box; so register a normal size there and draw the real (bigger) size on the map ourselves (see the
        -- DynamicImageSetTextureScale hook).
        local function register(sub, label, slice, scale, tint, tex)
            LK.subScale[sub] = scale
            LK.subSlice[sub] = slice
            if not MapMonsterAPI.PinTypeIsRegistered(LK.pinType, sub) then
                MapMonsterAPI.CreatePinSubType(LK.pinType, sub, {
                    label = towstring(label),
                    mapIcon = { texture = tex or "map_markers01", scale = math.min(scale, 0.875), slice = slice, tint = tint },
                })
            end
        end
        for sub, def in pairs(KINDS) do
            local sc = LK.pinScale * (def.mult or 1)
            if classic then register(sub, def.label, "Waypoint-Large", sc, def.tint)
            else register(sub, def.label, def.slice, sc, def.tint, def.tex) end
        end
        -- attack lines are always green so they stand out on the map
        register("arrow", "Arrow", "Waypoint-Large", LK.arrowScale, ARROW_TINT)
        register("arrowhead", "Arrow", "Waypoint-Large", LK.arrowScale * 1.25, ARROW_TINT)
    end)
    LK.pinsReady = ok and true or false
    LK.initError = ok and nil or err
    return ok, err
end

local function DeleteIds(ids)
    if MapMonsterAPI and MapMonsterAPI.DeletePin then
        local was = LK.deleting
        LK.deleting = true
        for _, id in ipairs(ids or {}) do pcall(MapMonsterAPI.DeletePin, id) end
        LK.deleting = was
    end
end

-- Deleting ONE pin of an arrow (MapMonster's right-click Delete) deletes all five.
local function InstallHooks()
    if LK.hooksInstalled or not (MapMonsterAPI and MapMonsterAPI.DeletePin) then return end
    LK.hooksInstalled = true
    -- MapMonster bug: when the zone you LEFT has no MapMonster data (flying through an unmapped zone, a city...),
    -- its zone-change handler throws and never records the new zone, so it keeps converting your position with the
    -- OLD zone's offsets until a reload. Repair it after the fact.
    if MapMonster and type(MapMonster.OnPlayerZoneChanged) == "function" and not LK.zoneHooked then
        LK.zoneHooked = true
        local origZone = MapMonster.OnPlayerZoneChanged
        MapMonster.OnPlayerZoneChanged = function(newZoneId, ...)
            local ok, err = pcall(origZone, newZoneId, ...)
            if P and P.Saved then P.Saved.lastPos = nil end          -- a remembered position from another zone/visit is useless now
            if not ok then LK.zoneRepairs = (LK.zoneRepairs or 0) + 1; LK.RepairZone(newZoneId) end
        end
    end
    local origDelete = MapMonsterAPI.DeletePin
    MapMonsterAPI.DeletePin = function(pinId, ...)
        local group
        if not LK.deleting then
            for name, list in pairs(LK.pins) do
                for i, e in ipairs(list) do
                    for _, id in ipairs(e.ids) do
                        if id == pinId and #e.ids > 1 then group = { name = name, index = i, entry = e } end
                    end
                end
            end
        end
        local r = origDelete(pinId, ...)
        if group then
            LK.deleting = true
            for _, id in ipairs(group.entry.ids) do
                if id ~= pinId then pcall(origDelete, id) end
            end
            LK.deleting = false
            local list = LK.pins[group.name]
            if list then
                for i = #list, 1, -1 do if list[i] == group.entry then table.remove(list, i) end end
                if #list == 0 then LK.pins[group.name] = nil end
            end
        end
        return r
    end
    -- MapMonster draws every pin in a 28x28 window; a texture scaled up inside it would be cut off
    -- (that is why 2x pins showed as a quarter). Make Pigeon's pin windows as big as their icon.
    if type(CreateWindowFromTemplate) == "function" then
        local origCreate = CreateWindowFromTemplate
        CreateWindowFromTemplate = function(name, template, ...)
            local a, b = origCreate(name, template, ...)
            if template == "MapMonster_MapPin" then pcall(LK.ResizePinWindow, name); pcall(LK.ApplyPinLayer, name) end
            return a, b
        end
    end
    -- MapMonster sets a map pin's texture scale to the registered (menu-sized) one; give Pigeon's pins their real size.
    if type(DynamicImageSetTextureScale) == "function" then
        local origScale = DynamicImageSetTextureScale
        DynamicImageSetTextureScale = function(name, s, ...)
            local id = tonumber(string.match(tostring(name), "MapMonster_MapPin(%d+)$"))
            if id and MapMonsterAPI and MapMonsterAPI.GetPin then
                local ok, pin = pcall(MapMonsterAPI.GetPin, id)
                if ok and type(pin) == "table" and pin.pinType == LK.pinType and LK.subScale and LK.subScale[pin.subType] then
                    s = LK.subScale[pin.subType]
                end
            end
            return origScale(name, s, ...)
        end
    end
    -- A bigger window hangs further right/down from the spot MapMonster anchors it at, so pull it back
    -- by half the extra size to keep the icon centred where it used to be.
    if type(WindowAddAnchor) == "function" then
        local origAnchor = WindowAddAnchor
        WindowAddAnchor = function(name, point, rel, relPoint, x, y, ...)
            local extra = LK.bigPins[name]
            if extra and point == "topleft" and type(x) == "number" and type(y) == "number" then
                x, y = x - extra, y - extra
            end
            return origAnchor(name, point, rel, relPoint, x, y, ...)
        end
    end
end
LK.InstallHooks = InstallHooks

-- Real (current) pins sit on a higher layer than the temporary "look at this old order" pins, so the newest order is
-- never hidden under a historical one.
function LK.ApplyPinLayer(name)
    if not (WindowSetLayer and Window and Window.Layers) then return end
    local id = tonumber(string.match(tostring(name), "MapMonster_MapPin(%d+)$"))
    if not id or not (MapMonsterAPI and MapMonsterAPI.GetPin) then return end
    local ok, pin = pcall(MapMonsterAPI.GetPin, id)
    if not ok or type(pin) ~= "table" or pin.pinType ~= LK.pinType then return end
    local temp = LK.makingTemp
    if not temp and LK.temp then for _, tid in ipairs(LK.temp.ids) do if tid == id then temp = true end end end
    pcall(WindowSetLayer, name, temp and Window.Layers.DEFAULT or Window.Layers.SECONDARY)
end

function LK.ResizePinWindow(name)
    local id = tonumber(string.match(tostring(name), "MapMonster_MapPin(%d+)$"))
    if not id or not (MapMonsterAPI and MapMonsterAPI.GetPin) then return end
    local ok, pin = pcall(MapMonsterAPI.GetPin, id)
    if not ok or type(pin) ~= "table" or pin.pinType ~= LK.pinType then return end
    local sc = LK.subScale and LK.subScale[pin.subType]
    if not sc then return end
    local base = LK.SLICE_BASE[LK.subSlice[pin.subType] or ""] or 0.875
    local size = math.floor(28 * sc / base + 0.5)
    if size < 4 then size = 4 end
    WindowSetDimensions(name, size, size)
    LK.bigPins[name] = (size - 28) / 2           -- negative for icons smaller than the standard window
end

function LK.ClearPin(name)
    local list = LK.pins[name]
    LK.pins[name] = nil
    if list then for _, e in ipairs(list) do DeleteIds(e.ids) end end
end

function LK.ClearAllPins()
    local names = {}
    for name in pairs(LK.pins) do names[#names + 1] = name end
    for _, name in ipairs(names) do LK.ClearPin(name) end
end

-- One pin per leader: a new order or position replaces their old pin.
local function Trace(s)
    LK.trace[#LK.trace + 1] = math.floor(P.clock) .. "s: " .. tostring(s)
    if #LK.trace > 8 then table.remove(LK.trace, 1) end
end
LK.Trace = Trace

-- Every pin a leader has on your map: up to P.maxPins (5) orders/arrows at once, oldest dropped first,
-- plus one position pin that does not count. An arrow is ONE entry made of five pins.
P.maxPins = P.maxPins or 5

local function AddEntry(name, entry)
    local list = LK.pins[name]
    if not list then list = {}; LK.pins[name] = list end
    if entry.pos then
        for i = #list, 1, -1 do
            if list[i].pos then DeleteIds(list[i].ids); table.remove(list, i) end
        end
    end
    list[#list + 1] = entry
    local function count() local n = 0; for _, e in ipairs(list) do if not e.pos then n = n + 1 end end; return n end
    while count() > P.maxPins do
        for i = 1, #list do
            if not list[i].pos then DeleteIds(list[i].ids); table.remove(list, i); break end
        end
    end
end

-- Returns nil when pins can be made, otherwise the sentence to show.
local function Gate(name, label, zone, zx, zy)
    if not MapMonsterAPI then LK.lastPin = "MapMonster not found"; return "no pin, MapMonster is not installed or not loaded" end
    if not LK.pinsEnabled then LK.lastPin = "pins off"; return "pins are switched off (/pg pins on)" end
    if not LK.pinsReady then
        LK.lastPin = "no pin for " .. name .. ": MapMonster pin type was not set up"
        return "no pin, MapMonster pin type is not set up (" .. tostring(LK.initError) .. ")"
    end
    if not zone then
        LK.lastPin = "no pin for " .. name .. ": " .. tostring(label) .. " carries no place (nothing to pin)"
        return ""                                          -- placeless message (buff check, countdown...): not an error
    end
    if not (zone and zx and zy) then
        local _, _, _, pwx = LK.RawPlayerPosition()
        local hint = pwx and " - MapMonster has your position but cannot turn it into map coordinates for this zone: right-click your arrow on the world map and pick 'I am standing here'"
                          or " - MapMonster does not know where you are yet: take a few steps and press again"
        LK.lastPin = "no pin for " .. name .. ": message carries no place (" .. tostring(label) .. ")" .. hint
        return "no pin, the message names no place I know"
    end
    return nil
end

-- Finds a Pigeon pin with this label that we are not tracking yet (newest first).
function LK.AdoptOrphan(label, extra)
    if not (MapMonsterAPI and MapMonsterAPI.GetPinsByType) then return nil end
    local pins = MapMonsterAPI.GetPinsByType(LK.pinType)
    if type(pins) ~= "table" then return nil end
    local tracked = {}
    for _, list in pairs(LK.pins) do for _, e in ipairs(list) do for _, id in ipairs(e.ids) do tracked[id] = true end end end
    if LK.temp then for _, id in ipairs(LK.temp.ids) do tracked[id] = true end end
    for id in pairs(extra or {}) do tracked[id] = true end
    local best
    for id, pin in pairs(pins) do
        if not tracked[id] and tostring(pin.label) == label and (not best or id > best) then best = id end
    end
    return best
end

-- One pin. Returns id, or nil and a reason.
local function MakePin(sub, zone, zx, zy, label, extra)
    local pos = MapMonsterAPI.ZoneToWorld({ zoneId = zone, zoneX = zx, zoneY = zy })
    if type(pos) ~= "table" or not pos.worldX then
        LK.lastPin = "no map data for zone " .. tostring(zone) .. " (MapMonster error " .. LK.ErrCode() .. ")"
        return nil, "MapMonster has no map data for zone " .. tostring(zone)
    end
    local ok, id = pcall(MapMonsterAPI.CreatePin, LK.pinType, sub, towstring(label), pos, { L"Set by Pigeon" }, nil, false)
    if not ok then
        -- MiniMapMonster wraps CreatePin and throws if you have not moved yet (it needs your world
        -- position). The pin was already saved by then, so adopt it or it would never expire.
        id = LK.AdoptOrphan(label, extra)
    end
    if id then return id end
    LK.lastPin = "CreatePin failed (MapMonster error " .. LK.ErrCode() .. ")"
    return nil, "MapMonster refused it (error " .. LK.ErrCode() .. ")"
end

-- A new order from another leader pulses on the map if the world map is already open on that zone
-- (MapMonster's own highlight; it would otherwise open the map, so we only do it when it is showing).
function LK.Flash(id, zone)
    if P.Saved and P.Saved.flash == false then return "" end
    local showing = false
    pcall(function() showing = WindowGetShowing("EA_Window_WorldMap") == true end)
    if not (showing and MapMonsterAPI and MapMonsterAPI.HighlightMapPin) then return "" end
    local viewing = (PigeonMap and PigeonMap.mapZone) or (WARCommander and WARCommander.mapZoneId)
    if viewing and tonumber(viewing) ~= tonumber(zone) then return "" end
    pcall(MapMonsterAPI.HighlightMapPin, id)
    return " + flashed"
end

local function Waypoint(id)
    if LK.waypoints and MMNavigator and MMNavigator.isWPEnabled and MMNavigator.AddAsWaypoint then
        local okw = pcall(function() MMNavigator.AddAsWaypoint(MapMonsterAPI.GetPin(id)) end)
        return okw and " + waypoint set" or " (waypoint failed)"
    end
    return ""
end

-- Returns a short sentence saying what happened (shown under the order in the Pigeon window).
local function ShowPin(name, kind, zone, zx, zy, label, ttl, wp)
    local bad = Gate(name, label, zone, zx, zy)
    if bad then return bad end
    local id, why = MakePin(kind, zone, zx, zy, label)
    if not id then return "no pin, " .. why end
    AddEntry(name, { ids = { id }, expires = P.clock + ttl, pos = (kind == "position") })
    LK.lastPin = "pin " .. tostring(id) .. " for " .. name .. " at zone " .. zone .. " " .. zx .. "," .. zy
    LK.lastPinId = id
    return "pin placed on your map" .. (wp and (Waypoint(id) .. LK.Flash(id, zone)) or "")
end

-- An attack line drawn as an arrow: a stem of four pins in a straight line, and a chevron ">" of five pins
-- (the apex at the target plus two pins on each side behind it). Nine pins, kept, expired and deleted as ONE object.
local function ArrowPoints(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    local ux, uy = 1, 0
    if len > 0 then ux, uy = dx / len, dy / len end
    local wing = math.min(math.max(len * 0.22, 700), 2500)     -- length of each side of the chevron, map units
    local ang = 0.62                                           -- about 35 degrees each side
    local function side(sign, f)
        local c, sn = math.cos(sign * ang), math.sin(sign * ang)
        return x2 - wing * f * (ux * c - uy * sn), y2 - wing * f * (ux * sn + uy * c)
    end
    local function r(v) return math.max(0, math.min(70000, math.floor(v + 0.5))) end
    local pts = {}
    for i = 0, 3 do                                            -- stem: start .. just short of the apex
        pts[#pts + 1] = { r(x1 + dx * i / 4), r(y1 + dy * i / 4), "arrow" }
    end
    for _, f in ipairs({ 0.5, 1 }) do                          -- chevron sides
        local ax, ay = side(1, f)
        local bx, by = side(-1, f)
        pts[#pts + 1] = { r(ax), r(ay), "arrow" }
        pts[#pts + 1] = { r(bx), r(by), "arrow" }
    end
    pts[#pts + 1] = { r(x2), r(y2), "arrowhead" }              -- apex
    return pts
end
LK.ArrowPoints = ArrowPoints

local function ShowArrow(name, kind, zone, x1, y1, x2, y2, label, ttl, wp)
    local bad = Gate(name, label, zone, x1, y1)
    if bad then return bad end
    if not (x2 and y2) then return "no arrow, the end point is missing" end
    local ids, got, why = {}, {}, nil
    for _, pt in ipairs(ArrowPoints(x1, y1, x2, y2)) do
        local id, w = MakePin(pt[3], zone, pt[1], pt[2], label, got)
        if not id then why = w; break end
        ids[#ids + 1] = id; got[id] = true
    end
    if #ids == 0 then return "no arrow, " .. tostring(why) end
    AddEntry(name, { ids = ids, expires = P.clock + ttl })
    LK.lastPinId = ids[#ids]
    LK.lastPin = "arrow of " .. #ids .. " pins for " .. name .. " in zone " .. zone
    return "arrow placed on your map (" .. #ids .. " pins)" .. (why and (", stopped early: " .. why) or "") .. (wp and (Waypoint(ids[#ids]) .. LK.Flash(ids[#ids], zone)) or "")
end

-- The pins of one order shown temporarily (click a leader row or a history entry): same icon as the real
-- pin, an arrow as a whole arrow. Removed again once you close the world map.
function LK.ShowTempOrder(o)
    if not (o and o.zone and o.zx and o.zy) then return false, "that order has no place" end
    local bad = Gate("look", "look", o.zone, o.zx, o.zy)
    if bad then return false, bad end
    LK.ClearTemp()
    local info = o.tag and P.Tags[o.tag]
    local v = o.verb and P.Verbs[o.verb]
    local kind = (info and info.kind) or (v and v.kind) or "other"
    local label = "Pigeon: " .. tostring(o.text or (v and v.text) or "look here")
    local pts
    if o.arrow and o.zx2 and o.zy2 then pts = ArrowPoints(o.zx, o.zy, o.zx2, o.zy2) else pts = { { o.zx, o.zy, kind } } end
    local ids, got, why = {}, {}, nil
    LK.makingTemp = true
    for _, pt in ipairs(pts) do
        local ok, id, w = pcall(MakePin, pt[3], o.zone, pt[1], pt[2], label, got)
        if not ok then why = id; break end
        if not id then why = w; break end
        ids[#ids + 1] = id; got[id] = true
    end
    LK.makingTemp = false
    if #ids == 0 then return false, why end
    LK.temp = { ids = ids, born = P.clock, seen = false }
    LK.lastPinId = ids[#ids]
    if MapMonsterAPI.HighlightMapPin then
        local ok, err = pcall(MapMonsterAPI.HighlightMapPin, ids[#ids])
        if not ok then return true, "pin placed, but the map would not open itself: " .. tostring(err) end
    end
    return true
end

function LK.ShowTemp(zone, zx, zy)
    return LK.ShowTempOrder({ zone = zone, zx = zx, zy = zy, text = "look here" })
end

function LK.ClearTemp()
    if LK.temp then DeleteIds(LK.temp.ids); LK.temp = nil end
end

function LK.OpenOrder(o)
    local ok, why = LK.ShowTempOrder(o)
    if not ok and P.Print then P.Print("[map] " .. tostring(why)) end
    return ok
end

function LK.OpenAt(link)
    local zone, zx, zy = string.match(tostring(link or ""), "^PGN:(%d+),(%d+),(%d+)")
    if not zone then return false end
    local ok, why = LK.ShowTemp(tonumber(zone), tonumber(zx), tonumber(zy))
    if not ok and P.Print then P.Print("[map] " .. tostring(why)) end
    return ok
end

function LK.OnOrder(name, o)
    local kind, label
    if o.text then
        local info = o.tag and P.Tags[o.tag]
        kind = info and info.kind or "other"
        label = o.text
    else
        local v = o.verb and P.Verbs[o.verb]
        if not v then return end
        kind, label = v.kind, v.text
    end
    if string.len(label) > 40 then label = string.sub(label, 1, 40) end
    return ShowPin(name, kind, o.zone, o.zx, o.zy, name .. ": " .. label, P.expirySeconds, name ~= P.Me())
end

function LK.OnArrow(name, a)
    local info = a.tag and P.Tags[a.tag]
    local kind = info and info.kind or "move"
    local label = a.text or "Arrow"
    if string.len(label) > 40 then label = string.sub(label, 1, 40) end
    return ShowArrow(name, kind, a.zone, a.zx, a.zy, a.zx2, a.zy2, name .. ": " .. label, P.expirySeconds, name ~= P.Me())
end

-- Flash the newest pin on the map (what WARCommander's "Updates" lines do when clicked).
function LK.Highlight()
    if not (LK.lastPinId and MapMonsterAPI and MapMonsterAPI.HighlightMapPin) then return false end
    return pcall(MapMonsterAPI.HighlightMapPin, LK.lastPinId)
end

function LK.OnPos(name, p)
    ShowPin(name, "position", p.zone, p.zx, p.zy, name .. " (position)", P.posExpirySeconds)
end

-- The temporary "look at this old order" pin: gone as soon as the world map has been shown and closed again
-- (or after 15s if the map never opened, 15 min at most). Called several times a second, not every 10s.
function LK.TempTick(clock)
    local t = LK.temp
    if not t then return end
    local showing = false
    pcall(function() showing = WindowGetShowing("EA_Window_WorldMap") == true end)
    if showing then t.seen = true end
    if (t.seen and not showing) or clock - t.born > (t.seen and 900 or 15) then LK.ClearTemp() end
end

function LK.Tick(clock)
    if not LK.hooked then LK.HookWLH() end       -- WLH may finish loading after us
    local names = {}
    for name in pairs(LK.pins) do names[#names + 1] = name end
    for _, name in ipairs(names) do
        local list = LK.pins[name]
        for i = #list, 1, -1 do
            if clock > list[i].expires then DeleteIds(list[i].ids); table.remove(list, i) end
        end
        if #list == 0 then LK.pins[name] = nil end
    end
    LK.TempTick(clock)

    if LK.track and clock - lastTrack >= LK.trackInterval then
        lastTrack = clock
        P.SendPos(true)
    end
end

-- Warband Lead Helper voice relay ----------------------------------------------
-- Strip everything that could forge a second voice tag or break WLH's markup.
local function RelaySafe(s, max)
    s = tostring(s or "")
    s = string.gsub(s, "[%c<>\"%[%]{}|]", "")
    if string.len(s) > max then s = string.sub(s, 1, max) end
    return s
end

-- Sends a leader's order or message to YOUR warband. Returns a description of what happened.
function LK.Relay(o, sender)
    local text, tag
    if o.text then
        text, tag = o.text, o.tag
    else
        local v = o.verb and P.Verbs[o.verb]
        if not v then error("unknown order") end
        text, tag = v.text, v.tag
    end
    local place = LK.PlaceText(o.zone, o.zx, o.zy)
    if place ~= "" and o.zx then text = text .. " at " .. place end
    if o.eta then text = text .. " ETA " .. o.eta .. "m" end
    if o.note and o.note ~= "" then text = text .. " - " .. o.note end
    text = RelaySafe(text, 110)
    if sender and sender ~= P.Me() then text = text .. " (" .. RelaySafe(sender, 24) .. ")" end

    if wbLeadHelper and wbLeadHelper.chat then
        -- WLH reads exactly one [XX] tag, removes it from the text and attaches it to the line.
        LK.relaying = true
        local ok, err = pcall(wbLeadHelper.chat, tag and (text .. " [" .. tag .. "]") or text, "/wb")
        LK.relaying = false
        if not ok then error(err) end
        return tag and ("via Warband Lead Helper with voice tag [" .. tag .. "]") or "via Warband Lead Helper"
    end
    SendChatText(towstring("/wb " .. text), L"")
    return "plain /wb text (Warband Lead Helper not found, so no voice tag)"
end

-- Parrot: repeat what you tell your warband through Warband Lead Helper -------------
-- Every WLH button ends in wbLeadHelper.chat(message, channel, color). We wrap that one
-- function: the original always runs first and untouched, then (inside pcall, so a bug here can
-- never break WLH) the same message is repeated to the other leaders.
local function Trim(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end
local lastParrot, lastParrotAt = "", -100

-- Finds a named place of this zone (WARCommander's list) mentioned in a message, e.g. a BO name.
-- Longest name wins, so "Monastery of Morr" beats a shorter name inside it.
function LK.MatchPlace(zone, text)
    local low = string.lower(tostring(text or ""))
    local best
    for _, pl in ipairs(LK.PlaceList(zone)) do
        local n = string.lower(pl.name)
        if string.len(n) >= 4 and string.find(low, n, 1, true) and (not best or string.len(n) > string.len(best.name)) then
            best = pl
        end
    end
    return best
end


-- Battlefield objective names straight from Warband Lead Helper's own per-zone data.
-- Returns name, crossZone  (name without any "XX - " zone prefix; crossZone true if WLH listed it as another zone's BO)
local function Norm(t)
    t = string.lower(tostring(t or ""))
    t = string.gsub(t, "^the%s+", "")
    t = string.gsub(t, "[^%w]", "")
    return t
end

function LK.WlhZoneId()
    local w = wbLeadHelper
    if w then
        for _, fn in ipairs({ "GetCurrentZoneId", "getCurrentZone" }) do
            if type(w[fn]) == "function" then
                local ok, z = pcall(w[fn])
                if ok and tonumber(z) then return tonumber(z) end
            end
        end
    end
    return GameData and GameData.Player and GameData.Player.zone or nil
end

function LK.WlhBoName(zone, text)
    local w = wbLeadHelper
    if not (w and zone) then return nil end
    local lists = {}
    if type(w.BosByZoneId) == "table" and type(w.BosByZoneId[zone]) == "table" then lists[#lists + 1] = w.BosByZoneId[zone] end
    if type(w.GetMiscBoNamesForZone) == "function" then
        local ok, l = pcall(w.GetMiscBoNamesForZone, zone)
        if ok and type(l) == "table" then lists[#lists + 1] = l end
    end
    local low = string.lower(tostring(text or ""))
    local best, bestLen, cross
    for _, l in ipairs(lists) do
        for _, entry in ipairs(l) do
            local e = tostring(entry)
            local n = string.len(e)
            if n >= 4 and string.find(low, string.lower(e), 1, true) and n > (bestLen or 0) then
                best, bestLen = e, n
            end
        end
    end
    if not best then return nil end
    local plain = string.match(best, "^[%w%.' ]-%s%-%s(.+)$")
    if plain then return plain, true end
    return best, false
end

-- WARCommander place whose name matches a BO name (ignores case, punctuation, a leading "The").
function LK.PlaceByName(zone, name)
    local want = Norm(name)
    if want == "" then return nil end
    local partial
    for _, pl in ipairs(LK.PlaceList(zone)) do
        local n = Norm(pl.name)
        if n == want then return pl end
        if not partial and n ~= "" and (string.find(n, want, 1, true) or string.find(want, n, 1, true)) then partial = pl end
    end
    return partial
end

function LK.OnWlhChat(message, channel)
    if not LK.parrot then Trace("parrot is off"); return end
    if LK.relaying then return end
    if type(message) ~= "string" then return end           -- countdown ticks are numbers
    local ch = string.lower(Trim(tostring(channel or "")))
    local inWb = false
    pcall(function() inWb = IsWarBandActive() and true or false end)
    -- WLH falls back to party chat when you are not in a warband, so then /p is the leader's voice
    if ch ~= "/wb" and not (ch == "/p" and (LK.parrotParty or not inWb)) then
        Trace("ignored, channel " .. ch .. ": " .. string.sub(message, 1, 30))
        return
    end

    local clean, code = message, nil
    if wbLeadHelper.GetVoiceDirective then
        clean, code = wbLeadHelper.GetVoiceDirective(message, "/wb")
    end
    if not code then code = string.match(message, "%[(%u%u)%]") end       -- party chat: read the tag ourselves
    clean = string.gsub(tostring(clean or ""), "%s*%[%u%u%]", "")
    clean = Trim(clean)
    if clean == "" then Trace("empty message"); return end
    if clean == lastParrot and P.clock - lastParrotAt < 3 then return end    -- double click
    lastParrot, lastParrotAt = clean, P.clock

    local info = code and P.Tags[code]
    if code and not info then code = nil end
    local zone, zx, zy = LK.PlayerPosition()
    local how = "no place"
    local matched
    if info and info.loc then
        local wzone = LK.WlhZoneId() or zone
        local boName, cross = LK.WlhBoName(wzone, clean)
        local match
        if boName then
            matched = boName
            if not cross then match = LK.PlaceByName(zone, boName) end
        end
        match = match or (not boName and LK.MatchPlace(zone, clean)) or nil
        if match then
            zx, zy, how = match.zx, match.zy, "matched " .. match.name       -- the BO named in WLH's text
            matched = matched or match.name
        elseif boName and info.kind ~= "defend" then
            zx, zy, how = nil, nil, "WLH BO '" .. boName .. "' (no WARCommander coordinates)"
        elseif code == "BO" then
            zx, zy, how = nil, nil, "BO but no position known for it"          -- a BO call is never "where I stand"
        else
            how = "your position"                                              -- like WARCommander: the pin goes where you pressed
        end
    else
        zone, zx, zy = nil, nil, nil                       -- only place-related orders carry a place (so no map note either)
    end
    Trace(ch .. " [" .. tostring(code) .. "] " .. string.sub(clean, 1, 30) .. " -> " .. how)

    -- What the other leaders read: WLH's wording is long and shouty, so use a short label for the tag.
    -- Messages that carry a name or number (BO, zone, countdown) keep their own text unless a place matched.
    local text = clean
    local label = code and P.TagLabel(code)
    if label then
        if matched then
            text = label .. " - " .. matched
        elseif not P.TagKeepsText(code) then
            text = label
        end
    end
    P.SendWlh(code, text, zone, zx, zy)
end

function LK.HookWLH()
    if LK.hooked then return true end
    if not (wbLeadHelper and wbLeadHelper.chat) then return false end
    local orig = wbLeadHelper.chat
    local wrapper
    wrapper = function(message, channel, color)
        orig(message, channel, color)
        local ok, err = pcall(LK.OnWlhChat, message, channel)
        if not ok then
            LK.Trace("ERROR " .. tostring(err))
            if P.clock - (LK.lastErrLog or -100) > 10 then       -- tell the player, but not on every press
                LK.lastErrLog = P.clock
                P.Print("error while handling a WLH message (your warband still got it): " .. tostring(err))
            end
        end
    end
    LK.origChat, LK.wrapper = orig, wrapper
    wbLeadHelper.chat = wrapper
    LK.hooked = true
    return true
end

function LK.UnhookWLH()
    if LK.hooked and wbLeadHelper and wbLeadHelper.chat == LK.wrapper then
        wbLeadHelper.chat = LK.origChat
    end
    LK.hooked = false
end

-- Lifecycle / status -----------------------------------------------------------
function LK.Init()
    if P.Saved and P.Saved.pins ~= nil then LK.pinsEnabled = P.Saved.pins end
    if P.Saved and P.Saved.pinScale then LK.pinScale = P.Saved.pinScale end
    if P.Saved and P.Saved.arrowScale then LK.arrowScale = P.Saved.arrowScale end
    if P.Saved and P.Saved.waypoints ~= nil then LK.waypoints = P.Saved.waypoints end
    LK.parrot = true      -- relaying is always on at start for now (/pg parrot off lasts until the next reload)
    if P.Saved and P.Saved.parrotParty ~= nil then LK.parrotParty = P.Saved.parrotParty end
    LK.HookWLH()
    local ok, err = LK.InitPins()
    pcall(LK.InstallHooks)
    if not ok and err and err ~= "MapMonster not found" then
        Log("map pins unavailable: " .. tostring(err))
    end
end

function LK.Shutdown()
    LK.UnhookWLH()
    LK.ClearAllPins()
end

function LK.Status()
    local function yn(v) return v and "found" or "not found" end
    return {
        "Warband Lead Helper: " .. yn(wbLeadHelper and wbLeadHelper.chat)
            .. (LK.hooked and (LK.parrot and ", repeating your warband messages to leaders" or ", repeating is OFF (/pg parrot on)") or ", not hooked"),
        "MapMonster (map pins): " .. yn(MapMonsterAPI and MapMonsterAPI.CreatePin)
            .. (LK.pinsReady and ", pin type ready" or ", pins OFF")
            .. (LK.pinsEnabled and "" or " (switched off with /pg pins off)"),
        "MiniMapMonster (minimap pins): " .. yn(MiniMapMonster),
        "WARCommander (named places): " .. yn(PointsOfInterest and PointsOfInterest.points),
        "ZonepopLite (lock timers): " .. yn(ZonepopLite and ZonepopLite.GetLockTimerText),
    }
end
