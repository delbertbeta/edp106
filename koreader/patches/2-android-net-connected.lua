--[[--
让 KOReader 在安卓上认得出非 Wi-Fi/蜂窝的网络（蓝牙 PAN、VPN）。

KOReader 的安卓后端判断"联没联网"是这么来的：

  Device:initNetworkManager() ->
    NetworkMgr:isConnected()  ->  android.getNetworkInfo()

而 Java 侧（org.koreader.launcher.extensions.ActivityExtensions.networkInfo()）
只认这三种 transport：

  hasTransport(TRANSPORT_WIFI)      -> 1  (Wi-Fi)
  hasTransport(TRANSPORT_CELLULAR)  -> 2  (移动数据)
  hasTransport(TRANSPORT_ETHERNET)  -> 3  (以太网)
  其余一律                          -> 0  (未连接)

蓝牙网络共享是 Transports: BLUETOOTH，VPN 是 TRANSPORT_VPN，
两个都落进"其余"，于是 networkInfo() 返回 "0;0"，
isConnected() 恒为 false —— 菜单里显示"未连接"，同步/下载插件会先弹"要开 Wi-Fi 吗"，
哪怕网络其实是通的（浏览器、微信读书都正常，它们不看这个 API）。

这里改成看**内核路由表**：有默认路由就算 connected。
NetworkMgr:hasDefaultRoute() 只对 203.0.113.1 做一次路由查找（setpeername，
不发包、不解析域名），开销可以忽略；网络真的断掉时它也会如实返回 false。

安装位置：
  koreader/patches/2-android-net-connected.lua
（文件名开头的 2 = late 优先级，此时 Device/NetworkMgr 都已初始化完毕）
]]--

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

if Device:isAndroid() then
    local orig_isConnected = NetworkMgr.isConnected

    NetworkMgr.isConnected = function(self)
        if not Device:hasWifiToggle() then
            return true
        end
        -- 有默认路由（Wi-Fi / 蓝牙 PAN / VPN 都算）就是连着的
        if self:hasDefaultRoute() then
            return true
        end
        -- 兜底：万一 socket 那套不可用，至少别丢掉原生判断
        return orig_isConnected(self)
    end

    -- initNetworkManager() 里执行过 `NetworkMgr.isWifiOn = NetworkMgr.isConnected`，
    -- 那是绑到旧函数上的，这里必须跟着一起换掉，否则 isWifiOn 还是老逻辑。
    NetworkMgr.isWifiOn = NetworkMgr.isConnected

    -- "网络信息"菜单是同一份 Java 数据的直连透视，同样认不出蓝牙/VPN，
    -- 不改的话它会在联网时显示"未连接"，和实际状态打架。
    local orig_retrieveNetworkInfo = Device.retrieveNetworkInfo
    Device.retrieveNetworkInfo = function(self)
        local text = orig_retrieveNetworkInfo(self)
        if text == _("Not connected") and NetworkMgr:hasDefaultRoute() then
            -- 不给接口名：默认路由可能落在 main 之外的表里（这个 ROM 的蓝牙 PAN
            -- 就在 table 1010）而 /proc/net/route 只看 main，硬查会得到个误导性的结果。
            return _("Connected")
        end
        return text
    end
end
