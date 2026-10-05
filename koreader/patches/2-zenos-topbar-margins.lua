-- ZenOS reader status-bar margin controls.
--
-- Install this file as:
--   koreader/patches/2-zenos-topbar-margins.lua
--
-- It adds the following menus:
--   Zen Settings > Reader > Top status bar > Margins
--   Zen Settings > Reader > Bottom status bar > Horizontal margin
--
-- ZenOS 4.x added "Align status bars with book margins", which drives the same
-- margins as this patch does and wins over them. This patch is the owner of
-- those margins, so while it is installed it forces that feature off
-- (isMarginAlignmentEnabled) and removes its Reader settings toggle.
--
-- The patch lives outside zenos.koplugin, so a normal ZenOS update does not
-- overwrite it. It patches the ZenOS module while Lua loads it and deliberately
-- fails loudly in KOReader's log if a future ZenOS release changes the relevant
-- source structure.

local logger = require("logger")

local SETTING_TOP = "zenos_topbar_margin_top"
local SETTING_LEFT = "zenos_topbar_margin_left"
local SETTING_RIGHT = "zenos_topbar_margin_right"
local SETTING_BOTTOM_HORIZONTAL = "zenos_bottombar_horizontal_margin"

-- These reproduce ZenOS/KOReader's current defaults before the user changes them.
local DEFAULT_TOP = 2
local DEFAULT_LEFT = 10
local DEFAULT_RIGHT = 10
local DEFAULT_BOTTOM_HORIZONTAL = 10

local TOPBAR_MODULE = "modules/reader/patches/reader_top_status_bar"
local FOOTER_MODULE = "modules/reader/patches/reader_footer"
local SETTINGS_MODULE = "modules/settings/sections/reader_settings"
local STATUS_BAR_MODULE = "common/reader_status_bar"

local function is_file(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function find_zenos_module(module_name)
    local module_path = module_name:gsub("%.", "/")
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", module_path)
        local normalized = candidate:gsub("\\", "/")
        if normalized:find("/zenos.koplugin/", 1, true) and is_file(candidate) then
            return candidate
        end
    end
end

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local source = file:read("*all")
    file:close()
    return source
end

local function replace_once(source, old, new, label)
    local start_at, end_at = source:find(old, 1, true)
    if not start_at then
        return nil, "cannot find " .. label
    end
    if source:find(old, end_at + 1, true) then
        return nil, "found more than one " .. label
    end
    return source:sub(1, start_at - 1) .. new .. source:sub(end_at + 1)
end

local function patch_topbar_source(source)
    local err
    source, err = replace_once(source,
        "        local top_pad = Size.padding.small\n        local h_pad   = Screen:scaleBySize(10)",
        "        local top_pad = Screen:scaleBySize(\n"
            .. "            G_reader_settings:readSetting(\"" .. SETTING_TOP .. "\", " .. DEFAULT_TOP .. "))\n"
            .. "        local h_pad = Screen:scaleBySize(\n"
            .. "            G_reader_settings:readSetting(\"" .. SETTING_LEFT .. "\", " .. DEFAULT_LEFT .. "))\n"
            .. "        local right_h_pad = Screen:scaleBySize(\n"
            .. "            G_reader_settings:readSetting(\"" .. SETTING_RIGHT .. "\", " .. DEFAULT_RIGHT .. "))",
        "top-bar margin declarations")
    if not source then return nil, err end

    -- The bookmark/dogear inset is reserved on both sides. The right side uses
    -- its own setting so the two margins can differ; the left side keeps h_pad.
    source, err = replace_once(source,
        "        right_pad = math.max(right_pad, right_inset > 0 and right_inset + h_pad or 0)",
        "        right_pad = math.max(right_pad, right_inset > 0 and right_inset + right_h_pad or 0)",
        "dogear right margin reservation")
    if not source then return nil, err end

    source, err = replace_once(source,
        "            left_pad = left_has and h_pad + right_inset or 0\n"
            .. "            right_pad = right_has and h_pad + right_inset or 0",
        "            left_pad = left_has and h_pad + right_inset or 0\n"
            .. "            right_pad = right_has and right_h_pad + right_inset or 0",
        "status-bar margin calculation")
    if not source then return nil, err end

    -- When the configured top margin grows, reserve the same extra height in
    -- paged reflowable documents so the first line cannot move under the bar.
    source, err = replace_once(source,
        "        local height = view.footer:getHeight()",
        "        local height = view.footer:getHeight()\n"
            .. "        local configured_top = Screen:scaleBySize(\n"
            .. "            G_reader_settings:readSetting(\"" .. SETTING_TOP .. "\", " .. DEFAULT_TOP .. "))\n"
            .. "        height = height + math.max(0, configured_top - Size.padding.small)",
        "reserved top-bar height")
    if not source then return nil, err end

    return source
end

local function active_reader()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI and ReaderUI.instance
end

local function refresh_reader()
    local UIManager = require("ui/uimanager")
    local reader = active_reader()
    if not reader then return end

    local typeset = reader.typeset
    if typeset and typeset.unscaled_margins
            and type(typeset.onSetPageMargins) == "function" then
        typeset:onSetPageMargins(typeset.unscaled_margins)
    end
    UIManager:setDirty(reader, "ui")
end

local function bottom_margin_value()
    local value = G_reader_settings and G_reader_settings:readSetting(
        SETTING_BOTTOM_HORIZONTAL, DEFAULT_BOTTOM_HORIZONTAL)
    value = math.floor(tonumber(value) or DEFAULT_BOTTOM_HORIZONTAL)
    return math.max(0, math.min(140, value))
end

local function apply_bottom_margin(footer)
    if not footer then return end
    local value = bottom_margin_value()
    local Screen = require("device").screen
    footer.horizontal_margin = Screen:scaleBySize(value)
    if footer.settings then
        -- Keep text, separators, and every progress-bar position on the same
        -- symmetric outer edge. This intentionally overrides KOReader's
        -- separate "same as book margins" progress-bar option.
        footer.settings.progress_margin = false
        footer.settings.progress_margin_width = value
    end
end

local function refresh_bottom_footer()
    local reader = active_reader()
    local footer = reader and reader.view and reader.view.footer
    if not footer then return end
    apply_bottom_margin(footer)
    if type(footer.refreshFooter) == "function" then
        footer:refreshFooter(true, true)
    end
end

local function install_bottom_margin_support()
    local ReaderFooter = require("apps/reader/modules/readerfooter")
    if ReaderFooter._userpatch_bottom_horizontal_margin then
        refresh_bottom_footer()
        return
    end
    ReaderFooter._userpatch_bottom_horizontal_margin = true

    local original_init = ReaderFooter.init
    ReaderFooter.init = function(self, ...)
        local result = original_init(self, ...)
        apply_bottom_margin(self)
        if self.footer_positioner and type(self.updateFooterContainer) == "function"
                and type(self.resetLayout) == "function" then
            self:updateFooterContainer()
            self:resetLayout(true)
        end
        return result
    end

    local original_refresh_footer = ReaderFooter.refreshFooter
    ReaderFooter.refreshFooter = function(self, ...)
        apply_bottom_margin(self)
        return original_refresh_footer(self, ...)
    end

    -- ReaderFooter may already exist when ZenOS loads inside an open book.
    refresh_bottom_footer()
end

local function read_margin(key, default)
    local value = G_reader_settings and G_reader_settings:readSetting(key, default)
    value = tonumber(value) or default
    return math.floor(value)
end

local function make_margin_item(label, key, default, maximum, refresh)
    local _ = require("gettext")
    return {
        text_func = function()
            return string.format("%s: %d", _(label), read_margin(key, default))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager = require("ui/uimanager")
            UIManager:show(SpinWidget:new{
                title_text = _(label),
                value = read_margin(key, default),
                value_min = 0,
                value_max = maximum,
                value_hold_step = 5,
                default_value = default,
                keep_shown_on_apply = true,
                callback = function(spin)
                    G_reader_settings:saveSetting(key, spin.value)
                    refresh()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

local function wrap_reader_settings(module)
    if type(module) ~= "table" or type(module.build) ~= "function" then
        error("ZenOS top-bar margins: unsupported reader settings module")
    end
    if module._userpatch_topbar_margins then return module end
    module._userpatch_topbar_margins = true

    local original_build = module.build
    module.build = function(ctx)
        local items = original_build(ctx)
        local gettext = require("gettext")

        -- ZenOS 4.x's book-margin alignment is forced off by the loader above,
        -- so its toggle would only lie about what the bars do. Hide it, and
        -- tolerate its absence in case a future ZenOS drops the feature.
        local align_text = gettext("Align status bars with book margins")
        if type(items) == "table" then
            for i = #items, 1, -1 do
                if type(items[i]) == "table" and items[i].text == align_text then
                    table.remove(items, i)
                end
            end
        end

        -- Reader settings currently builds Top status bar first. Validate both
        -- its position and label so a future ZenOS reorder fails explicitly
        -- instead of inserting these controls into an unrelated submenu.
        local topbar = type(items) == "table" and items[1]
        if not topbar or type(topbar.sub_item_table) ~= "table"
                or topbar.text ~= gettext("Top status bar") then
            error("ZenOS top-bar margins: first Reader item is not Top status bar")
        end

        local margins = {
            text = gettext("Margins"),
            sub_item_table = {
                make_margin_item("Top margin", SETTING_TOP, DEFAULT_TOP, 49,
                    refresh_reader),
                make_margin_item("Left margin", SETTING_LEFT, DEFAULT_LEFT, 140,
                    refresh_reader),
                make_margin_item("Right margin", SETTING_RIGHT, DEFAULT_RIGHT, 140,
                    refresh_reader),
            },
        }
        -- Keep the three item-slot menus together, followed by Margins.
        table.insert(topbar.sub_item_table, 4, margins)

        -- Bottom status bar is currently the ninth Reader item and builds its
        -- submenu lazily because it needs an active ReaderFooter instance.
        local bottombar = items[9]
        if not bottombar or type(bottombar.sub_item_table_func) ~= "function"
                or bottombar.text ~= gettext("Bottom status bar") then
            error("ZenOS top-bar margins: ninth Reader item is not Bottom status bar")
        end
        local original_bottom_items = bottombar.sub_item_table_func
        bottombar.sub_item_table_func = function(...)
            local bottom_items = original_bottom_items(...)
            table.insert(bottom_items, 3, make_margin_item(
                "Horizontal margin", SETTING_BOTTOM_HORIZONTAL,
                DEFAULT_BOTTOM_HORIZONTAL, 140, refresh_bottom_footer))
            return bottom_items
        end
        return items
    end

    return module
end

local interceptors = {
    [TOPBAR_MODULE] = function(chunk, path)
        local source, err = patch_topbar_source(chunk)
        if not source then
            error("ZenOS top-bar margins cannot patch " .. path .. ": " .. tostring(err))
        end
        local compiled, compile_err = loadstring(source, "@" .. path)
        if not compiled then error(compile_err) end
        return compiled
    end,
    [FOOTER_MODULE] = function(chunk, path)
        local compiled, compile_err = loadstring(chunk, "@" .. path)
        if not compiled then error(compile_err) end
        return function(...)
            local apply_footer_patch = compiled(...)
            if type(apply_footer_patch) ~= "function" then
                error("ZenOS status-bar margins: unsupported reader footer module")
            end
            return function(...)
                install_bottom_margin_support()
                local result = apply_footer_patch(...)
                refresh_bottom_footer()
                return result
            end
        end
    end,
    [STATUS_BAR_MODULE] = function(chunk, path)
        local compiled, compile_err = loadstring(chunk, "@" .. path)
        if not compiled then error(compile_err) end
        return function(...)
            local module = compiled(...)
            if type(module) ~= "table" then
                error("ZenOS status-bar margins: unsupported reader status bar module")
            end
            -- One gate for the whole feature: the top bar reads it as
            -- align_margins and the footer calls it from book_margin_width().
            module.isMarginAlignmentEnabled = function() return false end
            return module
        end
    end,
    [SETTINGS_MODULE] = function(chunk, path)
        local compiled, compile_err = loadstring(chunk, "@" .. path)
        if not compiled then error(compile_err) end
        return function(...)
            return wrap_reader_settings(compiled(...))
        end
    end,
}

local function zenos_margin_loader(module_name)
    local interceptor = interceptors[module_name]
    if not interceptor then return nil end

    local path = find_zenos_module(module_name)
    if not path then
        return function()
            error("ZenOS top-bar margins: ZenOS module not found")
        end
    end
    local source, read_err = read_file(path)
    if not source then
        return function()
            error("ZenOS top-bar margins: " .. tostring(read_err))
        end
    end

    local ok, loader_or_err = pcall(interceptor, source, path)
    if not ok then
        logger.warn(loader_or_err)
        return function() error(loader_or_err) end
    end
    return loader_or_err
end

-- Run before Lua's regular file loader, but only claim the two ZenOS modules
-- listed above. All other require() calls pass through unchanged.
table.insert(package.loaders, 1, zenos_margin_loader)
logger.info("ZenOS top-bar margin user patch installed")
