#!/bin/bash
#
# HK1 Box ImmortalWrt 编译：diy-part1（更新 feeds 之前执行）
#
# 加入 OAF(OpenAppFilter) 特征库 feed。
# wshcxl/Open-App 提供三件套：
#   oaf            -> kmod-oaf（内核模块 oaf.ko，应用识别/家长控制核心）
#   open-app-filter-> appfilter（守护进程 oafd + feature.bin）
#   luci-app-oaf   -> LuCI 管理界面
echo "diy-part1: 追加 OAF feed (wshcxl/Open-App)"
echo 'src-git oaf https://github.com/wshcxl/Open-App' >> feeds.conf.default

# 加入 QModem 特征库 feed（4G/5G USB 模组拨号）。
# wshcxl/QModem（FUjr/QModem 的 fork）提供：
#   application/qmodem        -> qmodem（拨号守护进程 + 模组管理）
#   luci/luci-app-qmodem-next -> LuCI 管理界面
#   luci/luci-i18n-qmodem-next-zh-cn -> 中文语言包
echo "diy-part1: 追加 QModem feed (wshcxl/QModem)"
echo 'src-git qmodem https://github.com/wshcxl/QModem' >> feeds.conf.default
