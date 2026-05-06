--[[--
Read Aloud — EPUB3 Media Overlay player for KOReader.

Plays audio files associated with an EPUB3 book while highlighting the currently
spoken text element.  Works on Android, Kobo, Kindle and desktop Linux.
@module koplugin.readaloud
--]]--

local DataStorage       = require("datastorage")
local Dispatcher        = require("dispatcher")
local Event             = require("ui/event")
local InfoMessage       = require("ui/widget/infomessage")
local InputContainer    = require("ui/widget/container/inputcontainer")
local LuaSettings       = require("luasettings")
local UIManager         = require("ui/uimanager")
local logger            = require("logger")
local _                 = require("gettext")

-- Local plugin modules are lazy-required inside init() so that the plugin
-- directory is guaranteed to be on package.path before we load them.
local EpubParser, SmilParser, AudioPlayer
local HighlightManager, PlaybackBar, BTManager, BtUI, MenuBuilder

-- ── ReadAloudPlugin ───────────────────────────────────────────────────────────

local ReadAloudPlugin = InputContainer:extend{
    name        = "readaloud",
    is_doc_only = true,
}

-- ── settings ──────────────────────────────────────────────────────────────────

local SETTINGS_DEFAULTS = {
    highlight_style        = "background",
    playback_speed         = 1.0,
    volume                 = 80,
    auto_page_turn         = true,
    keep_playing_lid_closed = false,
    bt_auto_connect        = false,
    bt_saved_address       = nil,
}

local function openSettings()
    local s = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/readaloud.lua"
    )
    -- Inject isTrue helper if not present (older KOReader builds).
    -- Falls back to SETTINGS_DEFAULTS so boolean settings work on first run.
    if not s.isTrue then
        s.isTrue = function(self, key)
            local v = self:readSetting(key, SETTINGS_DEFAULTS[key])
            return v == true or v == "true"
        end
    end
    return s
end

-- ── dispatcher actions ────────────────────────────────────────────────────────

function ReadAloudPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("readaloud_play_beginning", {
        category = "none",
        event    = "ReadAloudPlayBeginning",
        title    = _("Read Aloud: play from beginning"),
        general  = true,
    })
    Dispatcher:registerAction("readaloud_play_here", {
        category = "none",
        event    = "ReadAloudPlayHere",
        title    = _("Read Aloud: read from here"),
        general  = true,
    })
    Dispatcher:registerAction("readaloud_toggle", {
        category = "none",
        event    = "ReadAloudToggle",
        title    = _("Read Aloud: pause / resume"),
        general  = true,
    })
    Dispatcher:registerAction("readaloud_stop", {
        category = "none",
        event    = "ReadAloudStop",
        title    = _("Read Aloud: stop"),
        general  = true,
    })
    Dispatcher:registerAction("readaloud_prev_chapter", {
        category = "none",
        event    = "ReadAloudPrevChapter",
        title    = _("Read Aloud: previous chapter"),
        general  = true,
    })
    Dispatcher:registerAction("readaloud_next_chapter", {
        category = "none",
        event    = "ReadAloudNextChapter",
        title    = _("Read Aloud: next chapter"),
        general  = true,
    })
end

-- ── init ──────────────────────────────────────────────────────────────────────

function ReadAloudPlugin:init()
    -- Resolve plugin directory so we can load submodules by absolute path.
    -- Using dofile() instead of require() prevents identically-named modules in
    -- other installed plugins (e.g. audiobook.koplugin) from shadowing ours via
    -- the shared package.path / require cache.
    local plugin_dir = self.path and (self.path .. "/")
        or debug.getinfo(2, "S").source:match("^@(.*/)[^/]*$")
        or "./"

    EpubParser       = dofile(plugin_dir .. "epubparser.lua")
    SmilParser       = dofile(plugin_dir .. "smilparser.lua")
    AudioPlayer      = dofile(plugin_dir .. "audioplayer.lua")
    HighlightManager = dofile(plugin_dir .. "highlightmanager.lua")
    PlaybackBar      = dofile(plugin_dir .. "playbackbar.lua")
    BTManager        = dofile(plugin_dir .. "btmanager.lua")
    BtUI             = dofile(plugin_dir .. "btui.lua")
    MenuBuilder      = dofile(plugin_dir .. "menubuilder.lua")

    self:onDispatcherRegisterActions()
    self.settings = openSettings()

    -- Audio player (backend auto-detected)
    self.audio_player = AudioPlayer:new()
    self.audio_player:setVolume(self.settings:readSetting("volume", 80))
    self.audio_player:setSpeed(self.settings:readSetting("playback_speed", 1.0))

    -- Bluetooth manager
    self.bt_manager = BTManager:new(self.settings, self.audio_player)

    -- Highlight manager (document wired in onReaderReady)
    self.highlight_manager = nil

    -- Playback state
    self.timeline        = nil   -- global SMIL timeline
    self.audio_seq       = nil   -- ordered audio file list for AudioPlayer
    self.audio_durations = nil
    self.audio_global_start = nil
    self.total_duration  = 0
    self._last_entry_idx = nil
    self._chapter_titles = {}

    -- Playback bar
    self.playback_bar = PlaybackBar:new{
        on_play_pause = function() self:onReadAloudToggle() end,
        on_rewind     = function() self:onReadAloudPrevSentence() end,
        on_forward    = function() self:onReadAloudNextSentence() end,
        on_close      = function() self:onReadAloudStop() end,
        on_realign    = function() self:onReadAloudRealign() end,
    }

    -- Wire AudioPlayer position updates
    self.audio_player:onPositionUpdate(function(global_s)
        self:_onPositionUpdate(global_s)
    end)
    self.audio_player:onTrackEnd(function()
        logger.dbg("ReadAloud: audio queue finished")
        self.playback_bar:update(self.total_duration, self.total_duration, nil, false)
    end)

    -- Key events (media buttons from BT headset)
    self.key_events = {
        MediaPlayPause = {
            { "MediaPlayPause" },
            doc   = "Toggle Read Aloud play/pause",
            event = "ReadAloudToggle",
        },
        MediaNext = {
            { "MediaNext" },
            doc   = "Read Aloud next chapter",
            event = "ReadAloudNextChapter",
        },
        MediaPrev = {
            { "MediaPrev" },
            doc   = "Read Aloud previous chapter",
            event = "ReadAloudPrevChapter",
        },
    }

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

-- ── menu registration ─────────────────────────────────────────────────────────

function ReadAloudPlugin:addToMainMenu(menu_items)
    local s  = self.settings
    local ap = self.audio_player

    menu_items.readaloud = {
        text         = _("Read Aloud"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text     = _("Play from beginning"),
                callback = function() self:onReadAloudPlayBeginning() end,
            },
            {
                text     = _("Pause / Resume"),
                callback = function() self:onReadAloudToggle() end,
            },
            {
                text     = _("Stop"),
                callback = function() self:onReadAloudStop() end,
            },
            { text = "---" },
            {
                text     = _("Previous chapter"),
                callback = function() self:onReadAloudPrevChapter() end,
            },
            {
                text     = _("Next chapter"),
                callback = function() self:onReadAloudNextChapter() end,
            },
            { text = "---" },
            MenuBuilder.buildHighlightStyleMenu(self, s),
            MenuBuilder.buildPlaybackSpeedMenu(self, s, ap),
            MenuBuilder.buildVolumeMenu(self, s, ap),
            MenuBuilder.buildAutoScrollMenu(self, s),
            MenuBuilder.buildKeepPlayingMenu(self, s),
            { text = "---" },
            BtUI:build(self, self.bt_manager, s),
        },
    }
end

-- Called from btui.lua when a BT setting changes.
-- Menu callbacks are closures so state is always current; nothing to do here.
function ReadAloudPlugin:reloadMenu()
end

-- ── document lifecycle ────────────────────────────────────────────────────────

function ReadAloudPlugin:onReaderReady()
    self._has_overlays = false
    self.timeline      = nil
    self.audio_seq     = nil
    self.total_duration = 0

    -- Register "Read aloud from here" in the text-selection popup.
    -- Done here (not init) so all reader modules are guaranteed ready.
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("15_readaloud_from_here", function(this)
            return {
                text = _("Start from here (ReadAloud)"),
                callback = function()
                    local sel = this.selected_text
                    local pos0 = sel and sel.pos0
                    local xp = pos0 and (type(pos0) == "string" and pos0 or (pos0.serialize and pos0:serialize()))
                    UIManager:scheduleIn(0.1, function()
                        self:_playFromXPointer(xp)
                    end)
                end,
            }
        end)
    else
        logger.warn("ReadAloud: addToHighlightDialog not available on this build")
    end

    local doc_path = self.ui and self.ui.document and self.ui.document.file
    if not doc_path then return end

    -- Only process EPUB files (.epub and Kobo's .kepub variant)
    local ext = doc_path:match("%.([^%.]+)$")
    if not ext or (ext:lower() ~= "epub" and ext:lower() ~= "kepub") then return end

    -- Parse epub in the background (non-blocking schedule)
    UIManager:scheduleIn(0.5, function()
        local ok, result = pcall(function()
            return EpubParser:parse(doc_path)
        end)
        if not ok or not result then
            logger.warn("ReadAloud: no media overlays or parse error:", result)
            return
        end

        local timeline, audio_seq, audio_durations, audio_global_start
            = SmilParser:buildGlobalTimeline(result.spine_items)

        if not timeline or #timeline == 0 then
            logger.warn("ReadAloud: empty timeline after SMIL parsing")
            return
        end

        self.timeline           = timeline
        self.audio_seq          = audio_seq
        self.audio_durations    = audio_durations
        self.audio_global_start = audio_global_start
        self._has_overlays      = true
        self._spine_items       = result.spine_items

        -- Build file list for AudioPlayer
        local file_list = {}
        local total = 0
        for _, af in ipairs(audio_seq) do
            local dur = audio_durations[af] or 0
            table.insert(file_list, { path = af, duration_s = dur })
            total = total + dur
        end
        self._file_list    = file_list
        self.total_duration = total

        -- Build per-chapter title table (xhtml filename → title)
        self:_buildChapterTitles(result.spine_items)

        -- Wire up highlight manager
        self.highlight_manager = HighlightManager:new(self.ui, self.settings)

        -- Auto-connect BT
        self.bt_manager:autoConnect()

        logger.info(string.format(
            "ReadAloud: ready — %d timeline entries, %d audio files, %.1f s total",
            #timeline, #audio_seq, total
        ))
    end)
end

-- Hook into the single-word dictionary popup to add "Read aloud from here".
function ReadAloudPlugin:onDictButtonsReady(dict_popup, buttons)
    if not self._has_overlays then return end
    if dict_popup.is_wiki_fullpage then return end

    local plugin = self
    table.insert(buttons, {{
        id        = "readaloud_read",
        text      = _("Start from here (ReadAloud)"),
        font_bold = false,
        callback  = function()
            local xp = nil
            if dict_popup.highlight and dict_popup.highlight.selected_text then
                local sel = dict_popup.highlight.selected_text
                local pos0 = sel.pos0
                xp = pos0 and (type(pos0) == "string" and pos0 or (pos0.serialize and pos0:serialize()))
            end
            UIManager:close(dict_popup)
            UIManager:scheduleIn(0.3, function()
                plugin:_playFromXPointer(xp)
            end)
        end,
    }})
end

function ReadAloudPlugin:onCloseDocument()
    self:onReadAloudStop()
    if self.highlight_manager then
        self.highlight_manager:reset()
        self.highlight_manager = nil
    end
    self.timeline       = nil
    self.audio_seq      = nil
    self._file_list     = nil
    self._has_overlays  = false
    self._spine_items   = nil
    self.playback_bar:hide()
end

-- ── playback actions ──────────────────────────────────────────────────────────

function ReadAloudPlugin:onReadAloudPlayBeginning()
    if not self._has_overlays or not self._file_list then
        UIManager:show(InfoMessage:new{
            text    = _("No audio available for this document."),
            timeout = 3,
        })
        return true
    end
    self._last_entry_idx = nil
    self._last_global_s  = nil
    self._play_from_guard = nil
    -- Navigate to the first audio chapter before playback starts so the
    -- highlight system finds the text immediately instead of auto-turning pages.
    -- getXPointerOfElementById is not available on all KOReader builds, so we
    -- construct a DocFragment XPointer from the spine item index instead.
    if self.timeline and self.timeline[1] and self._spine_items and self.ui then
        local first_fname = self.timeline[1].xhtml_file
        first_fname = first_fname and first_fname:match("([^/\\]+)$")
        for i, item in ipairs(self._spine_items) do
            local item_fname = item.xhtml_path and item.xhtml_path:match("([^/\\]+)$")
            if item_fname and first_fname and item_fname == first_fname then
                local xp = "/body/DocFragment[" .. i .. "]/body[1]"
                self.ui:handleEvent(Event:new("GotoXPointer", xp))
                self._play_from_guard = true
                break
            end
        end
    end
    if self.highlight_manager then self.highlight_manager:clearLineCache() end
    self.audio_player:play(self._file_list, 0)
    self.playback_bar:show()
    return true
end

function ReadAloudPlugin:onReadAloudPlayHere()
    if not self._has_overlays or not self.timeline then
        UIManager:show(InfoMessage:new{
            text    = _("No audio available for this document."),
            timeout = 3,
        })
        return true
    end
    self:_playFromXPointer(self:_getCurrentXPointer())
    return true
end

function ReadAloudPlugin:_playFromXPointer(xp)
    if not self._has_overlays or not self._file_list then return end
    self._last_entry_idx = nil
    self._last_global_s  = nil
    self._play_from_guard = nil
    -- Navigate to the starting XPointer so the correct page is rendered before
    -- the first position-update callback fires and tries to highlight the sentence.
    -- This prevents GotoViewRel +1 from firing blindly on a stale scroll position.
    if xp and self.ui then
        self.ui:handleEvent(Event:new("GotoXPointer", xp))
        -- Guard: _findTimelineOffset may resolve to the entry just before the
        -- selection (off-by-one in XPointer DOM walk).  Since GotoXPointer already
        -- placed us on the correct page, suppress navigation for the very first
        -- callback so that artifact entry doesn't jump us forward.
        self._play_from_guard = true
    end
    if self.highlight_manager then self.highlight_manager:clearLineCache() end
    local offset = self:_findTimelineOffset(xp)
    self.audio_player:play(self._file_list, offset)
    self.playback_bar:show()
end

function ReadAloudPlugin:onReadAloudToggle()
    if self.audio_player:isPlaying() then
        self.audio_player:pause()
        self.playback_bar:update(
            self.audio_player:getPosition(), self.total_duration, nil, false)
    elseif self.audio_player:isPaused() then
        self.audio_player:resume()
    else
        self:onReadAloudPlayHere()
    end
    return true
end

function ReadAloudPlugin:onReadAloudStop()
    self._last_entry_idx = nil
    self._last_global_s  = nil
    self._play_from_guard = nil
    if self._pre_turn_timer then
        UIManager:unschedule(self._pre_turn_timer)
        self._pre_turn_timer = nil
    end
    if self._overflow_turn_timer then
        UIManager:unschedule(self._overflow_turn_timer)
        self._overflow_turn_timer = nil
    end
    self.audio_player:stop()
    if self.highlight_manager then self.highlight_manager:clear() end
    self.playback_bar:hide()
    return true
end

function ReadAloudPlugin:onReadAloudPrevChapter()
    self:_seekChapter(-1)
    return true
end

function ReadAloudPlugin:onReadAloudNextChapter()
    self:_seekChapter(1)
    return true
end

function ReadAloudPlugin:onReadAloudPrevSentence()
    self:_seekSentence(-1)
    return true
end

function ReadAloudPlugin:onReadAloudNextSentence()
    self:_seekSentence(1)
    return true
end

function ReadAloudPlugin:onReadAloudRealign()
    if not self.timeline or not self.ui or not self.ui.document then return end
    local cur_s = self.audio_player:getPosition()
    local entry_idx = SmilParser:findActiveEntry(self.timeline, cur_s)
    if not entry_idx then return end
    local entry = self.timeline[entry_idx]
    local doc = self.ui.document
    for _, fname in ipairs{"getXPointerOfElementById", "getXPointerForId", "findXPointerById"} do
        local ok, xp = pcall(function() return doc[fname](doc, entry.text_id) end)
        if ok and type(xp) == "string" and xp ~= "" then
            self.ui:handleEvent(Event:new("GotoXPointer", xp))
            return
        end
    end
end

-- ── suspend / resume ──────────────────────────────────────────────────────────

function ReadAloudPlugin:onSuspend()
    if self.settings:isTrue("keep_playing_lid_closed") then return end
    if self.audio_player:isPlaying() then
        self._was_playing = true
        self.audio_player:pause()
    end
end

function ReadAloudPlugin:onResume()
    if self._was_playing then
        self._was_playing = false
        self.audio_player:resume()
    end
end

-- ── position-update callback (100 ms) ────────────────────────────────────────

function ReadAloudPlugin:_onPositionUpdate(global_s)
    if not self.timeline then return end

    -- Debounce tiny backward position jumps (< 200 ms) that occur when the audio
    -- position callback ticks at a sentence boundary and returns a value just before
    -- the previous tick's position.  Real user seeks are always larger than 200 ms.
    if self._last_global_s and global_s < self._last_global_s
       and (self._last_global_s - global_s) < 0.2 then
        logger.info("RA_DIAG posUpdate: ignoring backward blip " .. string.format("%.3f→%.3f", self._last_global_s, global_s))
        self.playback_bar:update(global_s, self.total_duration, nil, true)
        return
    end
    self._last_global_s = global_s

    -- Find active timeline entry
    local entry_idx = SmilParser:findActiveEntry(self.timeline, global_s)
    if entry_idx == self._last_entry_idx then
        -- Position changed but same par — just update bar
        self.playback_bar:update(global_s, self.total_duration, nil, true)
        return
    end

    -- Cancel any timers scheduled for the previous entry
    if self._pre_turn_timer then
        UIManager:unschedule(self._pre_turn_timer)
        self._pre_turn_timer = nil
    end
    if self._overflow_turn_timer then
        UIManager:unschedule(self._overflow_turn_timer)
        self._overflow_turn_timer = nil
    end

    self._last_entry_idx = entry_idx
    if not entry_idx then return end

    local entry = self.timeline[entry_idx]

    logger.info("RA_DIAG entry changed: idx=" .. entry_idx .. " text_id=" .. tostring(entry.text_id) .. " at t=" .. string.format("%.2f", global_s) .. "s")

    -- Update highlight
    if self.highlight_manager then
        local opts = {}
        if self._play_from_guard then
            self._play_from_guard = nil
            opts.no_navigate = true
            logger.info("RA_DIAG posUpdate: play_from_guard — suppressing nav for tid=" .. tostring(entry.text_id))
        end
        local ok, err = pcall(function()
            self.highlight_manager:highlight(entry.text_id, entry, opts)
        end)
        if not ok then
            logger.warn("ReadAloud: highlight error:", err)
        end
        -- Pre-turn the page before the next sentence starts if it won't be visible
        self:_scheduleProactiveTurn(entry_idx, global_s)
        -- Mid-sentence overflow turn when the current sentence spans a page boundary
        self:_scheduleOverflowTurn(entry_idx, global_s)
    end

    -- Update playback bar
    local chapter_title = self:_chapterTitleForEntry(entry)
    self.playback_bar:update(global_s, self.total_duration, chapter_title, true)
end

-- Schedules a page turn 150 ms before the next entry starts, but only when
-- the next sentence is confirmed absent from the current page's line cache.
function ReadAloudPlugin:_scheduleProactiveTurn(entry_idx, global_s)
    if not self.highlight_manager then return end
    local auto_turn = not self.settings
        or self.settings:readSetting("auto_page_turn", true) ~= false
    if not auto_turn then return end

    local next_entry = self.timeline[entry_idx + 1]
    if not next_entry then return end

    local time_until_next = next_entry.global_offset_s - global_s
    logger.info("RA_DIAG proactive: cur_idx=" .. entry_idx .. " next_tid=" .. tostring(next_entry.text_id) .. " time_until_next=" .. string.format("%.2f", time_until_next))
    if time_until_next < 0.25 then
        logger.info("RA_DIAG proactive: skipping (too close, < 0.25s)")
        return
    end

    -- Only turn when next sentence is confirmed off-screen.
    -- isNextTextVisible returns nil when the cache isn't built yet, so we
    -- require an explicit false to avoid false-positive page turns.
    local visible = self.highlight_manager:isNextTextVisible(
        next_entry.xhtml_file, next_entry.text_id)
    logger.info("RA_DIAG proactive: isNextTextVisible=" .. tostring(visible) .. " — " .. (visible == false and "WILL schedule turn" or "will NOT schedule turn"))
    if visible ~= false then return end

    local delay = time_until_next - 0.15
    if delay <= 0 then return end

    -- Resolve the XPointer now (before the timer fires) so we know navigation
    -- will be precise.  GotoViewRel +1 is not used for proactive turns because
    -- it can overshoot by whole pages, landing PAST the target sentence.
    local doc = self.ui and self.ui.document
    local next_xp = nil
    if doc then
        for _, fname in ipairs{"getXPointerOfElementById","getXPointerForId","findXPointerById"} do
            local ok, xp = pcall(function() return doc[fname](doc, next_entry.text_id) end)
            if ok and type(xp) == "string" and xp ~= "" then
                next_xp = xp
                break
            end
        end
    end
    if not next_xp then
        logger.info("RA_DIAG proactive: no XPointer for " .. tostring(next_entry.text_id) .. " — skipping proactive turn (GotoViewRel too imprecise)")
        return
    end

    logger.info("RA_DIAG proactive: scheduling XPointer turn in " .. string.format("%.2f", delay) .. "s for next_tid=" .. tostring(next_entry.text_id))
    local captured_xp = next_xp
    local next_tid = next_entry.text_id
    local fn
    fn = function()
        self._pre_turn_timer = nil
        if not self.audio_player:isPlaying() then return end
        logger.info("RA_DIAG proactive: TURN FIRED for next_tid=" .. tostring(next_tid) .. " xp=" .. captured_xp:sub(1,60))
        self.ui:handleEvent(Event:new("GotoXPointer", captured_xp))
        self.highlight_manager:clearLineCache()
    end
    self._pre_turn_timer = fn
    UIManager:scheduleIn(delay, fn)
end

-- Schedules a mid-sentence page turn when the current sentence overflows onto
-- the next page.  Uses getVisibleTextFraction() to estimate what fraction of the
-- sentence text is on the current page, then schedules GotoViewRel +1 at that
-- fraction of the sentence's remaining audio time.  After turning, re-highlights
-- the tail of the sentence on the new page with no_navigate=true to avoid a
-- second navigation trigger.
function ReadAloudPlugin:_scheduleOverflowTurn(entry_idx, global_s)
    if self._overflow_turn_timer then
        UIManager:unschedule(self._overflow_turn_timer)
        self._overflow_turn_timer = nil
    end
    if not self.highlight_manager then return end
    local auto_turn = not self.settings
        or self.settings:readSetting("auto_page_turn", true) ~= false
    if not auto_turn then return end

    local entry = self.timeline[entry_idx]
    if not entry then return end

    local frac = self.highlight_manager:getVisibleTextFraction(entry.xhtml_file, entry.text_id)
    logger.info("RA_DIAG overflow: tid=" .. tostring(entry.text_id) .. " frac=" .. string.format("%.2f", frac))
    if frac >= 0.85 then return end  -- sentence fits (or nearly fits) on current page

    local next_entry = self.timeline[entry_idx + 1]
    -- If the next sentence is already visible on screen, the current sentence has not
    -- truly overflowed onto another page — skip the overflow turn to avoid navigating
    -- away from the correct page.
    if next_entry then
        local vis = self.highlight_manager:isNextTextVisible(next_entry.xhtml_file, next_entry.text_id)
        if vis then
            logger.info("RA_DIAG overflow: next sentence visible — skipping overflow turn for tid=" .. tostring(entry.text_id))
            return
        end
    end
    local global_end = next_entry and next_entry.global_offset_s or self.total_duration
    local sentence_remaining = global_end - global_s
    if sentence_remaining < 0.3 then return end

    -- Use text fraction as a proxy for how far into the audio the page break falls.
    -- Clamp to 0.3 s minimum: when only a word or two is visible (frac near 0),
    -- sentence_remaining * frac collapses to nearly zero and the old < 0.15 guard
    -- would bail out, preventing the turn entirely.  We want to turn quickly in
    -- that case, not skip.
    local turn_delay = math.max(0.3, sentence_remaining * frac)

    local tid = entry.text_id
    local entry_ref = entry
    logger.info("RA_DIAG overflow: scheduling GotoViewRel +1 in " .. string.format("%.2f", turn_delay) .. "s for tid=" .. tostring(tid))
    local fn
    fn = function()
        self._overflow_turn_timer = nil
        if not self.audio_player:isPlaying() then return end
        if not self.highlight_manager then return end
        if self.highlight_manager.last_text_id ~= tid then return end
        logger.info("RA_DIAG overflow: TURN FIRED for tid=" .. tostring(tid))
        self.ui:handleEvent(Event:new("GotoViewRel", 1))
        self.highlight_manager:clearLineCache()
        -- Re-highlight the tail of the sentence on the new page.
        -- no_navigate=true prevents a second GotoViewRel from firing here.
        UIManager:scheduleIn(0.15, function()
            if not self.highlight_manager then return end
            if self.highlight_manager.last_text_id ~= tid then return end
            self.highlight_manager:clear()
            self.highlight_manager:highlight(tid, entry_ref, {no_navigate = true})
        end)
    end
    self._overflow_turn_timer = fn
    UIManager:scheduleIn(turn_delay, fn)
end

-- ── chapter navigation ────────────────────────────────────────────────────────

-- offset: -1 for prev, +1 for next
function ReadAloudPlugin:_seekChapter(offset)
    if not self.timeline or not self._file_list then return end

    local cur_s = self.audio_player:getPosition()
    local cur_idx = SmilParser:findActiveEntry(self.timeline, cur_s) or 1
    local cur_entry = self.timeline[cur_idx]
    if not cur_entry then return end

    -- Identify the current chapter's first timeline entry
    local cur_xhtml = cur_entry.xhtml_file

    -- Walk forward/backward to find the boundary of the next/prev chapter
    local target_s
    if offset > 0 then
        -- Find the first entry of the next chapter
        for i = cur_idx + 1, #self.timeline do
            local e = self.timeline[i]
            if e.xhtml_file ~= cur_xhtml then
                target_s = e.global_offset_s
                break
            end
        end
        if not target_s then
            target_s = self.total_duration   -- end of book
        end
    else
        -- Find the first entry of the current chapter, then go to the previous
        local first_of_cur = cur_idx
        for i = cur_idx - 1, 1, -1 do
            if self.timeline[i].xhtml_file == cur_xhtml then
                first_of_cur = i
            else
                break
            end
        end
        if first_of_cur > 1 and cur_s - self.timeline[first_of_cur].global_offset_s < 3 then
            -- We're near the start of this chapter → go to previous chapter
            for i = first_of_cur - 1, 1, -1 do
                local e = self.timeline[i]
                if e.xhtml_file ~= self.timeline[first_of_cur].xhtml_file then
                    -- Find the real start of that chapter
                    local prev_xhtml = e.xhtml_file
                    for j = i, 1, -1 do
                        if self.timeline[j].xhtml_file ~= prev_xhtml then
                            target_s = self.timeline[j+1].global_offset_s
                            break
                        end
                    end
                    if not target_s then
                        target_s = self.timeline[i].global_offset_s
                    end
                    break
                end
            end
        end
        if not target_s then
            -- Restart current chapter
            target_s = self.timeline[first_of_cur].global_offset_s
        end
    end

    self.audio_player:seek(target_s)
end

function ReadAloudPlugin:_seekSentence(offset)
    if not self.timeline then return end
    local cur_s = self.audio_player:getPosition()
    local cur_idx = SmilParser:findActiveEntry(self.timeline, cur_s) or 1
    local target_idx
    if offset > 0 then
        target_idx = math.min(cur_idx + 1, #self.timeline)
    else
        -- If we're more than 2 seconds into the current sentence, restart it;
        -- otherwise jump to the previous sentence.
        local entry_start = self.timeline[cur_idx].global_offset_s
        if cur_s - entry_start > 2 then
            target_idx = cur_idx
        else
            target_idx = math.max(cur_idx - 1, 1)
        end
    end
    self.audio_player:seek(self.timeline[target_idx].global_offset_s)
end

-- ── helpers ───────────────────────────────────────────────────────────────────

function ReadAloudPlugin:_getCurrentXPointer()
    if not self.ui or not self.ui.document then return nil end
    local doc = self.ui.document
    -- Try to get xpointer of the first visible element
    for _, fname in ipairs({
        "getVisibleXPointer",
        "getCurrentPageXPointer",
        "getXPointerForPage",
    }) do
        if doc[fname] then
            local ok, xp = pcall(doc[fname], doc)
            if ok and xp and xp ~= "" then return xp end
        end
    end
    -- Fallback: use readerhighlight's current selection or last touched position
    if self.ui.highlight and self.ui.highlight.selected_text then
        local sel = self.ui.highlight.selected_text
        if sel and sel.pos0 then
            return sel.pos0:serialize()
        end
    end
    return nil
end

-- Parses the inner DOM path from a CRe xpointer (the part after DocFragment[N]).
-- Returns path segments {tag, idx} for walking the XHTML DOM.
-- Prepends {html, 1} because XHTML files start with <html> which is not in the xpointer.
local function parseXPointerInnerPath(xp)
    local inner = xp:match("/body/DocFragment%[%d+%]/(.+)$")
    if not inner then return {} end
    local segments = {{tag = "html", idx = 1}}
    for step in inner:gmatch("[^/]+") do
        if step:match("^text%(%)") then break end
        local tag, idx = step:match("^(.+)%[(%d+)%]$")
        if tag then
            table.insert(segments, {tag = string.lower(tag), idx = tonumber(idx)})
        else
            table.insert(segments, {tag = string.lower(step), idx = 1})
        end
    end
    return segments
end

-- Walk the XHTML DOM along path_segments and return the deepest id attribute found on the path.
-- Uses the SmilParser's pure-Lua XML parser.
local function findNearestIdForPath(xhtml_content, path_segments)
    if not xhtml_content or #path_segments == 0 then return nil end
    local stack = {{child_counts = {}, on_path = true}}
    local last_path_id = nil
    local done = false
    SmilParser.parseXML(xhtml_content, {
        StartElement = function(_, name, attrs)
            if done then return end
            name = string.lower(name)
            local parent = stack[#stack]
            parent.child_counts[name] = (parent.child_counts[name] or 0) + 1
            local my_idx = parent.child_counts[name]
            local depth = #stack
            local seg = path_segments[depth]
            local on_path = parent.on_path and seg ~= nil
                and seg.tag == name and seg.idx == my_idx
            if on_path then
                local elem_id = attrs.id or attrs.ID
                if elem_id then last_path_id = elem_id end
                if depth == #path_segments then done = true end
            end
            table.insert(stack, {child_counts = {}, on_path = on_path})
        end,
        EndElement = function(_, _)
            if #stack > 1 then table.remove(stack) end
        end,
    })
    return last_path_id
end

-- Returns all element IDs from an xpointer, deepest (most specific) first.
-- CRe encodes paths like: /body/DocFragment[N]/body[1]/p[@id='outer'][1]/span[@id='inner'][1]/text()[1].5
-- SMIL entries reference the innermost element, so we must try the last @id first.
local function xpointerToIds(xp)
    if not xp then return {} end
    local ids = {}
    for id in xp:gmatch("@id=['\"]([^'\"]+)['\"]") do
        table.insert(ids, 1, id)  -- prepend so iteration yields deepest first
    end
    local frag = xp:match("#(.+)$")
    if frag then table.insert(ids, frag) end
    return ids
end

-- Extract the DocFragment spine index from a CRe xpointer (1-based).
local function xpointerDocFragment(xp)
    if not xp then return nil end
    return tonumber(xp:match("/body/DocFragment%[(%d+)%]"))
end

function ReadAloudPlugin:_xpointerToElementId(xp)
    return xpointerToIds(xp)[1]  -- deepest id, or nil
end

-- Returns the global timeline offset (seconds) for the given xpointer.
-- Tries each element ID in the xpointer from deepest to shallowest, then falls
-- back to matching by DocFragment index so we at least land on the right chapter.
function ReadAloudPlugin:_findTimelineOffset(xp)
    if not xp or not self.timeline then return 0 end

    logger.info("RA_DIAG _findTimelineOffset: xp=" .. tostring(xp))

    -- 1. Direct ID match from @id attributes embedded in the xpointer
    local ids = xpointerToIds(xp)
    logger.info("RA_DIAG _findTimelineOffset: step1 ids=" .. #ids .. " first=" .. tostring(ids[1]))
    for _, elem_id in ipairs(ids) do
        for _, entry in ipairs(self.timeline) do
            if entry.text_id == elem_id then
                logger.info("RA_DIAG _findTimelineOffset: step1 matched id=" .. elem_id .. " offset=" .. string.format("%.3f", entry.global_offset_s))
                return entry.global_offset_s
            end
        end
    end

    local frag_n = xpointerDocFragment(xp)
    if frag_n and self._spine_items and self._spine_items[frag_n] then
        local xhtml_path = self._spine_items[frag_n].xhtml_path

        -- 2. XHTML path walk: find the nearest ancestor element with an id
        if xhtml_path then
            local f = io.open(xhtml_path, "rb")
            if f then
                local xhtml_content = f:read("*a")
                f:close()
                local path_segs = parseXPointerInnerPath(xp)
                local seg_desc = {}
                for _, s in ipairs(path_segs) do table.insert(seg_desc, s.tag .. "[" .. s.idx .. "]") end
                logger.info("RA_DIAG _findTimelineOffset: step2 segs=[" .. table.concat(seg_desc, "/") .. "]")
                local found_id = findNearestIdForPath(xhtml_content, path_segs)
                logger.info("RA_DIAG _findTimelineOffset: step2 found_id=" .. tostring(found_id))
                if found_id then
                    for _, entry in ipairs(self.timeline) do
                        if entry.text_id == found_id then
                            logger.info("RA_DIAG _findTimelineOffset: step2 matched offset=" .. string.format("%.3f", entry.global_offset_s))
                            return entry.global_offset_s
                        end
                    end
                end
            end
        end

        -- 3. Chapter-level fallback: land at the start of the right spine item
        local target_fname = xhtml_path and (xhtml_path:match("([^/]+)$") or xhtml_path)
        logger.info("RA_DIAG _findTimelineOffset: step3 chapter fallback xhtml=" .. tostring(target_fname))
        for _, entry in ipairs(self.timeline) do
            local ef = entry.xhtml_file and entry.xhtml_file:match("([^/]+)$")
            if ef and target_fname and ef == target_fname then
                logger.info("RA_DIAG _findTimelineOffset: step3 matched offset=" .. string.format("%.3f", entry.global_offset_s))
                return entry.global_offset_s
            end
        end
    end

    logger.info("RA_DIAG _findTimelineOffset: no match, returning 0")
    return 0
end

function ReadAloudPlugin:_buildChapterTitles(spine_items)
    self._chapter_titles = {}
    -- Use the XHTML filename as a cheap title; a proper implementation would
    -- read <title> from each XHTML file.
    for _, item in ipairs(spine_items) do
        if item.xhtml_path then
            local fname = item.xhtml_path:match("([^/]+)%.xhtml$")
                       or item.xhtml_path:match("([^/]+)$")
            self._chapter_titles[item.xhtml_path] = fname or item.id
        end
    end
end

function ReadAloudPlugin:_chapterTitleForEntry(entry)
    if not entry then return nil end
    return self._chapter_titles[entry.xhtml_file] or ""
end

return ReadAloudPlugin
