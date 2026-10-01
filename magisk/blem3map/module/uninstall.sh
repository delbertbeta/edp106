#!/system/bin/sh
# 卸载/移除模块时把守护进程停掉，设备立刻变回一只普通鼠标
pkill -x blem3map 2>/dev/null
