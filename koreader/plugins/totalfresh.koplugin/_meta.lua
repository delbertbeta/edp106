return {
    fullname = "阅读全刷频率",
    description = [[翻页 1/5/10/20 次后强制一次真正的墨水屏全刷（GC16）。

KOReader 自带的「Full refresh rate」在这台机器上不起作用 —— 它的 Android launcher 认不出这块屏的控制器（墨案 EPD106 / Allwinner virgo），于是 Screen:refreshFull() 只做一次普通 blit，不会闪。本插件自己数翻页，通过窗口管理器直接触发全刷。

刷新波形（快速/普通）由系统设置负责，本插件不再碰。]],
}
