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

# ===== Argon 主题（烤进固件，刷完即用，不用每次刷机再装）=====
# 用 v2.4.8-hotfix：LUCI_DEPENDS 只有 wget+jsonfilter，适配 LuCI 23.05。
# master(v3.x) 依赖 ucode 模板（ucode-mod-math + .ut 文件），23.05 的 luci-base 没有 ucode，不能用。
echo "diy-part2: 克隆 Argon 主题 v2.4.8-hotfix（适配 23.05）"
git clone --depth 1 -b release/v2.4.8-hotfix https://github.com/jerrykuku/luci-theme-argon package/hk1/luci-theme-argon

# 配套设置插件（换色/毛玻璃/壁纸），v2.5.0-beta.1 是配 v2 主题的版本；
# master 已变成 v3 时代的"空壳迁移包"（只是占位，设置已并入 v3 主题本体），不能用。
echo "diy-part2: 克隆 luci-app-argon-config v2.5.0-beta.1（配 v2 主题）"
git clone --depth 1 -b v2.5.0-beta.1 https://github.com/jerrykuku/luci-app-argon-config package/hk1/luci-app-argon-config

# 校验克隆结果，失败立刻报错中止（主题缺了编译能过但刷出来没有，属静默失败，必须防）
for P in package/hk1/luci-theme-argon/Makefile package/hk1/luci-app-argon-config/Makefile; do
  if [ ! -f "$P" ]; then
    echo "::error::克隆 Argon 失败：缺 $P"
    exit 1
  fi
done
echo "diy-part2: Argon 主题三件套克隆完成"
