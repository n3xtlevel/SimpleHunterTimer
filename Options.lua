-- Settings panel and slash commands for Simple Hunter Timer.
local ADDON, ns = ...
local SHT = ns.SHT

local panel, category, ap
local refreshers = {}

function ns.RefreshOptions()
    for _, fn in ipairs(refreshers) do fn() end
end

local function Checkbox(parent, anchor, label, tip, key, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, anchor.isCheck and -14 or -10)
    cb.isCheck = true
    cb.text = cb.text or cb.Text or cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.text:ClearAllPoints()
    cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    cb.text:SetFontObject("GameFontHighlight")
    cb.text:SetText(label)
    local note = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", cb.text, "BOTTOMLEFT", 0, -2)
    note:SetText(tip or "")
    cb:SetScript("OnClick", function(self)
        SHT.db[key] = self:GetChecked() and true or false
        if onChange then onChange(SHT.db[key]) end
    end)
    refreshers[#refreshers + 1] = function() cb:SetChecked(SHT.db[key]) end
    return cb, note
end

local sliderCount = 0
local function Slider(parent, anchor, label, key, lo, hi, step, fmt, x, y)
    sliderCount = sliderCount + 1
    local name = "SimpleHunterTimerSlider" .. sliderCount
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x or 0, y or -36)
    s:SetWidth(200)
    s:SetMinMaxValues(lo, hi)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    local low, high, text = _G[name .. "Low"], _G[name .. "High"], _G[name .. "Text"]
    if low then low:SetText(string.format(fmt, lo)) end
    if high then high:SetText(string.format(fmt, hi)) end
    local function caption(v)
        if text then text:SetText(label .. ": " .. string.format(fmt, v)) end
    end
    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        caption(v)
        if SHT.db[key] ~= v then
            SHT.db[key] = v
            SHT:ApplyLayout()
        end
    end)
    refreshers[#refreshers + 1] = function()
        s:SetValue(SHT.db[key])
        caption(SHT.db[key])
    end
    return s
end

function ns.BuildOptions()
    panel = CreateFrame("Frame")
    panel.name = "Simple Hunter Timer"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Simple Hunter Timer")

    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    sub:SetWidth(560)
    sub:SetJustifyH("LEFT")
    sub:SetText("Green: safe to move. Red zone: stand still, Auto Shot is aiming. "
        .. "Orange flash: you're delaying your shot. Grey: the shot is overdue (range, facing, ammo).")

    local lock = Checkbox(panel, sub, "Lock bar", "Unlock to drag the bar. A preview runs while it's unlocked.",
        "locked", function(v) SHT:SetLocked(v) end)
    local text = Checkbox(panel, lock, "Show text", "State on the left, seconds until the shot on the right.", "showText")
    local lat = Checkbox(panel, text, "Adjust for latency",
        "Starts the red zone earlier by your ping, so you stop moving in time.", "latency")
    local flash = Checkbox(panel, lat, "Flash when Auto Shot is delayed",
        "Flashes orange when moving or casting is holding your shot back.", "flash")
    local melee = Checkbox(panel, flash, "Show melee swing bar",
        "A small bar under the Auto Shot bar while you auto-attack in melee. Purple when Raptor Strike is queued.",
        "showMelee")
    local combat = Checkbox(panel, melee, "Always show in combat",
        "Otherwise the bar only shows while Auto Shot is on or reloading.", "showInCombat")
    local lane = Checkbox(panel, combat, "Show cast lane",
        "Thin strip above the bar. Cyan: safe for instant shots. Gold: start Aimed Shot now.", "showLane")
    local measure = Checkbox(panel, lane, "Measure abilities",
        "Times how each ability affects your next Auto Shot. See /sht report.", "measure")


    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetPoint("TOPLEFT", measure, "BOTTOMLEFT", 0, -24)
    reset:SetText("Reset position")
    reset:SetScript("OnClick", function() SHT:ResetPosition() end)

    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    help:SetPoint("TOPLEFT", reset, "BOTTOMLEFT", 0, -12)
    help:SetText("/sht  options    /sht lock | unlock | reset    /sht report    /sht resetstats")

    panel:SetScript("OnShow", ns.RefreshOptions)

    -- Appearance subpanel: size, fonts and texture.
    ap = CreateFrame("Frame")
    ap.name = "Appearance"
    ap.parent = panel.name
    local apTitle = ap:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    apTitle:SetPoint("TOPLEFT", 16, -16)
    apTitle:SetText("Simple Hunter Timer: Appearance")
    local apSub = ap:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    apSub:SetPoint("TOPLEFT", apTitle, "BOTTOMLEFT", 0, -6)
    apSub:SetWidth(560)
    apSub:SetJustifyH("LEFT")
    apSub:SetText("\"Match my UI\" uses ElvUI's or EllesmereUI's font and bar texture when one of them is loaded. "
        .. "Scroll over a setting or use the arrows to change it.")
    local w = Slider(ap, apSub, "Width", "width", 100, 500, 5, "%d", 4, -40)
    Slider(ap, apSub, "Height", "height", 8, 40, 1, "%d", 244, -40)
    local sc = Slider(ap, w, "Scale", "scale", 0.5, 2, 0.05, "%.2f")
    Slider(ap, w, "Font size", "fontSize", 6, 24, 1, "%d", 240)
    local gap = Slider(ap, sc, "Bar spacing", "spacing", 0, 10, 1, "%d")
    local _, mediaRefresh = ns.Media.AddOptions(ap, gap, function() return SHT.db end,
        function() SHT:ApplyStyle() end)
    refreshers[#refreshers + 1] = mediaRefresh
    ap:SetScript("OnShow", ns.RefreshOptions)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        if Settings.RegisterCanvasLayoutSubcategory then
            Settings.RegisterCanvasLayoutSubcategory(category, ap, ap.name)
        end
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
        InterfaceOptions_AddCategory(ap)
    end
    ns.RefreshOptions()
end

SLASH_SIMPLEHUNTERTIMER1 = "/sht"
SLASH_SIMPLEHUNTERTIMER2 = "/simplehuntertimer"
SlashCmdList.SIMPLEHUNTERTIMER = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if not SHT.db or SHT.disabled then
        print("|cff88ccffSimple Hunter Timer|r only runs on hunters.")
        return
    end
    if msg == "lock" then
        SHT:SetLocked(true)
        print("|cff88ccffSimple Hunter Timer|r locked.")
    elseif msg == "unlock" then
        SHT:SetLocked(false)
        print("|cff88ccffSimple Hunter Timer|r unlocked. Drag the bar, then /sht lock.")
    elseif msg == "report" then
        ns.Report()
    elseif msg == "resetstats" then
        ns.ResetStats()
        print("|cff88ccffSimple Hunter Timer|r measurements cleared.")
    elseif msg == "reset" then
        SHT:ResetPosition()
        print("|cff88ccffSimple Hunter Timer|r position reset.")
    elseif category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    elseif panel and InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end
