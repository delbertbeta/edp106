--[[--
Force a real full (GC16) screen refresh every N page turns.

KOReader's own refresh rate handling (`UIManager.FULL_REFRESH_COUNT`) ends up in
`Screen:refreshFull()`, which on Android only asks the launcher for an e-ink
update when the launcher recognised the panel controller. On the Moaan EPD106
(Allwinner virgo) it does not, so `framebuffer_android.lua` keeps
`has_eink_screen = false` and a "full refresh" is an ordinary blit that never
flashes.

So we count page turns ourselves and ask the window manager for the real thing:
`WindowManagerGlobal.mRoots[0]` is our `ViewRootImpl`, and
`ViewRootImpl.setRefreshMode(int)` makes the composer commit the next repaint
with a flashing waveform.

(That is also the only route that exists here: `View.getViewRootImpl()` and
`WindowManagerGlobal.getRootView(int)` are not in this framework at all.)

The window manager does no permission check for any of this, and Android 8.1
predates the hidden API blacklist, so plain JNI can reach it.

There used to be a waveform picker here as well. It is gone on purpose: the
panel's waveform LUT only demonstrably supports the modes the firmware itself
drives, the picker let one select everything else too, and some of those values
hung the whole device. Two known-good values are still used internally, just to
turn the periodic full refresh into a waveform flip instead of an extra commit
-- there is nothing user-selectable about them.

@module koplugin.totalfresh
--]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local T = require("ffi/util").template

local ffi = require("ffi")
local C = ffi.C

local RATE_KEY = "totalfresh_pages"
local RATES = { 1, 5, 10, 20 }

-- Only the two waveforms the firmware itself drives; the panel's LUT support for
-- anything else is unverified and some values hung this device (0x02 = DU is
-- what the system calls 快速, 0x84 = GU16 is 普通 and the framework's default
-- window mode).
local FULL_MODE = 0x04     -- GC16, the flashing one
local PARTIAL_MODE = 0x84  -- GU16
-- The page's own repaint reaches the composer ~80ms after onPageUpdate fires
-- (measured), so hold the flashing waveform long enough for it to get through
-- and then put the ordinary one back.
local REVERT_DELAY_S = 0.3

-- Same guard KOReader itself uses for its Android-only bits.
local is_android, android = pcall(require, "android")
if not is_android then
    android = nil
end

--- luajit-launcher owns its JNI helper but keeps it private, so redo the
--- attach/detach dance here (exactly like android.lua does).
--- @return nil on success, an error string otherwise.
local function withJNI(fn)
    local vm = android and android.app and android.app.activity and android.app.activity.vm
    if vm == nil then
        return "no JavaVM"
    end
    local env = ffi.new("JNIEnv*[1]")
    vm[0].GetEnv(vm, ffi.cast("void**", env), C.JNI_VERSION_1_6)
    if vm[0].AttachCurrentThread(vm, env, nil) == C.JNI_ERR then
        return "cannot attach to the JVM"
    end
    local jni = env[0]
    local ok, res = pcall(fn, jni)
    vm[0].DetachCurrentThread(vm)
    if not ok then
        -- `res` is the message an explicit need() below raised.
        logger.warn("totalfresh:", res)
        return tostring(res)
    end
    return res
end

--- Resolves our ViewRootImpl and invokes a void method on it.
--- @param method string method name on android.view.ViewRootImpl
--- @param signature string its JNI signature
--- @return nil on success, an error string otherwise.
local function callOnRootView(method, signature, ...)
    local args = { ... }
    return withJNI(function(jni)
        -- Any of these lookups can come back NULL, and a NULL return leaves a
        -- pending Java exception behind. Print it (it names the exact missing
        -- symbol) and clear it before bailing out.
        --
        -- NOTE: do *not* write this as `if not value then`. A NULL cdata
        -- pointer is a truthy value in LuaJIT and `not` on it is always false,
        -- and handing a NULL method ID to JNI makes ART abort the process.
        -- Only `== nil` is reliable here.
        local function need(what, value)
            if value ~= nil then return value end
            jni[0].ExceptionDescribe(jni)
            jni[0].ExceptionClear(jni)
            error(what, 0)
        end

        -- WindowManagerGlobal.getInstance().mRoots.get(0)
        local wmg_class = need("WindowManagerGlobal not found",
            jni[0].FindClass(jni, "android/view/WindowManagerGlobal"))
        local get_instance = need("WindowManagerGlobal.getInstance missing",
            jni[0].GetStaticMethodID(jni, wmg_class, "getInstance",
                "()Landroid/view/WindowManagerGlobal;"))
        local wmg = need("no WindowManagerGlobal instance",
            jni[0].CallStaticObjectMethod(jni, wmg_class, get_instance))
        local f_roots = need("WindowManagerGlobal.mRoots missing",
            jni[0].GetFieldID(jni, wmg_class, "mRoots", "Ljava/util/ArrayList;"))
        local roots = need("no root list",
            jni[0].GetObjectField(jni, wmg, f_roots))
        local roots_class = need("no ArrayList class",
            jni[0].GetObjectClass(jni, roots))
        local list_get = need("ArrayList.get missing",
            jni[0].GetMethodID(jni, roots_class, "get", "(I)Ljava/lang/Object;"))
        -- Variadic JNI calls promote a plain Lua number to double, so the int
        -- argument has to be an explicitly cast cdata.
        local root_view = need("no ViewRootImpl",
            jni[0].CallObjectMethod(jni, roots, list_get, ffi.cast("jint", 0)))

        local root_class = need("no ViewRootImpl class",
            jni[0].GetObjectClass(jni, root_view))
        local mid = need("ViewRootImpl." .. method .. " missing",
            jni[0].GetMethodID(jni, root_class, method, signature))
        jni[0].CallVoidMethod(jni, root_view, mid, unpack(args))
        if jni[0].ExceptionCheck(jni) == 1 then
            jni[0].ExceptionDescribe(jni)
            jni[0].ExceptionClear(jni)
            error(method .. " threw", 0)
        end
        return nil
    end)
end

--- Switches the reading window's waveform, so that the next repaint is
--- committed with it. Used with the two known-good values only; there is no
--- user-facing waveform picker (see the note at the top of this file).
--- @return nil on success, an error string otherwise.
local function setRefreshMode(mode)
    return callOnRootView("setRefreshMode", "(I)V", ffi.cast("jint", mode))
end

local TotalFresh = WidgetContainer:extend{
    name = "totalfresh",
}

function TotalFresh:init()
    self.rate = tonumber(G_reader_settings:readSetting(RATE_KEY)) or 0
    self.count = 0
    self.broken = false
    self.flip = 0
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function TotalFresh:setRate(rate)
    self.rate = rate
    self.count = 0
    self.broken = false
    G_reader_settings:saveSetting(RATE_KEY, rate)
end

function TotalFresh:onReaderReady()
    self.count = 0
end

function TotalFresh:onPageUpdate(page)
    if self.rate <= 0 or self.broken then return end
    self.count = self.count + 1
    if self.count < self.rate then return end
    self.count = 0

    -- Deliberately *not* ViewRootImpl.forceGlobalRefresh(): that fires a commit
    -- of its own, so a page turn flashes the old page and then draws the new
    -- one straight after (two panel updates, which is exactly the double
    -- refresh this is meant to avoid). Flipping the waveform instead makes
    -- KOReader's own single repaint come out as GC16.
    local err = setRefreshMode(FULL_MODE)
    if err then
        -- Nothing to retry every N pages, and the user should know rather than
        -- wonder why nothing flashes.
        self.broken = true
        logger.warn("totalfresh: full refresh failed:", err)
        UIManager:show(InfoMessage:new{
            text = T("本机无法触发全刷：\n%1", err),
            timeout = 10,
        })
        return
    end
    logger.info("totalfresh: full refresh at page", page)

    self.flip = self.flip + 1
    local flip = self.flip
    UIManager:scheduleIn(REVERT_DELAY_S, function()
        -- A newer full refresh already re-armed this; let its own revert win.
        if self.flip ~= flip then return end
        setRefreshMode(PARTIAL_MODE)
    end)
end

function TotalFresh:addToMainMenu(menu_items)
    -- Labels are Chinese on purpose: they mirror the 多看阅读 系统设置 -> 阅读全刷频率
    -- panel this is meant to replace. KOReader's own catalogue has no
    -- translation for these strings anyway.
    local rate_items = {}
    for _i, rate in ipairs(RATES) do
        rate_items[#rate_items + 1] = {
            text = T("%1页", rate),
            checked_func = function() return self.rate == rate end,
            callback = function() self:setRate(rate) end,
        }
    end
    rate_items[#rate_items + 1] = {
        text = "不全刷",
        checked_func = function() return self.rate == 0 end,
        callback = function() self:setRate(0) end,
    }

    -- The key has to be the plugin name: ZenOS' app launcher resolves entries
    -- with probe[plugin_key], and only falls back to "the single entry" when
    -- that misses. See zenos.koplugin/modules/menu/app_launcher/plugin_scan.lua
    menu_items.totalfresh = {
        text = "阅读全刷频率",
        sub_item_table = rate_items,
    }
end

return TotalFresh
