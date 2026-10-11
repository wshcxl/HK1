#!/bin/bash
# 在 feeds install 之后、make defconfig 之前运行：
# 1) 解决 appfilter 同名包被遮蔽的问题；2) 补 oaf(kmod) 的 Build/Prepare
set -e
cd openwrt

# ── 1) appfilter 同名冲突修正 ──────────────────────────────────────────────
# IMM packages 源的 net/open-app-filter 与 wshcxl/Open-App 的 open-app-filter 都定义了
# 名为 appfilter 的包（前者还提供 kmod-oaf）。feeds install -a 按包名去重，且 packages
# 源排在 oaf 源前面，于是 IMM 的 appfilter 先注册、Open-App 的 appfilter 被跳过（没建链接）。
# 结果：删掉 IMM 的链接后 appfilter 一个都不剩 -> opkg "cannot find dependency appfilter"。
# 这里手工修正：删掉 IMM 的 open-app-filter 链接，并把 Open-App 的 open-app-filter 链接进编译树。
rm -rf package/feeds/packages/open-app-filter

if [ ! -e package/feeds/oaf/open-app-filter ]; then
  mkdir -p package/feeds/oaf
  ln -sfn "$(pwd)/feeds/oaf/open-app-filter" package/feeds/oaf/open-app-filter
  echo "已手动链接 Open-App 的 open-app-filter（feeds install 因同名包跳过了它）"
fi

# ── 2) 补 oaf(kmod) 的 Build/Prepare ───────────────────────────────────────
# Open-App 的 oaf/Makefile 用 M="$(PKG_BUILD_DIR)" 编译，但 Kbuild 在 oaf/src/，
# 且缺 Build/Prepare 把 src/* 拷到 PKG_BUILD_DIR，内核模块编不出来。这里补上。
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
m = "define Build/Compile"
if m in s:
    s = s.replace(m, block + m, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print("patched", p)
else:
    print("marker not found", p)
PY
else
  echo "oaf Makefile 已含 Build/Prepare 或不存在，跳过补丁"
fi

# ── 3) 打印验证信息（进日志，方便排查）────────────────────────────────────
echo "--- package/feeds/oaf ---"
ls -l package/feeds/oaf/ 2>/dev/null || true
echo "--- appfilter 提供者（应只有 oaf/open-app-filter 一处）---"
ls -ld package/feeds/*/open-app-filter 2>/dev/null || true
echo "--- kmod-oaf 提供者 ---"
ls -ld package/feeds/*/oaf 2>/dev/null || true
