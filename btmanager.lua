--[[--
Bluetooth device management for Read Aloud.

Detects the platform (Android / BlueZ-Linux / MTK-Kobo) and delegates to the
appropriate BT subsystem.  Also intercepts AVRCP media-button key events and
maps them to AudioPlayer actions.
@module koplugin.readaloud.btmanager
--]]--

local logger    = require("logger")
local UIManager = require("ui/uimanager")

-- Key codes for media buttons (Linux input event codes)
local KEY_PLAYPAUSE   = 164
local KEY_NEXTSONG    = 163
local KEY_PREVIOUSSONG = 165

-- ── platform detection ────────────────────────────────────────────────────────

local PLATFORM_ANDROID = "android"
local PLATFORM_BLUEZ   = "bluez"
local PLATFORM_MTK     = "mtk"
local PLATFORM_NONE    = "none"

local function detectPlatform()
    -- Android
    local ok, android = pcall(require, "android")
    if ok and android then return PLATFORM_ANDROID, android end

    -- MTK (Kobo) — check for Bluedroid D-Bus interface
    local f = io.popen('dbus-send --system --print-reply --dest=com.kobo.mtk.bluedroid / org.freedesktop.DBus.Introspectable.Introspect 2>/dev/null | head -1')
    if f then
        local r = f:read("*l")
        f:close()
        if r and r ~= "" then return PLATFORM_MTK, nil end
    end

    -- BlueZ (Linux desktop / some Kobo)
    local fb = io.popen('bluetoothctl --version 2>/dev/null')
    if fb then
        local rb = fb:read("*l")
        fb:close()
        if rb and rb ~= "" then return PLATFORM_BLUEZ, nil end
    end

    return PLATFORM_NONE, nil
end

-- ── dbus helper (MTK / BlueZ) ─────────────────────────────────────────────────

local function dbusCall(dest, path, iface, method, args)
    local cmd = string.format(
        'dbus-send --system --print-reply --dest="%s" "%s" "%s.%s" %s 2>/dev/null',
        dest, path, iface, method, args or ""
    )
    local f = io.popen(cmd)
    if not f then return nil end
    local result = f:read("*a")
    f:close()
    return result
end

-- ── bluetoothctl helper (BlueZ) ───────────────────────────────────────────────

local function btctlRun(cmd_str)
    local f = io.popen('bluetoothctl ' .. cmd_str .. ' 2>/dev/null')
    if not f then return "" end
    local r = f:read("*a")
    f:close()
    return r or ""
end

local function parseBtctlDevices(output)
    local devices = {}
    for mac, name in output:gmatch("Device (%S+) (.-)%s*\n") do
        table.insert(devices, { address = mac, name = name, paired = false, connected = false })
    end
    return devices
end

-- ── BTManager object ──────────────────────────────────────────────────────────

local BTManager = {}
BTManager.__index = BTManager

function BTManager:new(settings, audio_player)
    local o = setmetatable({}, BTManager)
    o.settings      = settings
    o.audio_player  = audio_player
    o._platform, o._android = detectPlatform()
    o._connected_address = settings:readSetting("bt_saved_address")
    o._connected_name    = nil
    logger.info("BTManager: platform =", o._platform)
    return o
end

-- ── scanning ──────────────────────────────────────────────────────────────────

-- Returns a list of { address, name, paired, connected }.
function BTManager:scan(callback)
    if self._platform == PLATFORM_ANDROID then
        return self:_scanAndroid(callback)
    elseif self._platform == PLATFORM_BLUEZ then
        return self:_scanBluez(callback)
    elseif self._platform == PLATFORM_MTK then
        return self:_scanMTK(callback)
    end
    if callback then callback({}) end
    return {}
end

function BTManager:_scanBluez(callback)
    -- Start discovery, wait 5 s, stop, list
    os.execute('bluetoothctl scan on > /dev/null 2>&1 &')
    UIManager:scheduleIn(5, function()
        os.execute('bluetoothctl scan off > /dev/null 2>&1')
        local out = btctlRun("devices")
        local devs = parseBtctlDevices(out)
        -- Mark paired
        local paired_out = btctlRun("paired-devices")
        local paired_set = {}
        for mac in paired_out:gmatch("Device (%S+)") do paired_set[mac] = true end
        for _, d in ipairs(devs) do
            d.paired    = paired_set[d.address] == true
            d.connected = (d.address == self._connected_address)
        end
        if callback then callback(devs) end
    end)
    return {}
end

function BTManager:_scanMTK(callback)
    -- MTK D-Bus scan
    dbusCall("com.kobo.mtk.bluedroid", "/com/kobo/mtk/bluedroid",
        "com.kobo.mtk.bluedroid", "StartDiscovery", "")
    UIManager:scheduleIn(5, function()
        dbusCall("com.kobo.mtk.bluedroid", "/com/kobo/mtk/bluedroid",
            "com.kobo.mtk.bluedroid", "CancelDiscovery", "")
        local out = dbusCall("com.kobo.mtk.bluedroid", "/com/kobo/mtk/bluedroid",
            "com.kobo.mtk.bluedroid", "GetDevices", "") or ""
        -- Parse D-Bus output: each device is string "NAME\tADDR"
        local devs = {}
        for name, addr in out:gmatch('"([^"]+)\\t([%x:]+)"') do
            table.insert(devs, { address = addr, name = name, paired = false, connected = false })
        end
        if callback then callback(devs) end
    end)
    return {}
end

function BTManager:_scanAndroid(callback)
    -- Android BT scan uses system intents; not directly accessible from Lua.
    -- Return empty list and let the user pair via system Settings.
    logger.info("BTManager: Android BT scan not available from plugin; use system Settings")
    if callback then
        UIManager:scheduleIn(0.1, function() callback({}) end)
    end
    return {}
end

-- ── pairing / connection ──────────────────────────────────────────────────────

function BTManager:pair(address, callback)
    if self._platform == PLATFORM_BLUEZ then
        local out = btctlRun('pair ' .. address)
        local ok  = out:find("Pairing successful") ~= nil
        if callback then callback(ok) end
        return ok
    elseif self._platform == PLATFORM_MTK then
        local out = dbusCall("com.kobo.mtk.bluedroid", "/com/kobo/mtk/bluedroid",
            "com.kobo.mtk.bluedroid", "CreateBond",
            string.format('string:"%s"', address)) or ""
        local ok = out:find("boolean true") ~= nil
        if callback then callback(ok) end
        return ok
    end
    if callback then callback(false) end
    return false
end

function BTManager:connect(address)
    if self._platform == PLATFORM_BLUEZ then
        local out = btctlRun('connect ' .. address)
        if out:find("Connection successful") then
            self._connected_address = address
            self.settings:saveSetting("bt_saved_address", address)
            self.settings:flush()
            return true
        end
    elseif self._platform == PLATFORM_MTK then
        local out = dbusCall("com.kobo.mtk.bluedroid", "/com/kobo/mtk/bluedroid",
            "com.kobo.mtk.bluedroid", "Connect",
            string.format('string:"%s"', address)) or ""
        if out:find("boolean true") then
            self._connected_address = address
            self.settings:saveSetting("bt_saved_address", address)
            self.settings:flush()
            return true
        end
    elseif self._platform == PLATFORM_ANDROID then
        logger.info("BTManager: Android connection managed by system")
        self._connected_address = address
        self.settings:saveSetting("bt_saved_address", address)
        self.settings:flush()
        return true
    end
    return false
end

function BTManager:disconnect()
    if not self._connected_address then return end
    local addr = self._connected_address
    if self._platform == PLATFORM_BLUEZ then
        btctlRun('disconnect ' .. addr)
    elseif self._platform == PLATFORM_MTK then
        dbusCall("com.kobo.mtk.bluedroid", "/com/kobo/mtk/bluedroid",
            "com.kobo.mtk.bluedroid", "Disconnect",
            string.format('string:"%s"', addr))
    end
    self._connected_address = nil
end

function BTManager:forgetDevice()
    self:disconnect()
    self.settings:saveSetting("bt_saved_address", nil)
    self.settings:saveSetting("bt_auto_connect", false)
    self.settings:flush()
end

-- ── auto-connect ──────────────────────────────────────────────────────────────

function BTManager:autoConnect()
    if not self.settings:isTrue("bt_auto_connect") then return end
    local addr = self.settings:readSetting("bt_saved_address")
    if not addr or addr == "" then return end
    logger.info("BTManager: auto-connecting to", addr)
    self:connect(addr)
end

-- ── media-key interception ────────────────────────────────────────────────────

-- Register an InputContainer key handler table that can be merged into the
-- plugin's key_events.  main.lua does:  self.key_events = BTManager:keyEvents()
function BTManager:keyEvents()
    local ap = self.audio_player
    return {
        MediaPlayPause = {
            { "MediaPlayPause" },
            doc = "Toggle play/pause",
            event = "MediaPlayPause",
        },
        MediaNext = {
            { "MediaNext" },
            doc = "Next chapter",
            event = "MediaNext",
        },
        MediaPrev = {
            { "MediaPrev" },
            doc = "Previous chapter",
            event = "MediaPrev",
        },
    }
end

function BTManager:getConnectedAddress()
    return self._connected_address
end

function BTManager:getPlatform()
    return self._platform
end

return BTManager
