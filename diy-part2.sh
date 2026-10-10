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

# Modify default IP
sed -i 's/192.168.1.1/192.168.50.101/g' package/base-files/files/bin/config_generate

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
