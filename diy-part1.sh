#!/bin/bash
#
# HK1 Box ImmortalWrt 编译：diy-part1（更新 feeds 之前执行）
# 作用：把 OAF(OpenAppFilter) 应用特征库仓库作为 feed 加进来
#

# 追加 OAF(OpenAppFilter) 应用特征库 feed
# 仓库根目录下就是三个包：oaf(内核模块) / open-app-filter(守护进程+feature.bin特征库) / luci-app-oaf(LuCI界面)
echo 'src-git oaf https://github.com/wshcxl/Open-App' >>feeds.conf.default
