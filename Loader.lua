--[[
    Syn-Guard v2  -  request firewall for Potassium (standalone, no UI library needed)

    Autoexec stub:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/YetYoursTruly/Syn-Guard/main/Guard.lua"))()

    Repo layout:
        Guard.lua
        Assets/settings.png, globe.png, shield-alert.png, x.png

    Behaviour
      * Web/HTTP + WebSocket calls PAUSE the calling script thread and show a prompt.
        Allow -> the real call runs and the script gets the REAL result (loadstring(game:HttpGet())() works).
        Decline -> the script gets an empty fake result and carries on.
      * Clipboard / teleport / purchase / file calls are held back immediately (script keeps running);
        Allow runs that call once.
      * "Trust host" lets a host through for the rest of the session (web + websocket only).
      * LOG button = decision history, gear = settings, RightShift = open/close settings.

    Loop fix: approved calls are flagged PER THREAD (coroutine.running() read at call time), so the real call
    passes through every hook layer (function hook, __index, __namecall, executor-internal request) untouched.
]]

if getgenv().SynGuardLoaded then return end
getgenv().SynGuardLoaded = true

local REPO_RAW   = "https://raw.githubusercontent.com/YetYoursTruly/Syn-Guard/main/"
local ASSET_DIR  = "Syn-Guard-assets"
local CFG_FILE   = "Syn-Guard.json"
local TOGGLE_KEY = Enum.KeyCode.RightShift
local ICON_FILES = { "settings.png", "globe.png", "shield-alert.png", "x.png" }

----------------------------------------------------------------------
-- Saved originals + per-thread bypass (all taken BEFORE any hook)
----------------------------------------------------------------------
local cloneref = cloneref or function(x) return x end
local clonef   = clonefunction or function(f) return f end
local env      = getgenv()

local inFlight = setmetatable({}, { __mode = "k" }) -- threads currently running an APPROVED / internal call

local function runApproved(f, ...)
    local t = coroutine.running()
    local prev = inFlight[t]
    inFlight[t] = true
    local res = table.pack(pcall(f, ...))
    inFlight[t] = prev
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

-- clone now, and make every call from our own code immune to our own hooks
local function safe(f)
    if type(f) ~= "function" then return nil end
    local c = clonef(f)
    return function(...) return runApproved(c, ...) end
end

local ORIG = {
    writefile = safe(writefile),
    readfile  = safe(readfile),
    isfile    = safe(isfile),
}
local origHttpGet
pcall(function() origHttpGet = safe(game.HttpGet) end)

local cfg = { Web = true, Clipboard = true, Teleport = true, Purchase = true, Socket = true, Files = false }

local CATEGORIES = {
    { key = "Web",       tag = "WEB",  name = "Web / HTTP requests",         color = Color3.fromRGB(120, 170, 255) },
    { key = "Clipboard", tag = "CLIP", name = "Clipboard",                   color = Color3.fromRGB(255, 200, 110) },
    { key = "Teleport",  tag = "TELE", name = "Teleports / queue_on_teleport", color = Color3.fromRGB(190, 150, 255) },
    { key = "Purchase",  tag = "BUY",  name = "Purchase prompts",            color = Color3.fromRGB(255, 110, 110) },
    { key = "Socket",    tag = "WS",   name = "WebSockets",                  color = Color3.fromRGB(120, 170, 255) },
    { key = "Files",     tag = "FILE", name = "File writes",                 color = Color3.fromRGB(130, 220, 160) },
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
        if ORIG.isfile and ORIG.readfile and ORIG.isfile(CFG_FILE) then
            local data = cloneref(game:GetService("HttpService")):JSONDecode(ORIG.readfile(CFG_FILE))
            for k in pairs(cfg) do
                if type(data[k]) == "boolean" then cfg[k] = data[k] end
            end
        end
    end)
end)

----------------------------------------------------------------------
-- Helpers, trust list, queue, history
----------------------------------------------------------------------
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

local function hostOf(url)
    url = tostring(url)
    local auth = url:match("^%a[%w+.-]*://([^/%?#]*)")
    if not auth then return nil end
    auth = (auth:gsub(".*@", ""))   -- strip user:pass@  (defeats trusted.com@evil.com tricks)
    auth = (auth:gsub(":%d+$", "")) -- strip port
    if auth == "" then return nil end
    return auth:lower()
end

local trusted = {} -- host -> true, this session only
local function isTrusted(cat, hold, target)
    if not hold or (cat ~= "Web" and cat ~= "Socket") then return false end
    local h = hostOf(target)
    return h ~= nil and trusted[h] == true
end

local queue, byKey, history = {}, {}, {}
local changed -- assigned at the bottom

local function notify()
    task.defer(function() if changed then changed() end end)
end

-- hold = the calling thread waits for the decision
local function enqueue(cat, label, target, detail, hold, replay)
    target = tostring(target)
    local key = cat .. "|" .. label .. "|" .. target .. "|" .. (detail or "")
    local item = byKey[key]
    if item then
        item.count += 1
    else
        if #queue >= 25 then return nil end -- flood protection: extra calls are auto-declined
        item = {
            cat = cat, label = label, target = target, detail = detail or "", hold = hold,
            replay = replay, count = 1, key = key, source = callerName(), waiters = {},
            host = hold and hostOf(target) or nil,
        }
        byKey[key] = item
        table.insert(queue, item)
    end
    notify()
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

local function resolve(item, allowed, how)
    local idx = table.find(queue, item)
    if not idx then return end
    table.remove(queue, idx)
    byKey[item.key] = nil
    table.insert(history, 1, {
        t = os.date("%H:%M:%S"), cat = item.cat, label = item.label, target = item.target,
        allowed = allowed, how = how or (allowed and "allowed" or "declined"), count = item.count,
    })
    if #history > 40 then table.remove(history) end
    for _, ev in ipairs(item.waiters) do ev:Fire(allowed) end
    if allowed and not item.hold and item.replay then
        task.spawn(pcall, item.replay)
    end
    notify()
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
        if not cfg[cat] or inFlight[coroutine.running()] then return o(...) end
        local args = table.pack(...)
        local ok, target, detail = pcall(describe, ...)
        if not ok then target, detail = "?", "" end
        if isTrusted(cat, hold, target) then
            return runApproved(o, table.unpack(args, 1, args.n))
        end
        local replay
        if not hold then
            replay = function() return runApproved(o, table.unpack(args, 1, args.n)) end
        end
        local item = enqueue(cat, label, target, detail, hold, replay)
        if hold and item and waitFor(item) then
            return runApproved(o, table.unpack(args, 1, args.n)) -- approved: the script gets the REAL result
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
            if not cfg.Socket or inFlight[coroutine.running()] then return o(url, ...) end
            local rest = table.pack(...)
            if isTrusted("Socket", true, url) then
                return runApproved(o, url, table.unpack(rest, 1, rest.n))
            end
            local item = enqueue("Socket", "WebSocket.connect()", url, "", true)
            if item and waitFor(item) then
                return runApproved(o, url, table.unpack(rest, 1, rest.n))
            end
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
    OpenNativeOverlay = { class = "GuiService",        cat = "Web",      fake = NOTHING },
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

-- returns false (let it through) or true, packedResults (what the script should get back)
local function check(self, m, ...)
    local w = W[m]
    if not w or not cfg[w.cat] then return false end
    if inFlight[coroutine.running()] then return false end -- approved call passing through another hook layer
    local ok, cls = pcall(function() return self.ClassName end)
    if not ok or cls ~= w.class then return false end

    local args = table.pack(...)
    local target, detail = targetOf(args[1], args[2])
    if isTrusted(w.cat, w.hold, target) then return false end

    local function real()
        -- thread is read NOW (not captured), so a replay on a fresh thread flags itself correctly
        return runApproved(function() return self[m](self, table.unpack(args, 1, args.n)) end)
    end

    local label = (cls == "DataModel" and "game" or cls) .. ":" .. m .. "()"
    local item = enqueue(w.cat, label, target, detail, w.hold, (not w.hold) and real or nil)

    if w.hold and item and waitFor(item) then
        return true, table.pack(real()) -- approved: the real response goes back to the script
    end
    return true, table.pack(w.fake(...))
end

-- Hook the method FUNCTIONS themselves (catches saved references, game.X(game, ...), etc.)
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
            if setnamecallmethod then setnamecallmethod(m) end -- check() may have clobbered it
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
local manual -- nil | "settings" | "log"   (what the user opened by hand)

local function buildUI()
    local RunService = cloneref(game:GetService("RunService"))
    local TweenService = cloneref(game:GetService("TweenService"))
    local TextService = cloneref(game:GetService("TextService"))
    local CoreGui = cloneref(game:GetService("CoreGui"))

    local T = {
        bg = Color3.fromRGB(10, 10, 11), panel = Color3.fromRGB(22, 22, 24),
        button = Color3.fromRGB(30, 30, 33), buttonHi = Color3.fromRGB(56, 56, 60),
        text = Color3.fromRGB(238, 238, 238), dim = Color3.fromRGB(136, 136, 140),
        icon = Color3.fromRGB(200, 200, 200), white = Color3.fromRGB(238, 238, 238),
        black = Color3.fromRGB(8, 8, 8), ok = Color3.fromRGB(140, 220, 160), bad = Color3.fromRGB(240, 120, 120),
    }
    local W_, TOP, REQ_H, SET_H, LOG_H = 520, 36, 196, 300, 292
    local MAXH = math.max(REQ_H, SET_H, LOG_H)
    local PAD = 70 -- how far the ascii reaches past the window edges

    local function new(class, props, parent)
        local i = Instance.new(class)
        for k, v in pairs(props) do pcall(function() i[k] = v end) end
        i.Parent = parent
        return i
    end
    local function round(p, r) return new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, p) end
    local function outline(p, tr, color)
        return new("UIStroke", { Color = color or Color3.new(1, 1, 1), Transparency = tr, Thickness = 1,
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
    local function mkButton(parent, kind, label, props)
        local primary = kind == "primary"
        local base = primary and T.white or T.button
        local hi = primary and Color3.new(1, 1, 1) or T.buttonHi
        props.BackgroundColor3 = base
        props.BorderSizePixel = 0
        props.AutoButtonColor = false
        props.Text = label
        props.TextColor3 = primary and T.black or T.text
        props.TextSize = props.TextSize or 13
        props.Font = Enum.Font.GothamBold
        local b = new("TextButton", props, parent)
        round(b, 6)
        if not primary then outline(b, 0.7) end
        b.MouseEnter:Connect(function() tw(b, 0.12, { BackgroundColor3 = hi }) end)
        b.MouseLeave:Connect(function() tw(b, 0.2, { BackgroundColor3 = base }) end)
        return b
    end

    ------------------------------------------------------------------
    -- Icons (downloaded once, cached in the workspace)
    ------------------------------------------------------------------
    local iconAssets, iconWaiters = {}, {}
    local function useIcon(img, file)
        if iconAssets[file] then
            img.Image = iconAssets[file]; img.Visible = true
            return
        end
        iconWaiters[file] = iconWaiters[file] or {}
        table.insert(iconWaiters[file], img)
    end
    task.spawn(function()
        for _, file in ipairs(ICON_FILES) do
            pcall(function()
                if not (isfolder and makefolder and isfile and ORIG.writefile and getcustomasset and origHttpGet) then return end
                if not isfolder(ASSET_DIR) then makefolder(ASSET_DIR) end
                local path = ASSET_DIR .. "/" .. file
                if not isfile(path) then
                    local data = origHttpGet(game, REPO_RAW .. "Assets/" .. file)
                    if type(data) ~= "string" or #data < 50 or data:sub(2, 4) ~= "PNG" then return end
                    ORIG.writefile(path, data)
                end
                iconAssets[file] = getcustomasset(path)
                for _, img in ipairs(iconWaiters[file] or {}) do
                    img.Image = iconAssets[file]; img.Visible = true
                end
            end)
        end
    end)
    local function iconImg(parent, file, size, pos)
        local img = new("ImageLabel", {
            Size = UDim2.fromOffset(size, size), Position = pos, BackgroundTransparency = 1,
            ImageColor3 = T.icon, Visible = false,
        }, parent)
        useIcon(img, file)
        return img
    end

    ------------------------------------------------------------------
    -- Window (fixed, top center)
    ------------------------------------------------------------------
    local gui = new("ScreenGui", {
        Name = "Syn-Guard", ResetOnSpawn = false, IgnoreGuiInset = true,
        DisplayOrder = 2147483647, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, (gethui and gethui()) or CoreGui)

    local shownPos  = UDim2.new(0.5, 0, 0, 12)
    local hiddenPos = UDim2.new(0.5, 0, 0, -(MAXH + PAD + 40))
    local frame = new("Frame", {
        Name = "Main", AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(W_, REQ_H), Position = hiddenPos,
        BackgroundColor3 = T.bg, BackgroundTransparency = 0.05, BorderSizePixel = 0, Visible = false, ZIndex = 10,
    }, gui)
    round(frame); outline(frame, 0.65)

    ------------------------------------------------------------------
    -- ASCII glow around the window (a child of the window, so it can't drift)
    ------------------------------------------------------------------
    local HW, HH = W_ + PAD * 2, MAXH + PAD * 2
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
            TextTransparency = i == 1 and 0.86 or 0.55, TextXAlignment = Enum.TextXAlignment.Left,
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
        if acc < 1 / 18 then return end
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

    local clip = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 2 }, frame)
    round(clip)

    ------------------------------------------------------------------
    -- Header: shield + title, pending button, LOG, gear
    ------------------------------------------------------------------
    local topbar = new("Frame", { Size = UDim2.new(1, 0, 0, TOP), BackgroundColor3 = T.panel, BorderSizePixel = 0 }, clip)
    round(topbar, 8)
    new("Frame", { Position = UDim2.fromOffset(0, TOP - 10), Size = UDim2.new(1, 0, 0, 10), BackgroundColor3 = T.panel, BorderSizePixel = 0 }, topbar)
    new("Frame", { Position = UDim2.fromOffset(0, TOP - 1), Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.9, BorderSizePixel = 0 }, topbar)
    iconImg(topbar, "shield-alert.png", 16, UDim2.fromOffset(12, 10))
    local titleLbl = text({
        Position = UDim2.fromOffset(36, 0), Size = UDim2.new(1, -210, 1, -1), Font = Enum.Font.GothamBold,
        RichText = true, Text = "Syn-Guard",
    }, topbar)

    local pendingBtn = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -82, 0.5, 0), Size = UDim2.fromOffset(92, 22),
        BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false, Text = "", Font = Enum.Font.Code,
        TextSize = 11, TextColor3 = T.dim, TextXAlignment = Enum.TextXAlignment.Right, Visible = false,
    }, topbar)

    local function headerBtn(label, size, pos)
        local b = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5), Position = pos, Size = size,
            BackgroundColor3 = T.button, BorderSizePixel = 0, AutoButtonColor = false,
            Text = label, TextColor3 = T.icon, TextSize = 10, Font = Enum.Font.Code,
        }, topbar)
        round(b, 6); outline(b, 0.88)
        return b
    end
    local logBtn = headerBtn("LOG", UDim2.fromOffset(36, 22), UDim2.new(1, -38, 0.5, 0))
    local gear = headerBtn("[=]", UDim2.fromOffset(24, 22), UDim2.new(1, -8, 0.5, 0))
    local gearImg = iconImg(gear, "settings.png", 14, UDim2.fromOffset(5, 4))
    gearImg:GetPropertyChangedSignal("Visible"):Connect(function()
        if gearImg.Visible then gear.Text = "" end
    end)
    if gearImg.Visible then gear.Text = "" end

    local function paintHeaderBtn(b, active, hover)
        local on = active or hover
        tw(b, 0.12, { BackgroundColor3 = on and T.buttonHi or T.button })
        b.TextColor3 = on and T.white or T.icon
        if b == gear then tw(gearImg, 0.12, { ImageColor3 = on and T.white or T.icon }) end
    end

    ------------------------------------------------------------------
    -- Request page
    ------------------------------------------------------------------
    local reqPage = new("Frame", { Position = UDim2.fromOffset(0, TOP), Size = UDim2.new(1, 0, 1, -TOP), BackgroundTransparency = 1 }, clip)
    local chip = new("Frame", { Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(48, 18),
        BackgroundColor3 = T.dim, BackgroundTransparency = 0.82, BorderSizePixel = 0 }, reqPage)
    round(chip, 5)
    local chipStroke = outline(chip, 0.55, T.dim)
    local chipLbl = text({ Size = UDim2.fromScale(1, 1), Text = "WEB", Font = Enum.Font.Code, TextSize = 11,
        TextColor3 = T.dim, TextXAlignment = Enum.TextXAlignment.Center }, chip)
    local globeIcon = iconImg(reqPage, "globe.png", 16, UDim2.fromOffset(70, 11))
    local shieldIcon = iconImg(reqPage, "shield-alert.png", 16, UDim2.fromOffset(70, 11))
    local fnLbl = text({ Position = UDim2.fromOffset(92, 10), Size = UDim2.new(1, -106, 0, 20), Text = "",
        Font = Enum.Font.GothamBold, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd }, reqPage)
    local srcLbl = text({ Position = UDim2.fromOffset(14, 34), Size = UDim2.new(1, -150, 0, 16), Text = "",
        TextColor3 = T.dim, TextSize = 11, TextTruncate = Enum.TextTruncate.AtEnd }, reqPage)
    local declineAllBtn = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 34), Size = UDim2.fromOffset(120, 16),
        BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false, Text = "",
        Font = Enum.Font.Code, TextSize = 10, TextColor3 = T.dim, TextXAlignment = Enum.TextXAlignment.Right, Visible = false,
    }, reqPage)
    declineAllBtn.MouseEnter:Connect(function() declineAllBtn.TextColor3 = T.white end)
    declineAllBtn.MouseLeave:Connect(function() declineAllBtn.TextColor3 = T.dim end)

    local tbox = new("Frame", { Position = UDim2.fromOffset(14, 56), Size = UDim2.new(1, -28, 0, 54),
        BackgroundColor3 = T.panel, BackgroundTransparency = 0.1, BorderSizePixel = 0 }, reqPage)
    round(tbox, 6); outline(tbox, 0.9)
    local accentBar = new("Frame", { Position = UDim2.fromOffset(7, 8), Size = UDim2.fromOffset(2, 38),
        BackgroundColor3 = T.dim, BorderSizePixel = 0 }, tbox)
    round(accentBar, 1)
    local targetLbl = text({ Position = UDim2.fromOffset(18, 5), Size = UDim2.new(1, -28, 0, 30), Text = "",
        Font = Enum.Font.Code, TextSize = 12, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
        TextTruncate = Enum.TextTruncate.AtEnd }, tbox)
    local detailLbl = text({ Position = UDim2.fromOffset(18, 36), Size = UDim2.new(1, -28, 0, 14), Text = "",
        Font = Enum.Font.Code, TextSize = 11, TextColor3 = T.dim, TextTruncate = Enum.TextTruncate.AtEnd }, tbox)

    local declineBtn = mkButton(reqPage, "secondary", "Decline", { Size = UDim2.fromOffset(150, 30) })
    iconImg(declineBtn, "x.png", 14, UDim2.new(0, 12, 0.5, -7))
    local allowBtn = mkButton(reqPage, "primary", "Allow once", { Size = UDim2.fromOffset(150, 30) })
    local trustBtn = mkButton(reqPage, "secondary", "Trust host", { Size = UDim2.fromOffset(150, 30) })

    local function snapshot() return table.clone(queue) end
    allowBtn.MouseButton1Click:Connect(function() if queue[1] then resolve(queue[1], true, "allowed") end end)
    declineBtn.MouseButton1Click:Connect(function() if queue[1] then resolve(queue[1], false, "declined") end end)
    trustBtn.MouseButton1Click:Connect(function()
        local it = queue[1]
        if not (it and it.host) then return end
        trusted[it.host] = true
        for _, q in ipairs(snapshot()) do
            if q.hold and q.host == it.host then resolve(q, true, "trusted") end
        end
    end)
    declineAllBtn.MouseButton1Click:Connect(function()
        for _, q in ipairs(snapshot()) do resolve(q, false, "declined") end
    end)

    ------------------------------------------------------------------
    -- Settings page
    ------------------------------------------------------------------
    local setPage = new("Frame", { Position = UDim2.fromOffset(0, TOP), Size = UDim2.new(1, 0, 1, -TOP), BackgroundTransparency = 1, Visible = false }, clip)
    for i, cat in ipairs(CATEGORIES) do
        local row = new("Frame", { Position = UDim2.fromOffset(14, 10 + (i - 1) * 30), Size = UDim2.new(1, -28, 0, 26), BackgroundTransparency = 1 }, setPage)
        local isWeb = cat.key == "Web" or cat.key == "Socket"
        iconImg(row, isWeb and "globe.png" or "shield-alert.png", 14, UDim2.fromOffset(0, 6))
        text({ Position = UDim2.fromOffset(24, 0), Size = UDim2.fromOffset(48, 26), Text = "[" .. cat.tag .. "]", Font = Enum.Font.Code, TextColor3 = cat.color, TextSize = 12 }, row)
        text({ Position = UDim2.fromOffset(76, 0), Size = UDim2.new(1, -190, 1, 0), Text = cat.name, TextSize = 12 }, row)
        local stateLbl = text({
            AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -52, 0.5, 0), Size = UDim2.fromOffset(44, 26),
            Text = "", Font = Enum.Font.Code, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right,
        }, row)
        local sw = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(42, 20),
            BackgroundColor3 = T.button, BorderSizePixel = 0, AutoButtonColor = false, Text = "",
        }, row)
        round(sw, 10)
        local st = outline(sw, 0.8)
        local knob = new("Frame", { Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = T.dim, BorderSizePixel = 0 }, sw)
        round(knob, 7)
        local function paint()
            local on = cfg[cat.key]
            tw(sw, 0.15, { BackgroundColor3 = on and T.white or T.button })
            tw(knob, 0.15, { Position = UDim2.fromOffset(on and 25 or 3, 3), BackgroundColor3 = on and T.black or T.dim })
            st.Transparency = on and 0.4 or 0.85
            stateLbl.Text = on and "ASK" or "PASS"
            stateLbl.TextColor3 = on and T.white or T.dim
        end
        sw.MouseButton1Click:Connect(function() cfg[cat.key] = not cfg[cat.key]; paint(); saveCfg() end)
        paint()
    end
    local trustLbl = text({ Position = UDim2.fromOffset(14, 196), Size = UDim2.new(1, -100, 0, 26), Text = "",
        Font = Enum.Font.Code, TextSize = 11, TextColor3 = T.dim, TextTruncate = Enum.TextTruncate.AtEnd }, setPage)
    local clearBtn = mkButton(setPage, "secondary", "Clear", { AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -14, 0, 198), Size = UDim2.fromOffset(64, 22), TextSize = 11 })
    clearBtn.MouseButton1Click:Connect(function() table.clear(trusted); ui.refresh() end)
    text({
        Position = UDim2.new(0, 14, 1, -36), Size = UDim2.new(1, -28, 0, 30), TextColor3 = T.dim, TextSize = 11,
        Font = Enum.Font.Code, TextYAlignment = Enum.TextYAlignment.Top,
        Text = "ASK = intercept and prompt        PASS = let through silently\nRightShift opens / closes this panel",
    }, setPage)

    ------------------------------------------------------------------
    -- Log page
    ------------------------------------------------------------------
    local logPage = new("Frame", { Position = UDim2.fromOffset(0, TOP), Size = UDim2.new(1, 0, 1, -TOP), BackgroundTransparency = 1, Visible = false }, clip)
    local logList = new("ScrollingFrame", {
        Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 1, -16), BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = T.dim, CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, logPage)
    new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, logList)
    local emptyLbl = text({ Size = UDim2.fromScale(1, 1), Text = "no decisions yet", Font = Enum.Font.Code, TextSize = 12,
        TextColor3 = T.dim, TextXAlignment = Enum.TextXAlignment.Center }, logPage)
    local logRows = {}
    local function renderLog()
        for _, r in ipairs(logRows) do r:Destroy() end
        table.clear(logRows)
        emptyLbl.Visible = #history == 0
        for i, h in ipairs(history) do
            local row = new("Frame", { LayoutOrder = i, Size = UDim2.new(1, -6, 0, 34), BackgroundColor3 = T.panel,
                BackgroundTransparency = 0.3, BorderSizePixel = 0 }, logList)
            round(row, 5)
            local verdict = h.how == "trusted" and "TRUST" or (h.allowed and "ALLOW" or "DENY")
            text({ Position = UDim2.fromOffset(8, 0), Size = UDim2.fromOffset(50, 34), Text = verdict, Font = Enum.Font.Code,
                TextSize = 11, TextColor3 = h.allowed and T.ok or T.bad }, row)
            text({ Position = UDim2.fromOffset(62, 3), Size = UDim2.new(1, -136, 0, 14), TextSize = 12, Font = Enum.Font.GothamBold,
                Text = "[" .. CAT[h.cat].tag .. "] " .. h.label .. (h.count > 1 and ("  x" .. h.count) or ""),
                TextTruncate = Enum.TextTruncate.AtEnd }, row)
            text({ Position = UDim2.fromOffset(62, 18), Size = UDim2.new(1, -136, 0, 13), Text = short(h.target, 90),
                Font = Enum.Font.Code, TextSize = 11, TextColor3 = T.dim, TextTruncate = Enum.TextTruncate.AtEnd }, row)
            text({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 0), Size = UDim2.fromOffset(60, 34),
                Text = h.t, Font = Enum.Font.Code, TextSize = 10, TextColor3 = T.dim, TextXAlignment = Enum.TextXAlignment.Right }, row)
            table.insert(logRows, row)
        end
    end

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
        local view = manual or (item and "request") or nil
        if not view then setOpen(false) return end

        -- header
        titleLbl.Text = 'Syn-Guard  <font color="rgb(136,136,140)">//  ' .. view .. "</font>"
        pendingBtn.Visible = #queue > 0
        pendingBtn.Text = #queue .. " pending"
        pendingBtn.TextColor3 = view == "request" and T.dim or T.white
        paintHeaderBtn(gear, view == "settings", false)
        paintHeaderBtn(logBtn, view == "log", false)

        -- pages
        reqPage.Visible = view == "request"
        setPage.Visible = view == "settings"
        logPage.Visible = view == "log"

        if view == "request" and item then
            local cat = CAT[item.cat]
            local isWeb = item.cat == "Web" or item.cat == "Socket"
            globeIcon.ImageTransparency = isWeb and 0 or 1
            shieldIcon.ImageTransparency = isWeb and 1 or 0
            chipLbl.Text = cat.tag
            chipLbl.TextColor3 = cat.color
            chip.BackgroundColor3 = cat.color
            chipStroke.Color = cat.color
            accentBar.BackgroundColor3 = cat.color
            fnLbl.Text = item.label .. (item.count > 1 and ("   x" .. item.count) or "")
            srcLbl.Text = "from " .. item.source .. (item.hold and "   //   script paused until you choose"
                or "   //   call held back, script still running")
            targetLbl.Text = item.target
            detailLbl.Text = item.detail
            declineAllBtn.Visible = #queue > 1
            declineAllBtn.Text = "decline all (" .. #queue .. ")"

            local three = item.hold and item.host ~= nil
            local n = three and 3 or 2
            local bw = (W_ - 28 - (n - 1) * 8) / n
            for i, b in ipairs({ declineBtn, allowBtn, trustBtn }) do
                b.Size = UDim2.fromOffset(bw, 30)
                b.Position = UDim2.fromOffset(14 + (i - 1) * (bw + 8), 120)
            end
            trustBtn.Visible = three
            trustBtn.Text = three and "Trust host" or ""
        elseif view == "settings" then
            local list = {}
            for h in pairs(trusted) do table.insert(list, h) end
            table.sort(list)
            trustLbl.Text = #list == 0 and "Trusted hosts: none this session" or ("Trusted hosts: " .. table.concat(list, ", "))
            clearBtn.Visible = #list > 0
        elseif view == "log" then
            renderLog()
        end

        local targetH = view == "settings" and SET_H or (view == "log" and LOG_H or REQ_H)
        if open then
            tw(frame, 0.3, { Size = UDim2.fromOffset(W_, targetH) })
        else
            frame.Size = UDim2.fromOffset(W_, targetH)
        end
        setOpen(true)
    end

    gear.MouseEnter:Connect(function() paintHeaderBtn(gear, false, true) end)
    gear.MouseLeave:Connect(function() paintHeaderBtn(gear, manual == "settings", false) end)
    logBtn.MouseEnter:Connect(function() paintHeaderBtn(logBtn, false, true) end)
    logBtn.MouseLeave:Connect(function() paintHeaderBtn(logBtn, manual == "log", false) end)
    gear.MouseButton1Click:Connect(function() manual = (manual == "settings") and nil or "settings"; self.refresh() end)
    logBtn.MouseButton1Click:Connect(function() manual = (manual == "log") and nil or "log"; self.refresh() end)
    pendingBtn.MouseButton1Click:Connect(function() manual = nil; self.refresh() end)

    return self
end

changed = function()
    if not ui then
        if #queue == 0 then return end
        local ok, res = pcall(buildUI)
        if not ok then
            -- never leave a script hanging forever behind a UI that failed to build
            warn("[Syn-Guard] UI failed to build: " .. tostring(res))
            for _, it in ipairs(table.clone(queue)) do resolve(it, false, "ui error") end
            return
        end
        ui = res
    end
    local ok, err = pcall(ui.refresh)
    if not ok then warn("[Syn-Guard] UI refresh failed: " .. tostring(err)) end
end

-- single RightShift listener (builds the UI on demand)
cloneref(game:GetService("UserInputService")).InputBegan:Connect(function(input, gpe)
    if gpe or input.KeyCode ~= TOGGLE_KEY then return end
    manual = (manual == "settings") and nil or "settings"
    if not ui then
        local ok, res = pcall(buildUI)
        if not ok then warn("[Syn-Guard] UI failed to build: " .. tostring(res)) manual = nil return end
        ui = res
    end
    pcall(ui.refresh)
end)
