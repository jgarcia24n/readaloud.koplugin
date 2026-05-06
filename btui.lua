--[[--
Bluetooth audio sub-menu builder for the Read Aloud plugin.

Returns a menu_items fragment that main.lua inserts under the "Read Aloud" menu.
@module koplugin.readaloud.btui
--]]--

local InfoMessage  = require("ui/widget/infomessage")
local Menu         = require("ui/widget/menu")
local UIManager    = require("ui/uimanager")
local _            = require("gettext")

local BtUI = {}

-- Build and show a device-list menu after a scan.
local function showDeviceMenu(bt_manager, devices, plugin)
    if #devices == 0 then
        UIManager:show(InfoMessage:new{
            text    = _("No Bluetooth devices found."),
            timeout = 3,
        })
        return
    end

    local items = {}
    for _, dev in ipairs(devices) do
        local label = dev.name or dev.address
        if dev.connected then
            label = label .. " ✓"
        elseif dev.paired then
            label = label .. " (" .. _("paired") .. ")"
        end
        table.insert(items, {
            text     = label,
            callback = function()
                if dev.connected then
                    bt_manager:disconnect()
                    UIManager:show(InfoMessage:new{
                        text    = _("Disconnected."),
                        timeout = 2,
                    })
                else
                    -- Pair if not yet paired
                    if not dev.paired then
                        UIManager:show(InfoMessage:new{
                            text    = _("Pairing…"),
                            timeout = 10,
                        })
                        bt_manager:pair(dev.address, function(ok)
                            if not ok then
                                UIManager:show(InfoMessage:new{
                                    text    = _("Pairing failed."),
                                    timeout = 3,
                                })
                                return
                            end
                            UIManager:show(InfoMessage:new{
                                text    = _("Connecting…"),
                                timeout = 5,
                            })
                            local connected = bt_manager:connect(dev.address)
                            UIManager:show(InfoMessage:new{
                                text    = connected and _("Connected!") or _("Connection failed."),
                                timeout = 3,
                            })
                        end)
                    else
                        -- Already paired, just connect
                        UIManager:show(InfoMessage:new{
                            text    = _("Connecting…"),
                            timeout = 5,
                        })
                        local connected = bt_manager:connect(dev.address)
                        UIManager:show(InfoMessage:new{
                            text    = connected and _("Connected!") or _("Connection failed."),
                            timeout = 3,
                        })
                    end
                end
            end,
        })
    end

    UIManager:show(Menu:new{
        title        = _("Bluetooth Devices"),
        item_table   = items,
        onMenuSelect = function(menu, item) item.callback() end,
    })
end

-- Returns a menu fragment table to be inserted into the main menu.
function BtUI:build(plugin, bt_manager, settings)
    local connected_addr = bt_manager:getConnectedAddress()
    local connected_text = connected_addr
        and string.format(_("Connected: %s"), connected_addr)
        or  _("Not connected")

    return {
        text = _("Bluetooth audio"),
        sub_item_table = {
            {
                text     = _("Scan for devices"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text    = _("Scanning for 5 seconds…"),
                        timeout = 5,
                    })
                    bt_manager:scan(function(devices)
                        showDeviceMenu(bt_manager, devices, plugin)
                    end)
                end,
            },
            {
                text             = connected_text,
                enabled          = connected_addr ~= nil,
                callback         = function()
                    if connected_addr then
                        bt_manager:disconnect()
                        UIManager:show(InfoMessage:new{
                            text    = _("Disconnected."),
                            timeout = 2,
                        })
                        plugin:reloadMenu()
                    end
                end,
            },
            {
                text      = _("Auto-connect on startup"),
                checked_func = function()
                    return settings:isTrue("bt_auto_connect")
                end,
                callback  = function()
                    local cur = settings:isTrue("bt_auto_connect")
                    settings:saveSetting("bt_auto_connect", not cur)
                    settings:flush()
                end,
            },
            {
                text     = _("Forget saved device"),
                enabled  = connected_addr ~= nil
                        or settings:readSetting("bt_saved_address") ~= nil,
                callback = function()
                    bt_manager:forgetDevice()
                    UIManager:show(InfoMessage:new{
                        text    = _("Saved device forgotten."),
                        timeout = 2,
                    })
                    plugin:reloadMenu()
                end,
            },
        },
    }
end

return BtUI
