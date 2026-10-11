#!/bin/bash
# 修复 OAF 编译的两类问题（在 feeds install 之后、make defconfig 之前运行）
set -e
cd openwrt

# 1) 移除 IMM 自带 packages feed 里的 open-app-filter。
#    IMM 的 open-app-filter 也会生成 kmod-oaf / appfilter，与 wshcxl/Open-App 的同名包重名，
#    导致 kconfig "symbol PACKAGE_kmod-oaf is selected by PACKAGE_kmod-oaf" 递归依赖，
#    kmod-oaf 被丢弃 -> 打包阶段 "cannot find dependency kmod-oaf"。
#    统一只用 Open-App 的 OAF 全套（kmod-oaf / appfilter / luci-app-oaf）。
rm -rf package/feeds/packages/open-app-filter
echo "已移除 IMM 自带 open-app-filter（避免与 Open-App 的 kmod-oaf/appfilter 重名冲突）"

# 2) 修复 Open-App 的 oaf(kmod) Makefile：
#    它的 Build/Compile 用 M="$(PKG_BUILD_DIR)"，但真正的 Kbuild 在 oaf/src/，
#    而包 Makefile 没有 Build/Prepare 把 src/* 拷到 PKG_BUILD_DIR，导致内核模块编不出来。
#    这里补一个 Build/Prepare。
OAF_MK=package/feeds/oaf/oaf/Makefile
[ -f "$OAF_MK" ] || OAF_MK=feeds/oaf/oaf/Makefile
if [ -f "$OAF_MK" ] && ! grep -q "define Build/Prepare" "$OAF_MK"; then
python3 - "$OAF_MK" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
block = (
    "define Build/Prepare\n"
    "\tmkdir -p $(PKG_BUILD_DIR)\n"
    "\t$(CP) ./src/* $(PKG_BUILD_DIR)/\n"
    "endef\n\n"
)
marker = "define Build/Compile"
if marker in s:
    s = s.replace(marker, block + marker, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print("patched", p)
else:
    print("marker not found in", p)
PY
else
  echo "oaf Makefile 已含 Build/Prepare 或不存在，跳过补丁"
fi
