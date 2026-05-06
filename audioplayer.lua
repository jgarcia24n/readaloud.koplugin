--[[--
Cross-platform audio player with a sequential file queue.

Backend priority:
  1. Android MediaPlayer (via Java JNI bridge, androidplayer.lua)
  2. ffplay subprocess
  3. mpv subprocess
  4. mplayer subprocess
  5. gst-play-1.0 subprocess

Position is tracked via MediaPlayer.getCurrentPosition() on Android, or a
monotonic clock on subprocess backends, so callers can map it to SMIL entries.
@module koplugin.readaloud.audioplayer
--]]--

local logger    = require("logger")
local UIManager = require("ui/uimanager")

-- Directory containing this file (= plugin root), used to locate the .dex.
local _PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$") or "."

-- High-resolution time.  Prefer LuaSocket; fall back to os.time().
local function gettime()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then
        gettime = socket.gettime
        return socket.gettime()
    end
    gettime = function() return os.time() end
    return os.time()
end

-- ── backend detection ─────────────────────────────────────────────────────────

local function getKOReaderDir()
    local ok, ds = pcall(require, "datastorage")
    if ok and ds and ds.getDataDir then
        local data_dir = ds:getDataDir()
        if data_dir then
            return data_dir:match("^(.*)/[^/]+/?$") or ""
        end
    end
    return ""
end

local _koreader_dir = nil
local function hasBinary(name)
    local f = io.popen('which "' .. name .. '" 2>/dev/null')
    if f then
        local r = f:read("*l")
        f:close()
        if r and r ~= "" then return true, r end
    end
    if _koreader_dir == nil then
        _koreader_dir = getKOReaderDir()
    end
    if _koreader_dir ~= "" then
        local candidate = _koreader_dir .. "/" .. name
        local fh = io.open(candidate, "r")
        if fh then fh:close(); return true, candidate end
    end
    return false, nil
end

-- Returns backend_name, backend_obj_or_nil, bin_path_or_nil
local function detectBackend()
    -- Android: Java MediaPlayer via JNI bridge
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device:isAndroid() then
        local ok_ap, AndroidPlayer = pcall(require, "androidplayer")
        if ok_ap and AndroidPlayer then
            local player = AndroidPlayer:new{ plugin_dir = _PLUGIN_DIR }
            if player:init() then
                return "androidmp", player, nil
            end
            logger.warn("AudioPlayer: androidplayer init failed")
        else
            logger.warn("AudioPlayer: androidplayer module not available:", tostring(AndroidPlayer))
        end
    end

    local found, path
    found, path = hasBinary("ffplay")
    if found then return "ffplay", nil, path end
    found, path = hasBinary("mpv")
    if found then return "mpv", nil, path end
    found, path = hasBinary("mplayer")
    if found then return "mplayer", nil, path end
    found, path = hasBinary("gst-play-1.0")
    if found then return "gst", nil, path end
    logger.warn("AudioPlayer: no playback backend found")
    return nil, nil, nil
end

-- ── AudioPlayer object ────────────────────────────────────────────────────────

local AudioPlayer = {}
AudioPlayer.__index = AudioPlayer

function AudioPlayer:new()
    local o = setmetatable({}, AudioPlayer)
    o._android_player    = nil   -- AndroidPlayer instance

    o.file_queue         = {}    -- { {path=..., duration_s=...}, ... }
    o.current_idx        = 0
    o.global_start_s     = 0
    o.play_start_time    = 0
    o.is_playing         = false
    o.is_paused          = false

    o.volume             = 80    -- 0–100
    o.speed              = 1.0

    o._proc_pid          = nil
    o._poll_scheduled    = false

    o.on_track_end_cb        = nil
    o.on_position_update_cb  = nil

    local backend, backend_obj, bin_path = detectBackend()
    o.backend   = backend
    o._bin_path = bin_path
    if backend == "androidmp" then
        o._android_player = backend_obj
    end

    logger.info("AudioPlayer: backend =", o.backend or "none", bin_path or "")
    return o
end

-- ── internal helpers ──────────────────────────────────────────────────────────

-- Returns global_s, local_s, file_idx for the current playback position.
function AudioPlayer:_currentPosition()
    if not self.is_playing then
        return self.global_start_s, 0, self.current_idx
    end

    local global_s
    if self.backend == "androidmp" and self._android_player then
        -- Actual position from MediaPlayer — more accurate than the clock.
        local local_ms    = self._android_player:getCurrentPositionMs()
        local file_offset = self:_globalOffsetOfFile(self.current_idx)
        global_s = file_offset + local_ms / 1000
    else
        local elapsed = (gettime() - self.play_start_time) * self.speed
        global_s = self.global_start_s + elapsed
    end

    local accum = 0
    for i, finfo in ipairs(self.file_queue) do
        local next_accum = accum + (finfo.duration_s or 0)
        if i == #self.file_queue or global_s < next_accum then
            return global_s, global_s - accum, i
        end
        accum = next_accum
    end
    return global_s, 0, self.current_idx
end

-- Global time offset (seconds) at the start of file at index idx.
function AudioPlayer:_globalOffsetOfFile(idx)
    local accum = 0
    for i = 1, idx - 1 do
        accum = accum + (self.file_queue[i] and self.file_queue[i].duration_s or 0)
    end
    return accum
end

function AudioPlayer:_killSubprocess()
    if self._proc_pid then
        os.execute(string.format("kill %d 2>/dev/null", self._proc_pid))
        self._proc_pid = nil
    end
end

local function readPidFile(pid_file)
    local f = io.open(pid_file, "r")
    if not f then return nil end
    local pid = f:read("*n")
    f:close()
    return pid
end

local function isPidRunning(pid)
    if not pid then return false end
    local ret = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
    return ret == true or ret == 0
end

-- ── subprocess launch ─────────────────────────────────────────────────────────

local PIDFILE = "/tmp/readaloud_player.pid"

local function buildSubprocessCmd(backend, bin_path, file_path, offset_s, volume, speed)
    local vol_pct = math.floor(volume)
    local bin = bin_path or backend
    if backend == "ffplay" then
        return string.format(
            '"%s" -nodisp -autoexit -ss %.3f -af "volume=%.2f,atempo=%.3f" "%s" > /dev/null 2>&1 & echo $! > "%s"',
            bin, offset_s, vol_pct / 100, speed, file_path, PIDFILE)
    elseif backend == "mpv" then
        return string.format(
            '"%s" --no-video --start=%.3f --volume=%d --speed=%.3f "%s" > /dev/null 2>&1 & echo $! > "%s"',
            bin, offset_s, vol_pct, speed, file_path, PIDFILE)
    elseif backend == "mplayer" then
        return string.format(
            '"%s" -ss %.3f -volume %d -speed %.3f -noconsolecontrols "%s" > /dev/null 2>&1 & echo $! > "%s"',
            bin, offset_s, vol_pct, speed, file_path, PIDFILE)
    elseif backend == "gst" then
        return string.format(
            'gst-launch-1.0 filesrc location="%s" ! decodebin ! audioconvert ! volume volume=%.2f ! autoaudiosink > /dev/null 2>&1 & echo $! > "%s"',
            file_path, vol_pct / 100, PIDFILE)
    end
    return nil
end

function AudioPlayer:_launchSubprocess(file_path, offset_s)
    self:_killSubprocess()
    local cmd = buildSubprocessCmd(self.backend, self._bin_path, file_path, offset_s, self.volume, self.speed)
    if not cmd then
        logger.err("AudioPlayer: cannot build command for backend:", self.backend)
        return false
    end
    os.execute(cmd)
    local pid
    for _ = 1, 20 do
        pid = readPidFile(PIDFILE)
        if pid then break end
        local t = gettime() + 0.005
        while gettime() < t do end
    end
    self._proc_pid = pid
    logger.dbg("AudioPlayer: launched PID", pid, "file", file_path)
    return true
end

-- ── position polling ──────────────────────────────────────────────────────────

function AudioPlayer:_schedulePoll()
    if not self.is_playing or self._poll_scheduled then return end
    self._poll_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._poll_scheduled = false
        if not self.is_playing then return end

        local global_s, local_s, idx = self:_currentPosition()

        if self.on_position_update_cb then
            pcall(self.on_position_update_cb, global_s, local_s, idx)
        end

        -- Detect track completion
        if self.backend == "androidmp" then
            if self._android_player and self._android_player:isPlaybackDone() then
                self:_advanceQueue()
                return
            end
        elseif self._proc_pid and not isPidRunning(self._proc_pid) then
            self:_advanceQueue()
            return
        end

        self:_schedulePoll()
    end)
end

function AudioPlayer:_advanceQueue()
    self._proc_pid = nil
    if self.current_idx >= #self.file_queue then
        self.is_playing = false
        logger.dbg("AudioPlayer: queue finished")
        if self.on_track_end_cb then pcall(self.on_track_end_cb) end
        return
    end

    local next_idx  = self.current_idx + 1
    local next_file = self.file_queue[next_idx]
    logger.dbg("AudioPlayer: advancing to file", next_idx, next_file.path)

    self.global_start_s  = self:_globalOffsetOfFile(next_idx)
    self.play_start_time = gettime()
    self.current_idx     = next_idx

    if self.backend == "androidmp" and self._android_player then
        self._android_player:playFile(next_file.path)
    else
        self:_launchSubprocess(next_file.path, 0)
    end

    self:_schedulePoll()
end

-- ── public API ────────────────────────────────────────────────────────────────

-- file_list: { {path=..., duration_s=...}, ... }
-- start_global_s: position in the global timeline to begin from
function AudioPlayer:play(file_list, start_global_s)
    if not self.backend then
        logger.err("AudioPlayer: no playback backend available")
        return false
    end

    self:stop()
    self.file_queue  = file_list
    self.is_playing  = true
    self.is_paused   = false
    start_global_s   = start_global_s or 0

    -- Locate the file and local offset for start_global_s
    local accum = 0
    local start_idx, start_local = 1, 0
    for i, finfo in ipairs(file_list) do
        local next_accum = accum + (finfo.duration_s or 0)
        if i == #file_list or start_global_s < next_accum then
            start_idx   = i
            start_local = math.max(0, start_global_s - accum)
            break
        end
        accum = next_accum
    end

    self.current_idx     = start_idx
    self.global_start_s  = start_global_s
    self.play_start_time = gettime()

    local file_path = file_list[start_idx].path

    if self.backend == "androidmp" and self._android_player then
        local offset_ms = math.floor(start_local * 1000)
        if offset_ms > 0 then
            self._android_player:playFileFrom(file_path, offset_ms)
        else
            self._android_player:playFile(file_path)
        end
    else
        self:_launchSubprocess(file_path, start_local)
    end

    self:_schedulePoll()
    return true
end

function AudioPlayer:pause()
    if not self.is_playing or self.is_paused then return end
    self.is_paused      = true
    local global_s      = self:_currentPosition()
    self.global_start_s = global_s

    if self.backend == "androidmp" and self._android_player then
        self._android_player:pausePlayback()
    else
        self:_killSubprocess()
    end
    logger.dbg("AudioPlayer: paused at", global_s)
end

function AudioPlayer:resume()
    if not self.is_paused then return end
    self.is_paused       = false
    self.play_start_time = gettime()

    if self.backend == "androidmp" and self._android_player then
        self._android_player:resumePlayback()
    else
        -- Subprocess backends must restart from the saved position
        local accum = 0
        local play_idx, play_local = self.current_idx, 0
        for i, finfo in ipairs(self.file_queue) do
            local next_accum = accum + (finfo.duration_s or 0)
            if i == #self.file_queue or self.global_start_s < next_accum then
                play_idx   = i
                play_local = math.max(0, self.global_start_s - accum)
                break
            end
            accum = next_accum
        end
        self.current_idx = play_idx
        local finfo = self.file_queue[play_idx]
        if finfo then self:_launchSubprocess(finfo.path, play_local) end
    end

    self:_schedulePoll()
    logger.dbg("AudioPlayer: resumed at global", self.global_start_s)
end

function AudioPlayer:stop()
    self.is_playing = false
    self.is_paused  = false
    if self.backend == "androidmp" and self._android_player then
        self._android_player:stopPlayback()
    else
        self:_killSubprocess()
    end
    self.file_queue     = {}
    self.current_idx    = 0
    self.global_start_s = 0
end

-- Seek to an absolute position in the global timeline.
function AudioPlayer:seek(global_s)
    if #self.file_queue == 0 then return end

    local was_playing    = self.is_playing and not self.is_paused
    self:pause()
    self.global_start_s  = global_s
    self.play_start_time = gettime()

    local accum = 0
    for i, finfo in ipairs(self.file_queue) do
        local next_accum = accum + (finfo.duration_s or 0)
        if i == #self.file_queue or global_s < next_accum then
            self.current_idx = i
            local local_s    = math.max(0, global_s - accum)
            self.is_paused   = false
            if was_playing then
                self.is_playing = true
                if self.backend == "androidmp" and self._android_player then
                    local offset_ms = math.floor(local_s * 1000)
                    if offset_ms > 0 then
                        self._android_player:playFileFrom(finfo.path, offset_ms)
                    else
                        self._android_player:playFile(finfo.path)
                    end
                else
                    self:_launchSubprocess(finfo.path, local_s)
                end
                self:_schedulePoll()
            end
            return
        end
        accum = next_accum
    end
end

-- Returns global_s, local_s, file_index
function AudioPlayer:getPosition()
    return self:_currentPosition()
end

function AudioPlayer:setVolume(vol)
    self.volume = math.max(0, math.min(100, vol))
    if self.backend == "androidmp" and self._android_player then
        self._android_player:setVolume(self.volume / 100)
    end
    -- Subprocess backends: takes effect at next play/seek.
end

function AudioPlayer:setSpeed(speed)
    self.speed = speed
    -- Android: MediaPlayer speed requires API 23+; takes effect at next play/seek.
    -- Subprocess backends: takes effect at next play/seek.
end

function AudioPlayer:onTrackEnd(cb)
    self.on_track_end_cb = cb
end

function AudioPlayer:onPositionUpdate(cb)
    self.on_position_update_cb = cb
end

function AudioPlayer:isPlaying()
    return self.is_playing and not self.is_paused
end

function AudioPlayer:isPaused()
    return self.is_paused
end

-- Returns the AndroidPlayer instance, or nil on non-Android.
-- Used by epubparser to extract ZIP entries via Java without a shell unzip.
function AudioPlayer:getAndroidPlayer()
    return self._android_player
end

return AudioPlayer
