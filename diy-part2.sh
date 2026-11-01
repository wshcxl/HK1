#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# 修改默认 IP
# 注意：刷完首次开机就用这个 IP，不用再改。选192.168.1.96 是因为用户家路由器在 192.168.1.1
# （.95 打印机 / .99 电视盒子 / .110 录像机 / .156 电脑，.96 是空位），这样盒子可以直接当旁路由用。
sed -i 's/192.168.1.1/192.168.1.96/g' package/base-files/files/bin/config_generate

# 默认 LuCI 语言设为中文（zh_cn）—— 仅当 ZH_DEFAULT=1 时启用
# 两种构建都会内置 luci-i18n-base-zh-cn，可随时在 Web 界面切换语言
if [ "$ZH_DEFAULT" = "1" ]; then
  LUCI_CFG=package/feeds/luci/luci-base/root/etc/config/luci
  if [ -f "$LUCI_CFG" ]; then
    sed -i "s/option lang '[^']*'/option lang 'zh_cn'/" "$LUCI_CFG"
    echo "已将默认语言设置为中文"
  else
    echo "未找到 $LUCI_CFG，跳过语言设置"
  fi
else
  echo "ZH_DEFAULT 未开启，保持英文默认语言"
fi

# ===== Alpha 主题（用户指定：左侧栏导航 + 登录页全屏壁纸毛玻璃，IMM 社区流行款）=====
# luci-theme-alpha 是 Lua 版主题，适配 LuCI 23.05；运行依赖 luci-compat（.config 已加）。
echo "diy-part2: 克隆 luci-theme-alpha（左侧栏主题）"
git clone --depth 1 https://github.com/derisamedia/luci-theme-alpha package/hk1/luci-theme-alpha

# 校验克隆结果，失败立刻报错中止（主题缺了编译能过但刷出来没有，属静默失败，必须防）
if [ ! -f package/hk1/luci-theme-alpha/Makefile ]; then
  echo "::error::克隆 luci-theme-alpha 失败：缺 Makefile"
  exit 1
fi
echo "diy-part2: Alpha 主题克隆完成"
