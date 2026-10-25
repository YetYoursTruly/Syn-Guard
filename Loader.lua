--[[
    Syn-Guard  -  request firewall for Potassium (standalone, no UI library needed)

    Autoexec stub (this is all you put in the autoexec folder):
        loadstring(game:HttpGet("https://raw.githubusercontent.com/YetYoursTruly/Syn-Guard/main/Guard.lua"))()

    Repo layout:
        Guard.lua
        Assets/settings.png, globe.png, shield-alert.png, x.png   (28x28, shown at 14x14)

    Startup cost: only the hooks are installed. The UI, the icon download, the ASCII effect and the
    config file are all created lazily the first time they are needed.

    How it behaves
      * Web/HTTP + WebSocket calls PAUSE the calling script thread (exactly like a slow network request)
        and show the prompt. Allow -> the real call runs and the script gets the REAL result, so
        loadstring(game:HttpGet(...))() works. Decline -> the script gets an empty fake result and carries on.
      * Clipboard / teleport / purchase / file calls are blocked immediately (script keeps running);
        Allow runs that call once.
      * The gear button in the prompt's top bar opens settings. RightShift also opens/closes it.
]]

if getgenv().SynGuardLoaded then return end
getgenv().SynGuardLoaded = true

local REPO_RAW   = "https://raw.githubusercontent.com/YetYoursTruly/Syn-Guard/main/"
local ICON_FILE  = "settings.png"
local ASSET_DIR  = "Syn-Guard-assets"
local CFG_FILE   = "Syn-Guard.json"
local TOGGLE_KEY = Enum.KeyCode.RightShift

----------------------------------------------------------------------
-- Saved originals (taken BEFORE any hook is installed)
----------------------------------------------------------------------
local cloneref = cloneref or function(x) return x end
local clonef   = clonefunction or function(f) return f end
local env      = getgenv()

local ORIG = {
    writefile = writefile and clonef(writefile),
    readfile  = readfile and clonef(readfile),
    isfile    = isfile and clonef(isfile),
}
local origHttpGet
pcall(function() origHttpGet = game.HttpGet end)
origHttpGet = origHttpGet and clonef(origHttpGet)

local cfg = { Web = true, Clipboard = true, Teleport = true, Purchase = true, Socket = true, Files = false }

local CATEGORIES = {
    { key = "Web",       tag = "WEB",  name = "Web / HTTP requests" },
    { key = "Clipboard", tag = "CLIP", name = "Clipboard" },
    { key = "Teleport",  tag = "TELE", name = "Teleports / queue_on_teleport" },
    { key = "Purchase",  tag = "BUY",  name = "Purchase prompts" },
    { key = "Socket",    tag = "WS",   name = "WebSockets" },
    { key = "Files",     tag = "FILE", name = "File writes" },
}
local CAT = {}
for _, c in ipairs(CATEGORIES) do CAT[c.key] = c end

local function saveCfg()
    if not ORIG.writefile then return end
    pcall(function()
        ORIG.writefile(CFG_FILE, cloneref(game:GetService("HttpService")):JSONEncode(cfg))
    end)
end

-- config is read after startup, never during it
task.defer(function()
    pcall(function()
        if ORIG.isfile and ORIG.isfile(CFG_FILE) then
            local data = cloneref(game:GetService("HttpService")):JSONDecode(ORIG.readfile(CFG_FILE))
            for k in pairs(cfg) do
                if type(data[k]) == "boolean" then cfg[k] = data[k] end
            end
        end
    end)
end)

----------------------------------------------------------------------
-- Queue
----------------------------------------------------------------------
local queue, byKey = {}, {}
local changed -- set below (lazy UI)

local function short(s, n)
    s = tostring(s)
    if #s > n then return s:sub(1, n) .. "..." end
    return s
end

local function callerName()
    local ok, scr = pcall(function() return getcallingscript and getcallingscript() end)
    if ok and scr then
        local ok2, n = pcall(function() return scr:GetFullName() end)
        if ok2 then return n end
    end
    return "executor script"
end

-- hold = the calling thread waits for the decision
local function enqueue(cat, label, target, detail, hold, replay)
    local key = cat .. "|" .. label .. "|" .. tostring(target)
    local item = byKey[key]
    if item then
        item.count += 1
    else
        if #queue >= 25 then return nil end -- flood protection: extra calls are auto-declined
        item = {
            cat = cat, label = label, target = tostring(target), detail = detail or "", hold = hold,
            replay = replay, count = 1, key = key, source = callerName(), waiters = {},
        }
        byKey[key] = item
        table.insert(queue, item)
    end
    task.defer(changed)
    return item
end

-- pauses the current thread until the user decides; returns true if allowed
local function waitFor(item)
    local ev = Instance.new("BindableEvent")
    table.insert(item.waiters, ev)
    local allowed = ev.Event:Wait()
    ev:Destroy()
    return allowed
end

local function resolve(item, allowed)
    local idx = table.find(queue, item)
    if not idx then return end
    table.remove(queue, idx)
    byKey[item.key] = nil
    for _, ev in ipairs(item.waiters) do ev:Fire(allowed) end
    if allowed and not item.hold and item.replay then
        task.spawn(pcall, item.replay)
    end
    task.defer(changed)
end

----------------------------------------------------------------------
-- Hooks
----------------------------------------------------------------------
local function targetOf(a1, a2)
    if type(a1) == "table" then
        local url = a1.Url or a1.url or "?"
        local m = a1.Method or a1.method or "GET"
        local body = a1.Body or a1.body
        return url, m .. (body and ("  |  body: " .. short(body, 120)) or "")
    end
    local d = ""
    if a2 ~= nil and type(a2) ~= "boolean" then d = "data: " .. short(a2, 120) end
    return a1, d
end

local FAKE_RESPONSE = function()
    return { Success = true, StatusCode = 200, StatusMessage = "OK", Headers = {}, Body = "" }
end

local function wrapGlobal(tbl, name, cat, label, describe, fake, hold)
    local orig = tbl and tbl[name]
    if type(orig) ~= "function" then return end
    local o = clonef(orig)
    local hook = newcclosure(function(...)
        if not cfg[cat] then return o(...) end
        local args = table.pack(...)
        local ok, target, detail = pcall(describe, ...)
        if not ok then target, detail = "?", "" end
        local item = enqueue(cat, label, target, detail, hold, (not hold) and function()
            return o(table.unpack(args, 1, args.n))
        end or nil)
        if hold and item and waitFor(item) then
            return o(table.unpack(args, 1, args.n)) -- approved: the script gets the REAL result
        end
        if fake then return fake(...) end
    end)
    local hooked = hookfunction and pcall(hookfunction, orig, hook)
    if not hooked then pcall(function() tbl[name] = hook end) end
end

local reqDescribe = function(opts) return targetOf(opts) end
wrapGlobal(env, "request", "Web", "request()", reqDescribe, FAKE_RESPONSE, true)
wrapGlobal(env, "http_request", "Web", "http_request()", reqDescribe, FAKE_RESPONSE, true)
wrapGlobal(env.syn, "request", "Web", "syn.request()", reqDescribe, FAKE_RESPONSE, true)
wrapGlobal(env.http, "request", "Web", "http.request()", reqDescribe, FAKE_RESPONSE, true)
wrapGlobal(env.fluxus, "request", "Web", "fluxus.request()", reqDescribe, FAKE_RESPONSE, true)

local clipDescribe = function(text) return "clipboard write", "text: " .. short(text, 160) end
wrapGlobal(env, "setclipboard", "Clipboard", "setclipboard()", clipDescribe)
wrapGlobal(env, "toclipboard", "Clipboard", "toclipboard()", clipDescribe)
wrapGlobal(env.Clipboard, "set", "Clipboard", "Clipboard.set()", clipDescribe)

local qDescribe = function(code) return "runs code after teleport", short(code, 160) end
wrapGlobal(env, "queue_on_teleport", "Teleport", "queue_on_teleport()", qDescribe)
wrapGlobal(env, "queueonteleport", "Teleport", "queueonteleport()", qDescribe)
wrapGlobal(env.syn, "queue_on_teleport", "Teleport", "syn.queue_on_teleport()", qDescribe)

local fDescribe = function(path, data) return path, "data: " .. short(data, 120) end
wrapGlobal(env, "writefile", "Files", "writefile()", fDescribe)
wrapGlobal(env, "appendfile", "Files", "appendfile()", fDescribe)

do -- WebSockets (held; approved -> real socket)
    local ws = env.WebSocket
    if type(ws) == "table" and type(ws.connect) == "function" then
        local o = clonef(ws.connect)
        local function dummy()
            local noop = setmetatable({}, { __index = function() return function() end end })
            return setmetatable({ OnMessage = noop, OnClose = noop }, { __index = function() return function() end end })
        end
        local hook = newcclosure(function(url, ...)
            if not cfg.Socket then return o(url, ...) end
            local rest = table.pack(...)
            local item = enqueue("Socket", "WebSocket.connect()", url, "", true)
            if item and waitFor(item) then return o(url, table.unpack(rest, 1, rest.n)) end
            return dummy()
        end)
        local hooked = hookfunction and pcall(hookfunction, ws.connect, hook)
        if not hooked then pcall(function() ws.connect = hook end) end
    end
end

local EMPTY = function() return "" end
local NOTHING = function() end
local W = {
    HttpGet           = { class = "DataModel",         cat = "Web",      hold = true,  fake = EMPTY },
    HttpGetAsync      = { class = "DataModel",         cat = "Web",      hold = true,  fake = EMPTY },
    HttpPost          = { class = "DataModel",         cat = "Web",      hold = true,  fake = EMPTY },
    HttpPostAsync     = { class = "DataModel",         cat = "Web",      hold = true,  fake = EMPTY },
    RequestAsync      = { class = "HttpService",       cat = "Web",      hold = true,  fake = FAKE_RESPONSE },
    GetAsync          = { class = "HttpService",       cat = "Web",      hold = true,  fake = function() return "{}" end },
    PostAsync         = { class = "HttpService",       cat = "Web",      hold = true,  fake = function() return "{}" end },
    OpenBrowserWindow = { class = "GuiService",        cat = "Web",      fake = NOTHING },
    Teleport                = { class = "TeleportService", cat = "Teleport", fake = NOTHING },
    TeleportAsync           = { class = "TeleportService", cat = "Teleport", fake = NOTHING },
    TeleportToPlaceInstance = { class = "TeleportService", cat = "Teleport", fake = NOTHING },
    PromptPurchase         = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptProductPurchase  = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptGamePassPurchase = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptBundlePurchase   = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptPremiumPurchase  = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptRobuxPurchase    = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptSubscriptionPurchase = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptCancelSubscription   = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptNativePurchase   = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptNativePurchaseWithLocalPlayer = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptThirdPartyPurchase = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptBulkPurchase     = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PromptCollectiblesPurchase = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    -- these spend Robux WITHOUT showing any prompt at all
    PerformPurchase        = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PerformPurchaseV2      = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    PerformBulkPurchase    = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    SignalPromptPurchaseFinished        = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    SignalPromptProductPurchaseFinished = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
    SignalClientPurchaseSuccess         = { class = "MarketplaceService", cat = "Purchase", fake = NOTHING },
}
W.OpenNativeOverlay = { class = "GuiService", cat = "Web", fake = NOTHING }

local bypassTok -- lets an approved call pass through every hook layer (restored when the real call returns)

-- returns false (let it through) or true, packedResults (what the script should get back)
local function check(self, m, ...)
    local w = W[m]
    if not w or not cfg[w.cat] then return false end
    local ok, cls = pcall(function() return self.ClassName end)
    if not ok or cls ~= w.class then return false end

    local args = table.pack(...)
    if bypassTok and bypassTok.m == m and bypassTok.a == args[1] then
        return false -- an approved call on its way through (token is cleared by real())
    end

    local function real()
        local prev = bypassTok
        bypassTok = { m = m, a = args[1] }
        local okc, res = pcall(function() return table.pack(self[m](self, table.unpack(args, 1, args.n))) end)
        bypassTok = prev
        if not okc then error(res, 0) end
        return table.unpack(res, 1, res.n)
    end

    local target, detail = targetOf(args[1], args[2])
    local label = (cls == "DataModel" and "game" or cls) .. ":" .. m .. "()"
    local item = enqueue(w.cat, label, target, detail, w.hold, (not w.hold) and real or nil)

    if w.hold and item and waitFor(item) then
        return true, table.pack(real()) -- approved: the real response goes back to the script
    end
    return true, table.pack(w.fake(...))
end

-- Hook the method FUNCTIONS themselves. This catches calls that never touch __namecall/__index:
-- references a script saved earlier, game.X(game, ...), getrawmetatable tricks, etc.
-- Must run BEFORE the __index hook below so we read the real functions.
for m, w in pairs(W) do
    pcall(function()
        local inst = w.class == "DataModel" and game or cloneref(game:GetService(w.class))
        local fn = inst[m]
        if type(fn) ~= "function" or not hookfunction then return end
        local o = clonef(fn)
        hookfunction(fn, newcclosure(function(self, ...)
            local blocked, res = check(self, m, ...)
            if blocked then return table.unpack(res, 1, res.n) end
            return o(self, ...)
        end))
    end)
end

if hookmetamethod then
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local m = getnamecallmethod()
        if W[m] then
            local blocked, res = check(self, m, ...)
            if blocked then return table.unpack(res, 1, res.n) end
        end
        return oldNamecall(self, ...)
    end))

    local oldIndex
    oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, k)
        if type(k) == "string" and W[k] and typeof(self) == "Instance" then
            local real = oldIndex(self, k)
            if type(real) == "function" then
                return newcclosure(function(s, ...)
                    local blocked, res = check(s, k, ...)
                    if blocked then return table.unpack(res, 1, res.n) end
                    return real(s, ...)
                end)
            end
            return real
        end
        return oldIndex(self, k)
    end))
end

----------------------------------------------------------------------
-- UI (built lazily on the first request or the first RightShift)
----------------------------------------------------------------------
local ui
local showSettings = false

-- icons live in the repo's Assets folder; downloaded once, cached in the workspace
local ICON_FILES = { "settings.png", "globe.png", "shield-alert.png", "x.png" }

local function buildUI()
    local RunService = cloneref(game:GetService("RunService"))
    local TweenService = cloneref(game:GetService("TweenService"))
    local TextService = cloneref(game:GetService("TextService"))
    local UserInputService = cloneref(game:GetService("UserInputService"))
    local CoreGui = cloneref(game:GetService("CoreGui"))

    -- monochrome palette
    local T = {
        bg = Color3.fromRGB(8, 8, 8), panel = Color3.fromRGB(20, 20, 20),
        button = Color3.fromRGB(28, 28, 28), buttonHi = Color3.fromRGB(52, 52, 52),
        text = Color3.fromRGB(238, 238, 238), dim = Color3.fromRGB(130, 130, 130),
        icon = Color3.fromRGB(200, 200, 200), white = Color3.fromRGB(238, 238, 238),
        black = Color3.fromRGB(8, 8, 8),
    }
    local W_, TOP, REQ_H, SET_H = 520, 32, 176, 262
    local PAD = 70 -- how far the ascii reaches past the window edges

    local function new(class, props, parent)
        local i = Instance.new(class)
        for k, v in pairs(props) do pcall(function() i[k] = v end) end
        i.Parent = parent
        return i
    end
    local function round(p, r) return new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, p) end
    local function outline(p, tr)
        return new("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = tr, Thickness = 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, p)
    end
    local function tw(o, t, props)
        TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props):Play()
    end
    local function text(props, parent)
        props.BackgroundTransparency = 1
        props.Font = props.Font or Enum.Font.GothamMedium
        props.TextSize = props.TextSize or 13
        props.TextColor3 = props.TextColor3 or T.text
        props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
        return new("TextLabel", props, parent)
    end

    ------------------------------------------------------------------
    -- Icons
    ------------------------------------------------------------------
    local iconAssets, iconWaiters = {}, {}
    local function useIcon(img, file, onLoad)
        if iconAssets[file] then
            img.Image = iconAssets[file]; img.Visible = true
            if onLoad then onLoad() end
            return
        end
        iconWaiters[file] = iconWaiters[file] or {}
        table.insert(iconWaiters[file], { img = img, cb = onLoad })
    end
    task.spawn(function()
        for _, file in ipairs(ICON_FILES) do
            pcall(function()
                if not (isfolder and makefolder and isfile and ORIG.writefile and getcustomasset and origHttpGet) then return end
                if not isfolder(ASSET_DIR) then makefolder(ASSET_DIR) end
                local path = ASSET_DIR .. "/" .. file
                if not isfile(path) then
                    local data = origHttpGet(game, REPO_RAW .. "Assets/" .. file) -- saved original: never intercepted
                    if type(data) ~= "string" or #data < 50 or data:sub(2, 4) ~= "PNG" then return end
                    ORIG.writefile(path, data)
                end
                iconAssets[file] = getcustomasset(path)
                for _, w in ipairs(iconWaiters[file] or {}) do
                    w.img.Image = iconAssets[file]; w.img.Visible = true
                    if w.cb then w.cb() end
                end
            end)
        end
    end)
    local function iconImg(parent, file, size, pos, onLoad)
        local img = new("ImageLabel", {
            Size = UDim2.fromOffset(size, size), Position = pos, BackgroundTransparency = 1,
            ImageColor3 = T.icon, Visible = false,
        }, parent)
        useIcon(img, file, onLoad)
        return img
    end

    ------------------------------------------------------------------
    -- Window (fixed position, top center, not draggable)
    ------------------------------------------------------------------
    local gui = new("ScreenGui", {
        Name = "Syn-Guard", ResetOnSpawn = false, IgnoreGuiInset = true,
        DisplayOrder = 2147483647, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, (gethui and gethui()) or CoreGui)

    local shownPos  = UDim2.new(0.5, 0, 0, 12)
    local hiddenPos = UDim2.new(0.5, 0, 0, -(SET_H + PAD + 40))
    local frame = new("Frame", {
        Name = "Main", AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(W_, REQ_H), Position = hiddenPos,
        BackgroundColor3 = T.bg, BackgroundTransparency = 0.08, BorderSizePixel = 0, Visible = false, ZIndex = 10,
    }, gui)
    round(frame); outline(frame, 0.6)
    local okS, shadow = pcall(Instance.new, "UIShadow")
    if okS and shadow then
        pcall(function() shadow.Color = Color3.new(1, 1, 1); shadow.Transparency = 0.82; shadow.BlurRadius = UDim.new(0, 20) end)
        shadow.Parent = frame
    end

    ------------------------------------------------------------------
    -- ASCII backdrop: a CHILD of the window, so it can never drift off it
    ------------------------------------------------------------------
    local HW, HH = W_ + PAD * 2, SET_H + PAD * 2
    local holder = new("Frame", {
        BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 1,
        Position = UDim2.fromOffset(-PAD, -PAD), Size = UDim2.fromOffset(HW, HH),
    }, frame)
    local FONT = Enum.Font.Code
    local huge = Vector2.new(1e5, 1e5)
    local cw = TextService:GetTextSize(string.rep("M", 200), 13, FONT, huge).X / 200
    local ch = (TextService:GetTextSize(string.rep("M\n", 20) .. "M", 13, FONT, huge).Y - TextService:GetTextSize("M", 13, FONT, huge).Y) / 20
    if cw <= 0 then cw = 8 end
    if ch <= 0 then ch = 13 end
    local cols, rows = math.floor(HW / cw), math.floor(HH / ch)
    local labels = {}
    for i = 1, 2 do
        labels[i] = new("TextLabel", {
            BackgroundTransparency = 1, Font = FONT, TextSize = 13, TextColor3 = Color3.new(1, 1, 1),
            TextTransparency = i == 1 and 0.84 or 0.5, TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top, Text = "", ZIndex = 1, RichText = false,
            Position = UDim2.fromOffset((HW - cols * cw) / 2, (HH - rows * ch) / 2),
            Size = UDim2.fromOffset(cols * cw + 4, rows * ch + 4),
        }, holder)
    end
    local ramp = " .,:;-=+*x#%@"
    local rampLen = #ramp
    local offX, offY = (HW - cols * cw) / 2, (HH - rows * ch) / 2
    local clock, acc = 0, 0
    local rowsA, rowsB, ca, cb = {}, {}, {}, {}
    local noise, sin, sqrt, floor = math.noise, math.sin, math.sqrt, math.floor

    RunService.Heartbeat:Connect(function(dt)
        if not frame.Visible then return end
        acc += dt
        if acc < 1 / 20 then return end
        clock += acc; acc = 0
        local fs = frame.AbsoluteSize
        local x0, y0, x1, y1 = PAD, PAD, PAD + fs.X, PAD + fs.Y -- the window, in holder space
        for y = 0, rows - 1 do
            local cy = offY + (y + 0.5) * ch
            local qy = math.max(y0 - cy, cy - y1, 0)
            local ny = y * 0.11 - clock * 0.35
            for x = 0, cols - 1 do
                local cx = offX + (x + 0.5) * cw
                local qx = math.max(x0 - cx, cx - x1, 0)
                local a, b = " ", " "
                if (qx > 0 or qy > 0) and qx < PAD and qy < PAD then
                    local g = 1 - sqrt(qx * qx + qy * qy) / PAD
                    if g > 0 then
                        g = g * g * (3 - 2 * g)
                        local v = (0.45 + noise(x * 0.055, ny, clock * 0.12) * 1.3 + sin(x * 0.12 + clock * 1.1) * 0.12) * g
                        if v >= 0.1 then
                            local idx = math.clamp(floor(v * rampLen) + 1, 2, rampLen)
                            local gl = ramp:sub(idx, idx)
                            if v >= 0.55 then b = gl else a = gl end
                        end
                    end
                end
                ca[x + 1], cb[x + 1] = a, b
            end
            rowsA[y + 1] = table.concat(ca, "", 1, cols)
            rowsB[y + 1] = table.concat(cb, "", 1, cols)
        end
        labels[1].Text = table.concat(rowsA, "\n", 1, rows)
        labels[2].Text = table.concat(rowsB, "\n", 1, rows)
    end)

    -- clipping layer for the real content (rounded corners)
    local clip = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 2 }, frame)
    round(clip)

    ------------------------------------------------------------------
    -- Top bar: shield icon + title, pending count, settings gear
    ------------------------------------------------------------------
    local topbar = new("Frame", { Size = UDim2.new(1, 0, 0, TOP), BackgroundColor3 = T.panel, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, clip)
    new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.9, BorderSizePixel = 0 }, topbar)
    iconImg(topbar, "shield-alert.png", 16, UDim2.fromOffset(12, 8))
    local titleLbl = text({ Position = UDim2.fromOffset(36, 0), Size = UDim2.new(1, -170, 1, 0), Text = "Syn-Guard  //  request", Font = Enum.Font.GothamBold }, topbar)
    local countLbl = text({
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -40, 0, 0), Size = UDim2.fromOffset(100, TOP),
        Text = "", TextColor3 = T.dim, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.Code,
    }, topbar)

    local gear = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(22, 22),
        BackgroundColor3 = T.button, BackgroundTransparency = 0.1, BorderSizePixel = 0, AutoButtonColor = false,
        Text = "[=]", TextColor3 = T.icon, TextSize = 11, Font = Enum.Font.Code,
    }, topbar)
    round(gear, 6); outline(gear, 0.88)
    local gearImg = iconImg(gear, "settings.png", 14, UDim2.fromOffset(4, 4), function() gear.Text = "" end)
    local function paintGear(hover)
        local on = hover or showSettings
        tw(gear, 0.15, { BackgroundColor3 = on and T.buttonHi or T.button })
        tw(gearImg, 0.15, { ImageColor3 = on and T.white or T.icon })
        gear.TextColor3 = on and T.white or T.icon
    end
    gear.MouseEnter:Connect(function() paintGear(true) end)
    gear.MouseLeave:Connect(function() paintGear(false) end)

    ------------------------------------------------------------------
    -- Request page
    ------------------------------------------------------------------
    local reqPage = new("Frame", { Position = UDim2.fromOffset(0, TOP), Size = UDim2.new(1, 0, 1, -TOP), BackgroundTransparency = 1 }, clip)
    local globeIcon = iconImg(reqPage, "globe.png", 16, UDim2.fromOffset(14, 10))
    local shieldIcon = iconImg(reqPage, "shield-alert.png", 16, UDim2.fromOffset(14, 10))
    local tagLbl = text({ Position = UDim2.fromOffset(38, 10), Size = UDim2.fromOffset(52, 18), Text = "[WEB]", Font = Enum.Font.Code, TextSize = 13, TextColor3 = T.dim }, reqPage)
    local fnLbl = text({ Position = UDim2.fromOffset(94, 10), Size = UDim2.new(1, -108, 0, 18), Text = "", Font = Enum.Font.GothamBold, TextTruncate = Enum.TextTruncate.AtEnd }, reqPage)
    local srcLbl = text({ Position = UDim2.fromOffset(14, 31), Size = UDim2.new(1, -28, 0, 16), Text = "", TextColor3 = T.dim, TextSize = 11, TextTruncate = Enum.TextTruncate.AtEnd }, reqPage)
    local tbox = new("Frame", { Position = UDim2.fromOffset(14, 54), Size = UDim2.new(1, -28, 0, 44), BackgroundColor3 = T.panel, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, reqPage)
    round(tbox, 6); outline(tbox, 0.9)
    text({ Position = UDim2.fromOffset(9, 0), Size = UDim2.fromOffset(14, 44), Text = "$", TextColor3 = T.dim, Font = Enum.Font.Code }, tbox)
    local targetLbl = text({
        Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -36, 1, 0), Text = "", Font = Enum.Font.Code, TextSize = 12,
        TextWrapped = true, TextTruncate = Enum.TextTruncate.AtEnd,
    }, tbox)

    -- Allow: solid light button.  Decline: dark outlined button with the x icon.
    local allowBtn = new("TextButton", {
        Position = UDim2.new(0, 14, 0, 108), Size = UDim2.new(0.5, -21, 0, 28), BackgroundColor3 = T.white,
        BorderSizePixel = 0, AutoButtonColor = false, Text = "Allow", TextColor3 = T.black, TextSize = 13, Font = Enum.Font.GothamBold,
    }, reqPage)
    round(allowBtn, 6)
    allowBtn.MouseEnter:Connect(function() tw(allowBtn, 0.15, { BackgroundColor3 = Color3.new(1, 1, 1) }) end)
    allowBtn.MouseLeave:Connect(function() tw(allowBtn, 0.2, { BackgroundColor3 = T.white }) end)

    local declineBtn = new("TextButton", {
        Position = UDim2.new(0.5, 7, 0, 108), Size = UDim2.new(0.5, -21, 0, 28), BackgroundColor3 = T.button, BackgroundTransparency = 0.1,
        BorderSizePixel = 0, AutoButtonColor = false, Text = "Decline", TextColor3 = T.text, TextSize = 13, Font = Enum.Font.GothamBold,
    }, reqPage)
    round(declineBtn, 6); outline(declineBtn, 0.6)
    iconImg(declineBtn, "x.png", 14, UDim2.new(0, 12, 0.5, -7))
    declineBtn.MouseEnter:Connect(function() tw(declineBtn, 0.15, { BackgroundColor3 = T.buttonHi }) end)
    declineBtn.MouseLeave:Connect(function() tw(declineBtn, 0.2, { BackgroundColor3 = T.button }) end)

    allowBtn.MouseButton1Click:Connect(function() if queue[1] then resolve(queue[1], true) end end)
    declineBtn.MouseButton1Click:Connect(function() if queue[1] then resolve(queue[1], false) end end)

    ------------------------------------------------------------------
    -- Settings page
    ------------------------------------------------------------------
    local setPage = new("Frame", { Position = UDim2.fromOffset(0, TOP), Size = UDim2.new(1, 0, 1, -TOP), BackgroundTransparency = 1, Visible = false }, clip)
    for i, cat in ipairs(CATEGORIES) do
        local row = new("Frame", { Position = UDim2.fromOffset(14, 8 + (i - 1) * 30), Size = UDim2.new(1, -28, 0, 26), BackgroundTransparency = 1 }, setPage)
        local isWeb = cat.key == "Web" or cat.key == "Socket"
        iconImg(row, isWeb and "globe.png" or "shield-alert.png", 14, UDim2.fromOffset(0, 6))
        text({ Position = UDim2.fromOffset(24, 0), Size = UDim2.fromOffset(48, 26), Text = "[" .. cat.tag .. "]", Font = Enum.Font.Code, TextColor3 = T.dim }, row)
        text({ Position = UDim2.fromOffset(76, 0), Size = UDim2.new(1, -150, 1, 0), Text = cat.name, TextSize = 12 }, row)
        local sw = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(64, 22),
            BackgroundColor3 = T.button, BackgroundTransparency = 0.1, BorderSizePixel = 0, AutoButtonColor = false,
            Text = "", TextSize = 12, Font = Enum.Font.Code,
        }, row)
        round(sw, 6)
        local st = outline(sw, 0.8)
        local function paint()
            local on = cfg[cat.key]
            sw.Text = on and "BLOCK" or "ALLOW"
            sw.TextColor3 = on and T.white or T.dim
            st.Transparency = on and 0.4 or 0.85
        end
        sw.MouseButton1Click:Connect(function() cfg[cat.key] = not cfg[cat.key]; paint(); saveCfg() end)
        paint()
    end
    text({
        Position = UDim2.new(0, 14, 1, -38), Size = UDim2.new(1, -28, 0, 32), TextColor3 = T.dim, TextSize = 11,
        Font = Enum.Font.Code, TextYAlignment = Enum.TextYAlignment.Top,
        Text = "BLOCK = intercept and ask first      ALLOW = let it through silently\nRightShift opens / closes this panel",
    }, setPage)

    ------------------------------------------------------------------
    -- Show / hide / refresh
    ------------------------------------------------------------------
    local open = false
    local function setOpen(want)
        if want == open then return end
        open = want
        if want then
            frame.Visible = true
            tw(frame, 0.35, { Position = shownPos })
        else
            tw(frame, 0.3, { Position = hiddenPos })
            task.delay(0.32, function() if not open then frame.Visible = false end end)
        end
    end

    local self = {}
    function self.refresh()
        local item = queue[1]
        countLbl.Text = #queue > 0 and (#queue .. " pending") or ""
        if item then
            local isWeb = item.cat == "Web" or item.cat == "Socket"
            globeIcon.ImageTransparency = isWeb and 0 or 1
            shieldIcon.ImageTransparency = isWeb and 1 or 0
            tagLbl.Text = "[" .. CAT[item.cat].tag .. "]"
            fnLbl.Text = item.label .. (item.count > 1 and ("   x" .. item.count) or "")
            srcLbl.Text = "src: " .. item.source .. (item.hold and "   //   script is paused until you choose"
                or "   //   call blocked, script still running")
            targetLbl.Text = item.target .. (item.detail ~= "" and ("\n" .. item.detail) or "")
        end
        reqPage.Visible = (not showSettings) and item ~= nil
        setPage.Visible = showSettings
        titleLbl.Text = showSettings and "Syn-Guard  //  settings" or "Syn-Guard  //  request"
        paintGear(false)
        tw(frame, 0.3, { Size = UDim2.fromOffset(W_, showSettings and SET_H or REQ_H) })
        setOpen(item ~= nil or showSettings)
    end

    gear.MouseButton1Click:Connect(function() showSettings = not showSettings; self.refresh() end)
    UserInputService.InputBegan:Connect(function(input, gpe)
        if not gpe and input.KeyCode == TOGGLE_KEY then
            showSettings = not showSettings
            self.refresh()
        end
    end)
    return self
end

changed = function()
    if not ui then
        if #queue == 0 then return end
        ui = buildUI()
    end
    ui.refresh()
end

-- RightShift before any request has happened: build the UI on demand (cheap listener only)
cloneref(game:GetService("UserInputService")).InputBegan:Connect(function(input, gpe)
    if not ui and not gpe and input.KeyCode == TOGGLE_KEY then
        showSettings = true
        ui = buildUI()
        ui.refresh()
    end
end)
