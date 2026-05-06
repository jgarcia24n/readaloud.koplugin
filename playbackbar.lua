--[[--
Playback Control Bar Widget
Shows play/pause, rewind, forward, and close controls at the bottom of the screen.

@module playbackbar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("logger")
local _ = require("gettext")

local PlaybackBar = InputContainer:extend{
    width = nil,
    height = nil,
    plugin = nil,
    sync_controller = nil,
    is_playing = true,
    current_word = "",
    progress = 0,
    -- Do NOT set toast = true.  Toast widgets cannot consume events: returning
    -- true from handleEvent has no effect and the reader below still receives
    -- the same tap, triggering its own gesture handler (showing the reader
    -- toolbar and hiding the playback bar).  As a non-toast widget we sit on
    -- top of the reader in the UIManager window stack and returning true from
    -- handleEvent actually stops propagation.  Swipe/hold/pan events are still
    -- passed through explicitly in handleEvent below.
    -- Callbacks from sync_controller
    on_play_pause = nil,
    on_rewind = nil,
    on_forward = nil,
    on_close = nil,
    on_realign = nil,
    -- Auto-hide: bar fades away while playing; any tap brings it back.
    auto_hide = true,
    auto_hide_delay = 4,  -- seconds before hiding after last tap
    _user_visible = true, -- false when auto-hidden (bar still in stack)
}

function PlaybackBar:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:scaleBySize(100)

    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
    }

    self._auto_hide_func = function()
        self:_autoHide()
    end

    self:setupUI()
end

function PlaybackBar:setupUI()
    local button_width = Screen:scaleBySize(60)
    local button_height = Screen:scaleBySize(40)
    local button_font_size = 20
    local spacing = Size.padding.large

    -- Rewind button (previous sentence)
    self.rewind_button = Button:new{
        text = "⏪︎",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onRewind()
        end,
        hold_callback = function()
            self:onRewindHold()
        end,
        bordersize = Size.border.button,
        show_parent = self,
    }

    -- Play/Pause button
    self.play_pause_button = Button:new{
        text = self.is_playing and "⏸" or "▶",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onPlayPause()
        end,
        bordersize = Size.border.button,
        show_parent = self,
    }

    -- Forward button (next sentence)
    self.forward_button = Button:new{
        text = "⏩︎",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onForward()
        end,
        hold_callback = function()
            self:onForwardHold()
        end,
        bordersize = Size.border.button,
        show_parent = self,
    }

    -- Hide button — immediately collapses the bar (tap anywhere to restore)
    self.hide_button = Button:new{
        text = "▼",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:_manualHide()
        end,
        bordersize = Size.border.button,
        show_parent = self,
    }

    -- Close button
    self.close_button = Button:new{
        text = "✕",
        width = button_width,
        max_width = button_width,
        height = button_height,
        text_font_size = button_font_size,
        callback = function()
            self:onClose()
        end,
        bordersize = Size.border.button,
        show_parent = self,
    }

    -- Current word display
    self.word_display = TextWidget:new{
        text = self.current_word or _("Starting..."),
        face = Font:getFace("cfont", 16),
        max_width = self.width - button_width * 5 - spacing * 7,
        truncate_left = true,
    }

    -- Progress bar — tall enough to be clearly visible on e-ink
    self.progress_bar = ProgressWidget:new{
        width = self.width - Size.padding.large * 2,
        height = Screen:scaleBySize(10),
        percentage = self.progress / 100,
        fillcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
        bordersize = 0,
        margin_h = 0,
        margin_v = 0,
        radius = Screen:scaleBySize(5),
        ticks = nil,
        tick_width = 0,
        last = nil,
    }

    -- Button row
    local button_row = HorizontalGroup:new{
        align = "center",
        self.hide_button,
        HorizontalSpan:new{ width = spacing * 2 },
        self.rewind_button,
        HorizontalSpan:new{ width = spacing },
        self.play_pause_button,
        HorizontalSpan:new{ width = spacing },
        self.forward_button,
        HorizontalSpan:new{ width = spacing * 2 },
        self.close_button,
    }

    -- Main layout — generous spacing so progress bar and buttons
    -- are clearly separated from each other and the bottom edge.
    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.small },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.word_display:getSize().h },
            self.word_display,
        },
        VerticalSpan:new{ width = Size.padding.default },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.progress_bar:getSize().h },
            self.progress_bar,
        },
        VerticalSpan:new{ width = Size.padding.large },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = button_height },
            button_row,
        },
        VerticalSpan:new{ width = Size.padding.fullscreen },
    }

    -- Frame with background
    self[1] = FrameContainer:new{
        width = self.width,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        padding = 0,
        content,
    }

    -- Position at bottom of screen
    self.dimen = self[1]:getSize()
    self.dimen.x = 0
    self.dimen.y = Screen:getHeight() - self.dimen.h
end

function PlaybackBar:onPlayPause()
    if self.on_play_pause then
        self.on_play_pause()
    elseif self.plugin then
        if self.is_playing then
            self.plugin:pauseReadAlong()
        else
            self.plugin:resumeReadAlong()
        end
    end
end

function PlaybackBar:onRewind()
    if self.on_rewind then
        self.on_rewind()
    elseif self.plugin and self.plugin.sync_controller then
        self.plugin.sync_controller:prevSentence()
    end
end

function PlaybackBar:onRewindHold()
    self:onRewind()
end

function PlaybackBar:onForward()
    if self.on_forward then
        self.on_forward()
    elseif self.plugin and self.plugin.sync_controller then
        self.plugin.sync_controller:nextSentence()
    end
end

function PlaybackBar:onForwardHold()
    self:onForward()
end

function PlaybackBar:onRealign()
    if self.on_realign then
        self.on_realign()
    end
end

function PlaybackBar:onClose()
    if self.on_close then
        self.on_close()
    elseif self.plugin then
        self.plugin:stopReadAlong()
    end
end

function PlaybackBar:updatePlayPauseButton()
    local new_text = self.is_playing and "⏸" or "▶"
    self.play_pause_button:setText(new_text, self.play_pause_button.width)
    -- Full bar repaint ensures the icon is visible on e-ink regardless of
    -- whether the button's dimen was already calculated at dirty time.
    UIManager:setDirty(self, "ui")
end

function PlaybackBar:updateCurrentWord(word)
    if word and word ~= self.current_word then
        self.current_word = word
        self.word_display:setText(word)
        UIManager:setDirty(self, function()
            return "ui", self.word_display.dimen
        end)
    end
end

function PlaybackBar:updateProgress(progress)
    if progress ~= self.progress then
        self.progress = progress
        self.progress_bar:setPercentage(progress / 100)
        UIManager:setDirty(self, function()
            return "ui", self.progress_bar.dimen
        end)
    end
end

function PlaybackBar:setPlaying(is_playing)
    local changed = is_playing ~= self.is_playing
    if not changed then return end
    self.is_playing = is_playing
    self:updatePlayPauseButton()
    -- Only adjust auto-hide on actual play/pause transitions, not every tick.
    -- Checking on every call would undo a manual hide immediately.
    if self.auto_hide and self.visible then
        if is_playing then
            self:_showForUser()
        else
            self:_cancelAutoHide()
            if not self._user_visible then
                self._user_visible = true
                UIManager:setDirty("all", "ui")
            end
        end
    end
end

function PlaybackBar:updatePlayState(is_playing)
    self:setPlaying(is_playing)
end

-- Convenience method: update progress, word display, and play state in one call.
-- position_s: current playback position in seconds
-- total_s: total duration in seconds
-- title: chapter/sentence label to display (may be nil)
-- playing: boolean
function PlaybackBar:update(position_s, total_s, title, playing)
    local new_progress = (total_s and total_s > 0) and ((position_s / total_s) * 100) or 0
    new_progress = math.max(0, math.min(100, new_progress))
    self:updateProgress(new_progress)
    if title then
        self:updateCurrentWord(title)
    end
    self:setPlaying(playing)
    if self.visible then
        UIManager:setDirty(self, "ui")
    end
end

function PlaybackBar:show()
    self.visible = true
    self.suppressed = false
    self._user_visible = true
    self.dimen.x = 0
    self.dimen.y = Screen:getHeight() - self.dimen.h
    UIManager:show(self, "ui", nil, self.dimen.x, self.dimen.y)
    -- If already playing when shown, start the auto-hide countdown
    if self.auto_hide and self.is_playing then
        self:_scheduleAutoHide()
    end
end

function PlaybackBar:hide()
    self.visible = false
    self.suppressed = false
    self:_cancelAutoHide()
    UIManager:close(self)
end

--- Suppress / un-suppress painting without removing the widget from the
-- UIManager window stack.  Used by the "paused_only" visibility mode so
-- that:
--   * The overlay auto-pause poller keeps detecting menus opening.
--   * The screen below shows through (paintTo is a no-op while suppressed).
--   * Events pass through to the reader while suppressed.
--
-- This avoids the v0.1.5.79 bugs where UIManager:close()'ing the bar dropped
-- it from the stack entirely: taps fell through to the reader (page turns,
-- dictionary), the bar could never be restored, and the top-menu pull-down
-- froze KOReader because the auto-pause path tried to re-show a stale widget.
function PlaybackBar:setSuppressed(suppressed)
    suppressed = suppressed and true or false
    if self.suppressed == suppressed then return end
    self.suppressed = suppressed
    -- Repaint the bar's region: when un-suppressing draw the bar; when
    -- suppressing redraw the area behind it (now empty paintTo).
    UIManager:setDirty("all", "ui")
end

function PlaybackBar:isSuppressed()
    return self.suppressed and true or false
end

-- Auto-hide: schedule the bar to disappear after auto_hide_delay seconds.
function PlaybackBar:_scheduleAutoHide()
    UIManager:unschedule(self._auto_hide_func)
    UIManager:scheduleIn(self.auto_hide_delay, self._auto_hide_func)
end

function PlaybackBar:_cancelAutoHide()
    UIManager:unschedule(self._auto_hide_func)
end

function PlaybackBar:_autoHide()
    if not self.auto_hide or not self.is_playing or not self.visible then return end
    self._user_visible = false
    UIManager:setDirty("all", "ui")
end

function PlaybackBar:_manualHide()
    if not self.visible then return end
    self:_cancelAutoHide()
    self._user_visible = false
    UIManager:setDirty("all", "ui")
end

-- Show the bar visually and restart the auto-hide countdown if playing.
function PlaybackBar:_showForUser()
    if not self.visible then return end
    self._user_visible = true
    UIManager:setDirty("all", "ui")
    if self.is_playing and self.auto_hide then
        self:_scheduleAutoHide()
    end
end

--- True when the bar widget is mounted in the UIManager window stack,
-- regardless of whether it is currently painted.  SyncController uses this
-- to decide whether to call show()/setSuppressed() on the next visibility
-- transition.
function PlaybackBar:isVisible()
    return self.visible
end

function PlaybackBar:onCloseWidget()
    self:_cancelAutoHide()
end

--[[--
Handle screen dimension changes (e.g. after device rotation).
Rebuild the bar layout with the new screen width and reposition at the
new bottom edge.
--]]
function PlaybackBar:onSetDimensions()
    if not self.visible then return end
    logger.warn("PlaybackBar: onSetDimensions, new screen =", Screen:getWidth(), "x", Screen:getHeight())
    -- Preserve current playback state across the rebuild
    local was_playing = self.is_playing
    local word = self.current_word
    local progress = self.progress
    -- Remove from UIManager so the old x,y coordinates are discarded
    UIManager:close(self)
    -- Re-derive width and height from the (potentially rotated) screen
    self.width = Screen:getWidth()
    self.height = Screen:scaleBySize(100)
    -- Rebuild the UI tree with new dimensions
    self:setupUI()
    -- Restore state into the fresh widgets
    self.is_playing = was_playing
    self.current_word = word
    self.progress = progress
    self:updatePlayPauseButton()
    if word and word ~= "" then self.word_display:setText(word) end
    self.progress_bar:setPercentage(progress / 100)
    -- Re-show at the correct position — this registers the new x,y
    -- with UIManager so paintTo receives the right coordinates.
    -- Reset auto-hide state so the bar is visible after rotation.
    self._user_visible = true
    self:show()
    UIManager:setDirty(self, "ui")
    return true
end

--- Override handleEvent so that:
--- 1. Taps inside the bar area go to the buttons normally.
--- 2. Taps on the reading area PASS THROUGH to the reader (no tap-to-pause).
--- 3. Swipe/pan/hold gestures always pass through so the bottom-swipe
---    ConfigMenu and long-press dictionary still work.
--- 4. When any overlay (menu/dialog) is active, all events pass through
---    so the overlay can handle its own taps and dismiss correctly.
--- 5. When the bar is suppressed (paused_only mode), all taps pass through.
function PlaybackBar:handleEvent(event)
    local arg1 = event.args and event.args[1]
    if event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges) then
        local ges = type(arg1) == "table" and arg1 or nil
        if ges then
            -- Let swipe/pan/hold pass through unconditionally
            if ges.ges == "swipe" or ges.ges == "pan" or ges.ges == "hold" or ges.ges == "hold_pan" then
                return false
            end
            -- When a menu or dialog is open, pass through so it can handle
            -- its own events (e.g. dismiss on outside tap).
            if self:_isOverlayActive() then
                return false
            end
            -- When bar is not visible or suppressed, pass all events through
            if not self.visible or self.suppressed then
                return false
            end
            -- Tap events
            if ges.ges == "tap" then
                -- Auto-hidden: any tap shows the bar.
                -- Consume taps in the bar's footprint (where buttons live) to
                -- avoid accidental reader actions; pass through taps in the
                -- reading area so page turns / dictionary still work.
                if self.auto_hide and not self._user_visible then
                    self:_showForUser()
                    if ges.pos and self.dimen and ges.pos.y >= self.dimen.y then
                        return true  -- consumed — bar area, no reader action
                    end
                    return false  -- reading area — let reader handle it too
                end
                if ges.pos and self.dimen and ges.pos.y >= self.dimen.y then
                    return InputContainer.handleEvent(self, event)
                end
                -- Taps outside the bar pass through to the reader
                return false
            end
        end
    end
    -- Non-gesture events: standard dispatch
    return InputContainer.handleEvent(self, event)
end

function PlaybackBar:paintTo(bb, x, y)
    -- Toast widgets are painted on top of everything. To let menus/dialogs
    -- appear above us, skip painting when any non-toast widget besides the
    -- base reader is in the UIManager window stack.
    if self:_isOverlayActive() then
        return
    end
    -- Suppressed mode: keep the widget in the stack (overlay detection still
    -- works) but render nothing so the screen below shows through.
    if self.suppressed then
        return
    end
    -- Auto-hidden: same idea — bar stays in stack for event interception but
    -- is not painted so the full reading area is visible.
    if not self._user_visible then
        return
    end
    if self[1] and self[1].paintTo then
        self[1]:paintTo(bb, x or 0, y or self.dimen.y)
    end
end

--- Check if any menu or dialog sits between us and the base reader.
-- In normal operation there is exactly 1 non-toast widget (the reader)
-- plus ourselves.  When a menu/dialog opens, there are 3+.
function PlaybackBar:_isOverlayActive()
    local stack = UIManager._window_stack
    if not stack then return false end
    local non_toast = 0
    for i = 1, #stack do
        local w = stack[i].widget
        if w ~= self and not w.toast then
            non_toast = non_toast + 1
            if non_toast > 1 then
                return true
            end
        end
    end
    return false
end

return PlaybackBar
