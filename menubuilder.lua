--[[--
Reusable menu fragment builders for the Read Aloud plugin.

Each builder returns a sub_item_table-style table that main.lua inserts into
its menu registration.
@module koplugin.readaloud.menubuilder
--]]--

local _ = require("gettext")

local MenuBuilder = {}

-- ── highlight style ───────────────────────────────────────────────────────────

local HIGHLIGHT_STYLES = {
    { id = "background", label = _("Background") },
    { id = "invert",     label = _("Invert (recommended for e-ink)") },
    { id = "underline",  label = _("Underline") },
    { id = "box",        label = _("Box") },
}

function MenuBuilder.buildHighlightStyleMenu(plugin, settings)
    local items = {}
    for _, style in ipairs(HIGHLIGHT_STYLES) do
        table.insert(items, {
            text = style.label,
            checked_func = function()
                return settings:readSetting("highlight_style", "background") == style.id
            end,
            callback = function()
                settings:saveSetting("highlight_style", style.id)
                settings:flush()
            end,
        })
    end
    return {
        text           = _("Highlight style"),
        sub_item_table = items,
    }
end

-- ── playback speed ────────────────────────────────────────────────────────────

local SPEEDS = { 0.75, 1.0, 1.25, 1.5, 2.0 }

function MenuBuilder.buildPlaybackSpeedMenu(plugin, settings, audio_player)
    local items = {}
    for _, spd in ipairs(SPEEDS) do
        local label = string.format("%.2g×", spd)
        table.insert(items, {
            text = label,
            checked_func = function()
                local cur = settings:readSetting("playback_speed", 1.0)
                return math.abs(cur - spd) < 0.01
            end,
            callback = function()
                settings:saveSetting("playback_speed", spd)
                settings:flush()
                if audio_player then audio_player:setSpeed(spd) end
            end,
        })
    end
    return {
        text           = _("Playback speed"),
        sub_item_table = items,
    }
end

-- ── volume ────────────────────────────────────────────────────────────────────

local VOLUMES = { 0, 20, 40, 60, 80, 100 }

function MenuBuilder.buildVolumeMenu(plugin, settings, audio_player)
    local items = {}
    for _, vol in ipairs(VOLUMES) do
        table.insert(items, {
            text = string.format("%d%%", vol),
            checked_func = function()
                return settings:readSetting("volume", 80) == vol
            end,
            callback = function()
                settings:saveSetting("volume", vol)
                settings:flush()
                if audio_player then audio_player:setVolume(vol) end
            end,
        })
    end
    return {
        text           = _("Volume"),
        sub_item_table = items,
    }
end

-- ── auto page turn ────────────────────────────────────────────────────────────

function MenuBuilder.buildAutoScrollMenu(plugin, settings)
    local function getAutoPageTurn()
        return settings:readSetting("auto_page_turn", true) ~= false
    end
    return {
        text      = _("Auto turn page with audio"),
        checked_func = getAutoPageTurn,
        callback  = function()
            settings:saveSetting("auto_page_turn", not getAutoPageTurn())
            settings:flush()
        end,
    }
end

-- ── keep playing with lid closed ──────────────────────────────────────────────

function MenuBuilder.buildKeepPlayingMenu(plugin, settings)
    return {
        text      = _("Keep playing with lid closed"),
        checked_func = function()
            return settings:isTrue("keep_playing_lid_closed")
        end,
        callback  = function()
            local cur = settings:isTrue("keep_playing_lid_closed")
            settings:saveSetting("keep_playing_lid_closed", not cur)
            settings:flush()
        end,
    }
end

return MenuBuilder
