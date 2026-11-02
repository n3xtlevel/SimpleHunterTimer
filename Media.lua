-- Fonts and bar textures for the Simple Timers addons.
-- "Match my UI" (auto) uses ElvUI's or EllesmereUI's choices when one of them is
-- loaded. Otherwise any font or texture registered with LibSharedMedia can be picked.
local ADDON, ns = ...

local Media = {}
ns.Media = Media

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
Media.LSM = LSM

Media.AUTO = "auto"
Media.DEFAULT_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
Media.OUTLINES = { "NONE", "OUTLINE", "THICKOUTLINE" }
Media.OUTLINE_LABELS = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick outline" }

local function ElvUIMedia()
    local E = type(_G.ElvUI) == "table" and _G.ElvUI[1]
    if type(E) == "table" and type(E.media) == "table" then
        return E.media, (type(E.db) == "table" and E.db.general) or nil
    end
end

-- Returns path, description of where it came from.
function Media.AutoFont()
    local m, g = ElvUIMedia()
    if m and m.normFont then
        return m.normFont, "ElvUI" .. ((g and g.font) and (": " .. g.font) or "")
    end
    local EUI = _G.EllesmereUI
    if type(EUI) == "table" and EUI.GetFontPath then
        local ok, path = pcall(EUI.GetFontPath)
        if ok and type(path) == "string" and path ~= "" then
            local okName, name = pcall(EUI.GetFontName or function() end)
            return path, "EllesmereUI" .. ((okName and name) and (": " .. name) or "")
        end
    end
    return STANDARD_TEXT_FONT, "Blizzard"
end

function Media.AutoTexture()
    local m, g = ElvUIMedia()
    if m and m.normTex then
        local name = type(_G.ElvUI[1].private) == "table" and _G.ElvUI[1].private.general
            and _G.ElvUI[1].private.general.normTex
        return m.normTex, "ElvUI" .. (name and (": " .. name) or "")
    end
    return Media.DEFAULT_TEXTURE, "Blizzard"
end

function Media.Font(name)
    if name and name ~= Media.AUTO and LSM then
        local path = LSM:Fetch("font", name, true)
        if path then return path end
    end
    return (Media.AutoFont())
end

function Media.Texture(name)
    if name and name ~= Media.AUTO and LSM then
        local path = LSM:Fetch("statusbar", name, true)
        if path then return path end
    end
    return (Media.AutoTexture())
end

-- Sorted names for kind ("font" or "statusbar"), with "auto" first.
function Media.List(kind)
    local out = { Media.AUTO }
    if LSM then
        for _, name in ipairs(LSM:List(kind)) do out[#out + 1] = name end
    end
    return out
end

function Media.Label(kind, name)
    if name == Media.AUTO then
        local _, src = (kind == "font" and Media.AutoFont or Media.AutoTexture)()
        return "Match my UI (" .. src .. ")"
    end
    return name
end

-- Applies the saved font/texture to bars made with CreateBar-style widgets
-- (fields: fill, left, right). sizes[i] scales the font for smaller bars.
function Media.Style(bars, db)
    local font = Media.Font(db.font)
    local tex = Media.Texture(db.texture)
    local outline = db.outline ~= "NONE" and db.outline or ""
    for bar, scale in pairs(bars) do
        bar.fill:SetTexture(tex)
        local size = math.max(6, math.floor(db.fontSize * scale + 0.5))
        for _, fs in ipairs({ bar.left, bar.right }) do
            fs:SetFont(font, size, outline)
            if not fs:GetFont() then
                fs:SetFont(STANDARD_TEXT_FONT, size, outline)
            end
            fs:SetShadowOffset(outline == "" and 1 or 0, outline == "" and -1 or 0)
        end
    end
end

-- Re-style when new media is registered (other addons load theirs late).
function Media.Watch(callback)
    if LSM then
        LSM.RegisterCallback(Media, "LibSharedMedia_Registered", callback)
        LSM.RegisterCallback(Media, "LibSharedMedia_SetGlobal", callback)
    end
end

-- Options widget: "Label   [<]  value  [>]". Mouse wheel over it also cycles.
-- values: function returning the list; label(value) for display; get/set the value.
function Media.Cycler(parent, anchor, title, values, label, get, set, preview, x, y)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(360, 24)
    f:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x or 0, y or -12)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("LEFT", 0, 0)
    f.title:SetWidth(80)
    f.title:SetJustifyH("LEFT")
    f.title:SetText(title)

    local prev = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    prev:SetSize(24, 22)
    prev:SetPoint("LEFT", f.title, "RIGHT", 4, 0)
    prev:SetText("<")
    local nextB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    nextB:SetSize(24, 22)
    nextB:SetPoint("LEFT", prev, "RIGHT", 230, 0)
    nextB:SetText(">")

    f.value = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.value:SetPoint("LEFT", prev, "RIGHT", 6, 0)
    f.value:SetPoint("RIGHT", nextB, "LEFT", -6, 0)
    f.value:SetJustifyH("CENTER")
    f.value:SetWordWrap(false)

    function f:Refresh()
        local v = get()
        f.value:SetText(label(v))
        if preview then preview(f.value, v) end
    end

    local function step(dir)
        local list = values()
        local cur, idx = get(), 1
        for i, v in ipairs(list) do
            if v == cur then idx = i break end
        end
        idx = ((idx - 1 + dir) % #list) + 1
        set(list[idx])
        f:Refresh()
    end
    prev:SetScript("OnClick", function() step(-1) end)
    nextB:SetScript("OnClick", function() step(1) end)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta) step(delta > 0 and -1 or 1) end)
    return f
end

-- Adds Font / Outline / Texture cyclers under anchor. Returns the last widget and
-- a refresh function. getDB() returns the saved settings; apply() restyles bars.
function Media.AddOptions(parent, anchor, getDB, apply)
    local font = Media.Cycler(parent, anchor, "Font",
        function() return Media.List("font") end,
        function(v) return Media.Label("font", v) end,
        function() return getDB().font end,
        function(v) getDB().font = v; apply() end,
        function(fs, v) fs:SetFont(Media.Font(v), 12, "") end, 0, -16)
    local outline = Media.Cycler(parent, font, "Outline",
        function() return Media.OUTLINES end,
        function(v) return Media.OUTLINE_LABELS[v] or v end,
        function() return getDB().outline end,
        function(v) getDB().outline = v; apply() end)
    local tex = Media.Cycler(parent, outline, "Texture",
        function() return Media.List("statusbar") end,
        function(v) return Media.Label("statusbar", v) end,
        function() return getDB().texture end,
        function(v) getDB().texture = v; apply() end)
    local function refresh()
        font:Refresh()
        outline:Refresh()
        tex:Refresh()
    end
    return tex, refresh
end
