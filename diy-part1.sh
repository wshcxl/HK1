#!/bin/bash
#
# HK1 Box ImmortalWrt 编译：diy-part1（更新 feeds 之前执行）
#
# 说明：原计划的 OAF(OpenAppFilter) 内核模块在此盒子的"armsr 编译 → ophub 封装"流程里
# 无法干净集成——其源码有 kconfig 自引用 bug 会导致 kmod-oaf 在配置阶段被丢弃，且
# ophub 封装会换成自己的 Flippy 内核，oaf.ko 的版本魔法必然与运行时内核对不上。
# 故改用官方即可编译的网络监控/管控插件（nlbwmon / netdata / statistics / adblock-fast / sqm）
# 来实现"监控网络"的需求，不再引入任何自定义内核模块 feed。
# 因此此处不再追加额外 feed。
echo "diy-part1: 无需追加额外 feed（OAF 已弃用，改用官方监控/管控插件）"
