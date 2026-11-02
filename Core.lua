-- Simple Hunter Timer: an Auto Shot timer for Classic Era hunters.
--
-- How Auto Shot works on the classic client:
--   * Each shot cycle lasts your hasted ranged speed (UnitRangedDamage).
--   * The cycle is a reload (speed - 0.5 s) followed by a fixed 0.5 s aim.
--   * Moving or casting during the reload is free. Moving or casting during the
--     aim pauses it, and the full 0.5 s aim starts over once you stand still again.
-- The bar fills over the whole cycle. The red zone at the end is the aim, widened
-- by your latency, so "stop moving now" is shown a little early.

local ADDON, ns = ...

local SHT = {}
ns.SHT = SHT
_G.SimpleHunterTimer = SHT

local GetTime, GetUnitSpeed, IsFalling = GetTime, GetUnitSpeed, IsFalling
local UnitCastingInfo, UnitChannelInfo = UnitCastingInfo, UnitChannelInfo
local UnitRangedDamage, UnitAttackSpeed = UnitRangedDamage, UnitAttackSpeed
local GetNetStats, InCombatLockdown = GetNetStats, InCombatLockdown
local max, min, floor, sin, abs = math.max, math.min, math.floor, math.sin, math.abs

local AUTO_SHOT_ID = 75
local AIMED_SHOT_ID = 19434
local RAPTOR_STRIKE_ID = 2973
local AIM_TIME = 0.5
local RESET_WINDOW = 0.5 -- the "cast Aimed Shot now" window right after a shot
ns.AIM_TIME = AIM_TIME
local WAIT_GRACE = 0.3 -- extra time past the expected shot before we call it "waiting"

local DB_VERSION = 1
local defaults = {
    version = DB_VERSION,
    locked = false,
    pos = { point = "CENTER", relPoint = "CENTER", x = 0, y = -180 },
    width = 220,
    height = 18,
    scale = 1,
    showText = true,
    latency = true,
    flash = true,
    showMelee = true,
    showInCombat = false,
    showLane = true,
    measure = true,
    font = "auto",
    fontSize = 11,
    outline = "OUTLINE",
    texture = "auto",
    spacing = 0, -- gap in pixels between bars; 0 = flush (borders shared)
}

ns.colors = {
    reload = { 0.30, 0.80, 0.35 }, -- safe: move and cast freely
    aim    = { 0.90, 0.25, 0.20 }, -- stand still
    held   = { 1.00, 0.60, 0.10 }, -- you are delaying the shot
    wait   = { 0.55, 0.55, 0.55 }, -- shot overdue (out of range, not facing, no ammo...)
    ready  = { 0.35, 0.60, 0.95 }, -- reloaded, Auto Shot is off
    melee  = { 0.80, 0.80, 0.80 },
    raptor = { 0.75, 0.40, 1.00 }, -- Raptor Strike queued
}

local LABELS = {
    reload = "Move",
    aim = "Hold still",
    held = "Delayed!",
    wait = "Waiting",
    ready = "Ready",
}

-- Ranged and melee timer state.
local R = {
    lastShot = 0, speed = 0, active = false, aimStart = nil, heldAt = 0, clipUntil = 0,
    -- for measuring (Measure.lua)
    moveHeldAt = 0, autoOnAt = 0, cycleDirty = false, lastWasAimed = false, sample = nil,
}
ns.R = R
local M = { last = 0, speed = 0, active = false }

local playerGUID
local autoShotName, aimedShotName, raptorName

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function Latency()
    if not SHT.db.latency then return 0 end
    local _, _, home, world = GetNetStats()
    local ms = max(world or 0, home or 0)
    return min(ms, 500) / 1000
end

local function IsCastingSomething()
    local name = UnitCastingInfo("player")
    if name and name ~= autoShotName then return true end
    name = UnitChannelInfo("player")
    if name then return true end
    return false
end

local function IsMoving()
    return (GetUnitSpeed("player") or 0) > 0 or IsFalling()
end

----------------------------------------------------------------------------
-- Bars
----------------------------------------------------------------------------
local TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

local function CreateBar(parent)
    local f = CreateFrame("Frame", nil, parent)

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0, 0, 0, 0.6)

    f.zone = f:CreateTexture(nil, "BORDER")
    f.zone:SetColorTexture(0.9, 0.2, 0.2, 0.35)
    f.zone:SetPoint("TOPRIGHT")
    f.zone:SetPoint("BOTTOMRIGHT")

    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetTexture(TEXTURE)
    f.fill:SetPoint("TOPLEFT")
    f.fill:SetPoint("BOTTOMLEFT")

    f.flash = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.flash:SetAllPoints()
    f.flash:SetColorTexture(1, 0.6, 0.1, 0)

    f.mark = f:CreateTexture(nil, "OVERLAY")
    f.mark:SetColorTexture(1, 1, 1, 0.9)
    f.mark:SetWidth(2)
    f.mark:SetPoint("TOP")
    f.mark:SetPoint("BOTTOM")

    f.spark = f:CreateTexture(nil, "OVERLAY", nil, 1)
    f.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    f.spark:SetBlendMode("ADD")
    f.spark:SetWidth(16)

    -- 1px black border
    f.borders = {}
    for _, spec in ipairs({ { "TOPLEFT", "TOPRIGHT", 0, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", 0, -1 } }) do
        local t = f:CreateTexture(nil, "OVERLAY", nil, 3)
        t:SetColorTexture(0, 0, 0, 1)
        t:SetPoint(spec[1], -1, spec[4])
        t:SetPoint(spec[2], 1, spec[4])
        t:SetHeight(1)
        f.borders[#f.borders + 1] = t
    end
    for _, spec in ipairs({ { "TOPLEFT", "BOTTOMLEFT", -1 }, { "TOPRIGHT", "BOTTOMRIGHT", 1 } }) do
        local t = f:CreateTexture(nil, "OVERLAY", nil, 3)
        t:SetColorTexture(0, 0, 0, 1)
        t:SetPoint(spec[1], spec[3], 1)
        t:SetPoint(spec[2], spec[3], -1)
        t:SetWidth(1)
        f.borders[#f.borders + 1] = t
    end

    f.left = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.left:SetPoint("LEFT", 4, 0)
    f.right = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.right:SetPoint("RIGHT", -4, 0)
    for _, fs in ipairs({ f.left, f.right }) do
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    end

    f:Hide()
    return f
end

local function SetFill(bar, frac, color)
    frac = max(0, min(frac or 0, 1))
    local w = bar:GetWidth() * frac
    if w < 0.5 then
        bar.fill:Hide()
    else
        bar.fill:Show()
        bar.fill:SetWidth(w)
        bar.fill:SetTexCoord(0, frac, 0, 1)
    end
    bar.fill:SetVertexColor(color[1], color[2], color[3])
    bar.spark:ClearAllPoints()
    bar.spark:SetPoint("CENTER", bar, "LEFT", w, 0)
    bar.spark:SetShown(frac > 0 and frac < 1)
end

local function SetZone(bar, frac)
    if not frac then
        bar.zone:Hide()
        bar.mark:Hide()
        return
    end
    frac = max(0, min(frac, 1))
    local w = bar:GetWidth()
    bar.zone:Show()
    bar.zone:SetWidth(max(w * (1 - frac), 1))
    bar.mark:Show()
    bar.mark:ClearAllPoints()
    bar.mark:SetPoint("TOP", bar, "TOPLEFT", w * frac, 0)
    bar.mark:SetPoint("BOTTOM", bar, "BOTTOMLEFT", w * frac, 0)
end

local function SetTexts(bar, left, right)
    if SHT.db.showText then
        bar.left:SetText(left or "")
        bar.right:SetText(right and string.format("%.1f", right) or "")
    else
        bar.left:SetText("")
        bar.right:SetText("")
    end
end

local function SetFlash(bar, on, now)
    if on and SHT.db.flash then
        bar.flash:SetAlpha(0.20 + 0.20 * sin(now * 14))
    else
        bar.flash:SetAlpha(0)
    end
end

----------------------------------------------------------------------------
-- Ranged (Auto Shot) logic
----------------------------------------------------------------------------
local function CurrentRangedSpeed()
    local s = UnitRangedDamage("player")
    return (s and s > 0) and s or 0
end

-- Returns fill (0..1), state, seconds until the shot (or nil), aim-zone start (0..1).
local function RangedState(now)
    local speed = R.speed > 0 and R.speed or CurrentRangedSpeed()
    if speed <= 0 then return nil end
    local reload = max(speed - AIM_TIME, 0)
    local reloadEnd = R.lastShot + reload
    local lat = Latency()
    local zone = max(reload - lat, 0) / speed

    if now < reloadEnd then
        local state = (now < reloadEnd - lat) and "reload" or "aim"
        return (now - R.lastShot) / speed, state, reloadEnd + AIM_TIME - now, zone
    end

    if not R.active then
        return reload / speed, "ready", nil, zone
    end

    local moving = IsMoving()
    if moving or IsCastingSomething() then
        R.aimStart = nil
        R.heldAt = now
        if moving then R.moveHeldAt = now end
        return reload / speed, "held", AIM_TIME, zone
    end

    if not R.aimStart then
        R.aimStart = max(reloadEnd, R.heldAt)
    end
    local t = now - R.aimStart
    if t <= AIM_TIME + WAIT_GRACE + lat then
        return (reload + min(t, AIM_TIME)) / speed, "aim", max(AIM_TIME - t, 0), zone
    end
    return 1, "wait", nil, zone
end

local function OnShot(now)
    R.lastShot = now
    R.speed = CurrentRangedSpeed()
    R.aimStart = nil
    R.heldAt = 0
    R.clipUntil = 0
    R.moveHeldAt = 0
    R.autoOnAt = 0
    R.cycleDirty = false
    R.lastWasAimed = false
    R.sample = nil
end

-- Restarts the cycle without a shot (Aimed Shot, or an ability measured as a reset).
local function RestartCycle(now)
    OnShot(now)
    R.lastWasAimed = true -- the next shot can't be compared cleanly
end

----------------------------------------------------------------------------
-- Cast lane: a thin strip above the bar.
--   cyan: safe to use instant shots (dim once you're past the cutoff)
--   gold: right after a shot, the moment to start Aimed Shot (or any ability
--         measured as restarting the timer)
----------------------------------------------------------------------------
local hasResetSpell = false
local function UpdateResetSpells()
    hasResetSpell = (aimedShotName and GetSpellInfo(aimedShotName)) and true or false
    if next(ns.resetSet or {}) then hasResetSpell = true end
end
ns.UpdateResetSpells = UpdateResetSpells

local function CreateLane(parent)
    local l = CreateFrame("Frame", nil, parent)
    l.bg = l:CreateTexture(nil, "BACKGROUND")
    l.bg:SetAllPoints()
    l.bg:SetColorTexture(0, 0, 0, 0.55)
    l.safe = l:CreateTexture(nil, "ARTWORK")
    l.safe:SetColorTexture(0.20, 0.85, 1.00, 1)
    l.safe:SetPoint("TOPLEFT")
    l.safe:SetPoint("BOTTOMLEFT")
    l.gold = l:CreateTexture(nil, "ARTWORK", nil, 1)
    l.gold:SetColorTexture(1.00, 0.82, 0.10, 1)
    l.gold:SetPoint("TOPLEFT")
    l.gold:SetPoint("BOTTOMLEFT")
    l.tick = l:CreateTexture(nil, "OVERLAY")
    l.tick:SetColorTexture(1, 1, 1, 1)
    l.tick:SetWidth(2)
    l:Hide()
    return l
end

-- cut, gold: fractions of the cycle. fill: where we are now.
local function DrawLane(cut, gold, fill)
    local lane = SHT.lane
    if not SHT.db.showLane then
        lane:Hide()
        return
    end
    lane:Show()
    local w = lane:GetWidth()
    cut = max(0, min(cut, 1))
    lane.safe:SetWidth(max(w * cut, 1))
    lane.safe:SetAlpha(fill < cut and 0.95 or 0.25)
    if gold and gold > 0 then
        lane.gold:Show()
        lane.gold:SetWidth(max(w * min(gold, 1), 1))
        lane.gold:SetAlpha(fill < gold and 1 or 0.3)
    else
        lane.gold:Hide()
    end
    lane.tick:ClearAllPoints()
    lane.tick:SetPoint("TOP", lane, "TOPLEFT", w * max(0, min(fill, 1)), 0)
    lane.tick:SetPoint("BOTTOM", lane, "BOTTOMLEFT", w * max(0, min(fill, 1)), 0)
end

----------------------------------------------------------------------------
-- Update loop
----------------------------------------------------------------------------
local function UpdateRanged(now)
    local bar = SHT.ranged
    local db = SHT.db

    -- Unlocked with nothing going on: run a preview so the bar can be placed.
    local speed = R.speed > 0 and R.speed or CurrentRangedSpeed()
    local busy = R.active or (speed > 0 and now < R.lastShot + speed)
        or (db.showInCombat and InCombatLockdown())
    if not busy then
        if db.locked then
            bar:Hide()
            SHT.lane:Hide()
            return
        end
        local s = 3
        local t = now % s
        local reload = s - AIM_TIME
        local state = t < reload and "reload" or "aim"
        bar:Show()
        SetFill(bar, t / s, ns.colors[state])
        SetZone(bar, reload / s)
        SetTexts(bar, "Simple Hunter Timer (drag me)", s - t)
        SetFlash(bar, false, now)
        DrawLane(reload / s, RESET_WINDOW / s, t / s)
        return
    end

    local fill, state, remaining, zone = RangedState(now)
    if not fill then
        bar:Hide()
        SHT.lane:Hide()
        return
    end
    bar:Show()
    SetFill(bar, fill, ns.colors[state])
    SetZone(bar, zone)
    SetTexts(bar, LABELS[state], remaining)
    SetFlash(bar, state == "held" or now < R.clipUntil, now)

    -- Cast lane. Instants are safe until the aim (or all the way through it, once
    -- measured as harmless there). The gold window is right after the shot.
    local reloadFrac = max(speed - AIM_TIME, 0) / speed
    local cut = ns.aimSafe and 1 or zone
    local gold = hasResetSpell and min(RESET_WINDOW / speed, reloadFrac) or nil
    DrawLane(cut, gold, (now - R.lastShot) / speed)
end

local function UpdateMelee(now)
    local bar = SHT.melee
    local db = SHT.db
    if not db.showMelee then
        bar:Hide()
        return
    end
    if not M.active or M.last == 0 then
        if db.locked or R.active then
            bar:Hide()
            return
        end
        -- preview while unlocked
        local t = now % 2.6
        bar:Show()
        SetFill(bar, t / 2.6, ns.colors.melee)
        SetZone(bar, nil)
        SetTexts(bar, "Melee", 2.6 - t)
        return
    end
    local speed = M.speed > 0 and M.speed or (UnitAttackSpeed("player") or 0)
    if speed <= 0 then
        bar:Hide()
        return
    end
    local t = now - M.last
    if t > speed + 2 then
        bar:Hide()
        return
    end
    local queued = false
    if raptorName and IsCurrentSpell then
        local ok, q = pcall(IsCurrentSpell, raptorName)
        queued = ok and q and true or false
    end
    bar:Show()
    SetFill(bar, t / speed, queued and ns.colors.raptor or ns.colors.melee)
    SetZone(bar, nil)
    SetTexts(bar, queued and "Raptor Strike" or "Melee", max(speed - t, 0))
end

local function OnUpdate()
    local now = GetTime()
    UpdateRanged(now)
    UpdateMelee(now)
end

----------------------------------------------------------------------------
-- Layout / positioning
----------------------------------------------------------------------------
function SHT:SavePosition()
    local point, _, relPoint, x, y = self.anchor:GetPoint(1)
    local p = self.db.pos
    p.point, p.relPoint, p.x, p.y = point, relPoint, floor(x + 0.5), floor(y + 0.5)
end

function SHT:ApplyLayout()
    local db, a = self.db, self.anchor
    a:SetScale(db.scale)
    a:SetSize(db.width, db.height)
    a:ClearAllPoints()
    a:SetPoint(db.pos.point, UIParent, db.pos.relPoint, db.pos.x, db.pos.y)
    a:EnableMouse(not db.locked)

    self.ranged:SetAllPoints(a)
    self.ranged.spark:SetHeight(db.height * 2.2)

    local lh = max(floor(db.height * 0.3 + 0.5), 3)
    self.lane:ClearAllPoints()
    self.lane:SetPoint("BOTTOMLEFT", a, "TOPLEFT", 0, 1 + db.spacing)
    self.lane:SetPoint("BOTTOMRIGHT", a, "TOPRIGHT", 0, 1 + db.spacing)
    self.lane:SetHeight(lh)

    local mh = max(floor(db.height * 0.6 + 0.5), 6)
    self.melee:ClearAllPoints()
    self.melee:SetPoint("TOPLEFT", a, "BOTTOMLEFT", 0, -(1 + db.spacing))
    self.melee:SetPoint("TOPRIGHT", a, "BOTTOMRIGHT", 0, -(1 + db.spacing))
    self.melee:SetHeight(mh)
    self.melee.spark:SetHeight(mh * 2.2)
    self:ApplyStyle()
end

function SHT:ApplyStyle()
    if not self.anchor or not ns.Media then return end
    ns.Media.Style({ [SHT.ranged] = 1, [SHT.melee] = 0.9 }, self.db)
end

function SHT:SetLocked(locked)
    self.db.locked = locked and true or false
    self:ApplyLayout()
    if ns.RefreshOptions then ns.RefreshOptions() end
end

function SHT:ResetPosition()
    self.db.pos = { point = "CENTER", relPoint = "CENTER", x = 0, y = -180 }
    self:ApplyLayout()
end

local function BuildUI()
    local a = CreateFrame("Frame", "SimpleHunterTimerAnchor", UIParent)
    a:SetMovable(true)
    a:SetClampedToScreen(true)
    a:RegisterForDrag("LeftButton")
    a:SetScript("OnDragStart", function(self)
        if not SHT.db.locked then self:StartMoving() end
    end)
    a:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SHT:SavePosition()
    end)
    SHT.anchor = a
    SHT.ranged = CreateBar(a)
    SHT.melee = CreateBar(a)
    SHT.lane = CreateLane(a)
    SHT:ApplyLayout()
    a:SetScript("OnUpdate", OnUpdate)
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------
local ev = CreateFrame("Frame")
local handlers = {}

function handlers.PLAYER_LOGIN()
    local _, class = UnitClass("player")
    SimpleHunterTimerDB = SimpleHunterTimerDB or {}
    CopyDefaults(defaults, SimpleHunterTimerDB)
    SHT.db = SimpleHunterTimerDB
    if class ~= "HUNTER" then
        SHT.disabled = true
        return
    end

    playerGUID = UnitGUID("player")
    autoShotName = GetSpellInfo(AUTO_SHOT_ID)
    aimedShotName = GetSpellInfo(AIMED_SHOT_ID)
    raptorName = GetSpellInfo(RAPTOR_STRIKE_ID)

    R.speed = CurrentRangedSpeed()
    if autoShotName and IsAutoRepeatSpell then
        R.active = IsAutoRepeatSpell(autoShotName) and true or false
    end
    M.speed = UnitAttackSpeed("player") or 0

    if ns.RefreshVerdicts then ns.RefreshVerdicts() end
    UpdateResetSpells()
    BuildUI()
    -- ElvUI and other media addons can finish setting up after us: restyle once
    -- everything has loaded, and whenever new fonts or textures are registered.
    local function restyle() SHT:ApplyStyle() end
    if ns.Media then ns.Media.Watch(restyle) end
    if C_Timer and C_Timer.After then C_Timer.After(1, restyle) end

    ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    ev:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
    ev:RegisterUnitEvent("UNIT_RANGEDDAMAGE", "player")
    ev:RegisterUnitEvent("UNIT_ATTACK_SPEED", "player")
    ev:RegisterEvent("START_AUTOREPEAT_SPELL")
    ev:RegisterEvent("STOP_AUTOREPEAT_SPELL")
    ev:RegisterEvent("PLAYER_ENTER_COMBAT")
    ev:RegisterEvent("PLAYER_LEAVE_COMBAT")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    ev:RegisterEvent("SPELLS_CHANGED")

    if ns.BuildOptions then ns.BuildOptions() end
end

function handlers.PLAYER_ENTERING_WORLD()
    R.aimStart, R.heldAt, R.clipUntil = nil, GetTime(), 0
    R.speed = CurrentRangedSpeed()
    R.cycleDirty = true
    M.active = false
end

function handlers.SPELLS_CHANGED() UpdateResetSpells() end

function handlers.UNIT_SPELLCAST_SUCCEEDED(_, _, _, spellID)
    local now = GetTime()
    if spellID == AUTO_SHOT_ID then
        if ns.MeasureShot then ns.MeasureShot(now) end
        OnShot(now)
        return
    end
    local name = GetSpellInfo(spellID)
    if aimedShotName and name == aimedShotName then
        -- Aimed Shot replaces the Auto Shot and restarts the cycle.
        RestartCycle(now)
        return
    end
    if ns.MeasureSpell then ns.MeasureSpell(now, name) end
    if name and ns.resetSet and ns.resetSet[name] and R.active then
        -- Measured on this client as restarting the Auto Shot timer.
        RestartCycle(now)
    end
end

function handlers.UNIT_SPELLCAST_START()
    -- Warn when a cast will run into the aim and push the next Auto Shot back.
    if not R.active then return end
    local name, _, _, _, endMS = UnitCastingInfo("player")
    if not name or name == autoShotName or name == aimedShotName then return end
    local speed = R.speed > 0 and R.speed or CurrentRangedSpeed()
    local reloadEnd = R.lastShot + max(speed - AIM_TIME, 0)
    local castEnd = (endMS or 0) / 1000
    if castEnd > reloadEnd then
        R.clipUntil = castEnd
    end
end

function handlers.UNIT_RANGEDDAMAGE()
    -- Haste changed mid-cycle (Rapid Fire, Quick Shots...): keep the same
    -- progress through the cycle at the new speed.
    local now, new = GetTime(), CurrentRangedSpeed()
    if new <= 0 then return end
    local old = R.speed
    if old > 0 and now < R.lastShot + max(old - AIM_TIME, 0) then
        local progress = (now - R.lastShot) / old
        R.lastShot = now - progress * new
    end
    if abs(new - old) > 0.001 then R.cycleDirty = true end
    R.speed = new
end

function handlers.UNIT_ATTACK_SPEED()
    local now, new = GetTime(), UnitAttackSpeed("player") or 0
    if new <= 0 then return end
    local old = M.speed
    if old > 0 and M.last > 0 and now < M.last + old then
        local progress = (now - M.last) / old
        M.last = now - progress * new
    end
    M.speed = new
end

function handlers.START_AUTOREPEAT_SPELL()
    R.active = true
    R.aimStart = nil
    R.heldAt = GetTime() -- the aim can't start before Auto Shot was turned on
    R.autoOnAt = R.heldAt
end

function handlers.STOP_AUTOREPEAT_SPELL()
    R.active = false
    R.aimStart = nil
    R.cycleDirty = true
end

function handlers.PLAYER_ENTER_COMBAT() M.active = true end
function handlers.PLAYER_LEAVE_COMBAT() M.active = false end

function handlers.COMBAT_LOG_EVENT_UNFILTERED()
    if not SHT.db.showMelee then return end
    local _, sub, _, src, _, _, _, _, _, _, _, a12, a13, _, _, _, _, _, _, _, a21 =
        CombatLogGetCurrentEventInfo()
    if src ~= playerGUID then return end
    local offhand
    if sub == "SWING_DAMAGE" then
        offhand = a21
    elseif sub == "SWING_MISSED" then
        offhand = a13
    elseif (sub == "SPELL_DAMAGE" or sub == "SPELL_MISSED") and raptorName and a13 == raptorName then
        offhand = false
    else
        return
    end
    if offhand then return end
    M.last = GetTime()
    M.speed = UnitAttackSpeed("player") or M.speed
end

ev:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if h then h(event, ...) end
end)
ev:RegisterEvent("PLAYER_LOGIN")
