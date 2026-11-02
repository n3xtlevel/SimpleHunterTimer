-- Measures how each ability affects Auto Shot on this client.
--
-- For every Auto Shot cycle we know when the shot *should* fire: the end of the
-- reload, pushed back only by movement during the aim or by Auto Shot being
-- turned on late, plus the 0.5 s aim. When the shot actually fires we compare.
--   * Cycles with no ability used give the baseline (latency and event jitter).
--   * Cycles with exactly one ability used are filed under that ability, split by
--     whether it was used during the reload or during the aim.
--   * If the shot lands one full weapon speed after the ability, the ability
--     restarted the timer ("reset").
-- Cycles where haste changed, Auto Shot was toggled off, or Aimed Shot fired are
-- thrown away, since they can't be compared cleanly.

local ADDON, ns = ...
local SHT = ns.SHT
local R = ns.R

local abs, max = math.abs, math.max

local MIN_SAMPLES = 3
local THRESHOLD = 0.1 -- seconds later than baseline that counts as a delay
local DECISIVE = 0.2 -- how far apart "reset" and "normal" must be to tell them apart

local function Store()
    local db = SHT.db
    db.stats = db.stats or {}
    local s = db.stats
    s.baseline = s.baseline or { n = 0, sum = 0 }
    s.spells = s.spells or {}
    return s
end

local function Bucket(name, phase)
    local spells = Store().spells
    spells[name] = spells[name] or {}
    local b = spells[name][phase]
    if not b then
        b = { n = 0, sum = 0, reset = 0 }
        spells[name][phase] = b
    end
    return b
end

-- Called when an ability (anything but Auto Shot and Aimed Shot) succeeds.
function ns.MeasureSpell(now, name)
    if not SHT.db.measure or not R.active or R.lastShot <= 0 or not name then return end
    if R.sample then
        R.sample.mixed = true
        return
    end
    local reloadEnd = R.lastShot + max(R.speed - ns.AIM_TIME, 0)
    R.sample = { name = name, t = now, phase = (now < reloadEnd) and "reload" or "aim" }
end

-- Called when Auto Shot fires, before the cycle is reset.
function ns.MeasureShot(now)
    if not SHT.db.measure then return end
    local speed = R.speed
    if R.lastShot <= 0 or speed <= 0 or R.cycleDirty or R.lastWasAimed then return end
    if now - R.lastShot > speed + 5 then return end -- Auto Shot was off for a while

    local reloadEnd = R.lastShot + max(speed - ns.AIM_TIME, 0)
    local expected = max(reloadEnd, R.moveHeldAt, R.autoOnAt) + ns.AIM_TIME
    local delay = now - expected
    if delay < -1 or delay > 4 then return end

    local sample = R.sample
    if not sample then
        local b = Store().baseline
        b.n, b.sum = b.n + 1, b.sum + delay
        return
    end
    if sample.mixed then return end

    -- If the ability restarted the timer, the shot would land one weapon speed
    -- after it. When that's too close to the normal time to tell apart (used
    -- right after a shot), the sample can't decide anything, so skip it.
    local resetTime = sample.t + speed
    if sample.phase == "reload" and resetTime - expected < DECISIVE then return end
    local b = Bucket(sample.name, sample.phase)
    b.n, b.sum = b.n + 1, b.sum + delay
    if sample.phase == "reload" and abs(now - resetTime) < abs(now - expected) then
        b.reset = b.reset + 1
    end
    ns.RefreshVerdicts()
end

local function Baseline()
    local b = Store().baseline
    if b.n >= 5 then return b.sum / b.n, b.n end
    return 0.05, b.n
end

-- Returns a verdict table for one ability, or nil if there's not enough data.
--   reload: "safe" | "resets" | "delays" | nil
--   aim:    "safe" | "delays" | nil, and aimDelay (seconds)
function ns.Verdict(name)
    local data = Store().spells[name]
    if not data then return nil end
    local base = Baseline()
    local v = {}
    local r = data.reload
    if r and r.n >= MIN_SAMPLES then
        if r.reset / r.n >= 0.6 then
            v.reload = "resets"
        elseif r.sum / r.n - base < THRESHOLD then
            v.reload = "safe"
        else
            v.reload = "delays"
        end
        v.reloadN = r.n
        v.reloadDelay = r.sum / r.n - base
    end
    local a = data.aim
    if a and a.n >= MIN_SAMPLES then
        v.aimDelay = a.sum / a.n - base
        v.aim = v.aimDelay < THRESHOLD and "safe" or "delays"
        v.aimN = a.n
    end
    return v
end

-- Spells measured as restarting the Auto Shot timer.
function ns.ResetSpells()
    local out = {}
    for name in pairs(Store().spells) do
        local v = ns.Verdict(name)
        if v and v.reload == "resets" then out[#out + 1] = name end
    end
    return out
end

-- True once at least one ability has aim-phase data and none of them delay the shot.
function ns.InstantsSafeWhileAiming()
    local any = false
    for name in pairs(Store().spells) do
        local v = ns.Verdict(name)
        if v and v.aim then
            if v.aim ~= "safe" then return false end
            any = true
        end
    end
    return any
end

local function fmt(n) return string.format("%.2f s", n) end

function ns.Report()
    local p = function(msg) print("|cff88ccffSHT|r " .. msg) end
    local base, bn = Baseline()
    p(string.format("Auto Shot report. Baseline: %d clean shots, average %s late (that's your latency).", bn, fmt(base)))
    local names = {}
    for name in pairs(Store().spells) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        p("No abilities measured yet. Fight with Auto Shot on and use your shots as usual.")
        return
    end
    for _, name in ipairs(names) do
        local data = Store().spells[name]
        local v = ns.Verdict(name) or {}
        local parts = {}
        local rn = data.reload and data.reload.n or 0
        local an = data.aim and data.aim.n or 0
        if v.reload == "resets" then
            parts[#parts + 1] = "|cffffd100restarts the timer|r (use right after a shot)"
        elseif v.reload == "safe" then
            parts[#parts + 1] = "|cff55ff55safe while reloading|r"
        elseif v.reload == "delays" then
            parts[#parts + 1] = "|cffff5555delays the shot " .. fmt(v.reloadDelay) .. " even while reloading|r"
        else
            parts[#parts + 1] = string.format("reloading: %d/%d uses so far", rn, MIN_SAMPLES)
        end
        if v.aim == "safe" then
            parts[#parts + 1] = "|cff55ff55no effect while aiming|r"
        elseif v.aim == "delays" then
            parts[#parts + 1] = "|cffff5555pushes the shot back " .. fmt(v.aimDelay) .. " while aiming|r"
        else
            parts[#parts + 1] = string.format("aiming: %d/%d uses so far", an, MIN_SAMPLES)
        end
        p(name .. ": " .. table.concat(parts, ", "))
    end
    p("Only fights where you used one ability per shot count. /sht resetstats clears this.")
end

function ns.ResetStats()
    SHT.db.stats = nil
    Store()
    ns.RefreshVerdicts()
end

-- Cached verdicts used by the cast lane. Refreshed after each measured shot.
ns.resetSet, ns.aimSafe = {}, false
function ns.RefreshVerdicts()
    local set = {}
    for _, name in ipairs(ns.ResetSpells()) do set[name] = true end
    ns.resetSet = set
    ns.aimSafe = ns.InstantsSafeWhileAiming()
    if ns.UpdateResetSpells then ns.UpdateResetSpells() end
end
