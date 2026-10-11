#!/bin/bash
# ============================================================================
# inject-oaf.sh —— 让 OAF 的内核模块 oaf.ko 在 ophub 内核上也能用
#
# 背景（为什么必须干这件事）：
#   ophub 的 remake 脚本在封装时会执行：
#     1) 解开我们编好的 OpenWrt rootfs；
#     2) rm -rf ${rootfs}/lib/modules/*      ← 把我们编的 kmod 全删掉
#     3) 把 ophub 内核包里的 modules-<kernel_name>.tar.gz 解到 /lib/modules
#   也就是说：内核和模块全部由 ophub 提供，我们自己编的 oaf.ko 会被丢掉。
#   而 OAF 的 appfilter 启动脚本是 `modprobe oaf`，没有 oaf.ko 就等于 OAF 废掉。
#
# 本脚本做的事（在调用 ophub action 之前跑）：
#   1) 下载 ophub 对应版本的内核包（里面就有编译好的内核 header 树，
#      含 .config / Module.symvers / include/generated → 能编出 vermagic 完全匹配的模块）；
#   2) 用这棵 header 树交叉编译 oaf.ko（对着 ophub 内核编，vermagic 天然一致）；
#   3) 校验 vermagic，不一致就原地改写 .modinfo 里的字符串再校验；
#   4) 把 oaf.ko 注入模块树，跑 depmod 重建 modules.dep；
#   5) 重新打包 modules-*.tar.gz + 刷新 sha256sums；
#   6) 放到 <action>/make-openwrt/kernel/<tag>/<version>/，remake 检测到目录已存在就跳过下载；
#   7) 顺带把 OAF 的 appfilter 启动脚本打成 openwrt_files（modprobe 失败用 insmod 兜底），
#      文件名/内容与 Open-App 仓库一致，只是加了两行兜底。
#
# 用法：KVER=5.15.222 KTAG=stable bash inject-oaf.sh
# 退出码：0=成功；非 0=失败（失败时镜像里不会有 oaf.ko）
# ============================================================================
set -euo pipefail

KVER="${KVER:?必须指定具体内核版本，例如 KVER=5.15.222}"
KTAG="${KTAG:-stable}"                       # stable / flippy / beta
OWNER="${OWNER:-ophub}"
OAF_REPO="${OAF_REPO:-https://github.com/wshcxl/Open-App.git}"
OAF_BRANCH="${OAF_BRANCH:-master}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
WS="${GITHUB_WORKSPACE:-$(pwd)}"
W="$WS/oafwork"
KOUT="$WS/oaf-files"                         # 作为 action 的 openwrt_files 输入

sep() { echo; echo "==================== $* ===================="; }

# ---------------------------------------------------------------------------
sep "0) 环境检查 / 定位 ophub action 目录"
# ⚠️ 注意：GitHub 会把 composite action 解到 /home/runner/work/_actions/<owner>/<repo>/<ref>，
#    这个目录**不在** GITHUB_WORKSPACE 里面（WS=/home/runner/work/HK1/HK1），
#    所以 $(dirname "$WS")/_actions 是错的（会拼成 /home/runner/work/HK1/_actions）。
#    这里按候选路径逐个试 + find 兜底。
resolve_act() {
    local c found
    if [ -n "${ACT_DIR:-}" ] && [ -d "$ACT_DIR/make-openwrt" ]; then
        echo "$ACT_DIR"; return 0
    fi
    for c in \
        "/home/runner/work/_actions/ophub/amlogic-s9xxx-openwrt/main" \
        "${RUNNER_WORKSPACE:-}/../_actions/ophub/amlogic-s9xxx-openwrt/main" \
        "$(dirname "$WS")/_actions/ophub/amlogic-s9xxx-openwrt/main" \
        "$(dirname "$(dirname "$WS")")/_actions/ophub/amlogic-s9xxx-openwrt/main" \
        "$HOME/work/_actions/ophub/amlogic-s9xxx-openwrt/main"
    do
        if [ -d "$c/make-openwrt" ]; then echo "$c"; return 0; fi
    done
    for c in "/home/runner/work/_actions" "$(dirname "$WS")/_actions" \
             "$(dirname "$(dirname "$WS")")/_actions" "$HOME/work/_actions"; do
        if [ ! -d "$c" ]; then continue; fi
        found="$(find "$c" -maxdepth 4 -type d -name 'amlogic-s9xxx-openwrt' 2>/dev/null | head -n1)"
        if [ -n "$found" ] && [ -d "$found/make-openwrt" ]; then echo "$found"; return 0; fi
    done
    found="$(find / -maxdepth 6 -type d -name 'amlogic-s9xxx-openwrt' 2>/dev/null | head -n1)"
    if [ -n "$found" ]; then echo "$found"; return 0; fi
    return 1
}
ACT="$(resolve_act || true)"
if [ -z "${ACT:-}" ] || [ ! -d "$ACT/make-openwrt" ]; then
    echo "❌ 找不到 ophub action 目录"
    echo "--- /home/runner/work/_actions ---"
    ls -la /home/runner/work/_actions 2>/dev/null || echo "（不存在）"
    echo "--- $(dirname "$WS")/_actions ---"
    ls -la "$(dirname "$WS")/_actions" 2>/dev/null || echo "（不存在）"
    exit 1
fi
rm -rf "$W" "$KOUT"
mkdir -p "$W" "$KOUT"
echo "内核版本：$KVER (kernel_$KTAG)"
echo "action  ：$ACT"
echo "交叉编译：$CROSS"
echo "工作目录：$W"
command -v aarch64-linux-gnu-gcc >/dev/null || { echo "❌ 缺 gcc-aarch64-linux-gnu"; exit 1; }
command -v depmod >/dev/null || { echo "❌ 缺 kmod(depmod)"; exit 1; }

# ---------------------------------------------------------------------------
sep "1) 下载 ophub 内核包（含 boot / dtb / modules / header）"
DL="https://github.com/$OWNER/kernel/releases/download/kernel_$KTAG"
curl -fsSL --retry 5 --retry-delay 15 -o "$W/kernel.tar.gz" "$DL/$KVER.tar.gz"
ls -lh "$W/kernel.tar.gz"
mkdir -p "$W/kb"
tar -xzf "$W/kernel.tar.gz" -C "$W/kb"
echo "--- 包内结构 ---"
find "$W/kb" -maxdepth 3 -type f -printf '%10s  %p\n' | sort -k2

MODTAR="$(find "$W/kb" -maxdepth 3 -name 'modules-*.tar.gz' | head -n1)"
[ -n "$MODTAR" ] || { echo "❌ 内核包里找不到 modules-*.tar.gz"; exit 1; }
KB="$(dirname "$MODTAR")"
KNAME="$(basename "$MODTAR" .tar.gz)"; KNAME="${KNAME#modules-}"
echo "★ 内核名（kernel_name）: $KNAME"

# ---------------------------------------------------------------------------
sep "2) 解开模块树，读取目标 vermagic"
mkdir -p "$W/modroot"
tar -xzf "$MODTAR" -C "$W/modroot"
KDIR="$W/modroot/$KNAME"
[ -d "$KDIR" ] || { echo "❌ 模块目录结构异常："; ls -l "$W/modroot" | head; exit 1; }
NKO="$(find "$KDIR" -name '*.ko' | wc -l)"
echo "模块目录：$KDIR（$NKO 个 .ko）"
SAMPLE="$(find "$KDIR" -name '*.ko' | head -n1)"
MODINFO="$(command -v modinfo || echo modinfo)"
TARGET_VM="$($MODINFO -F vermagic "$SAMPLE" 2>/dev/null || true)"
echo "样本模块：$SAMPLE"
echo "★ 目标 vermagic: [$TARGET_VM]"
if [ -f "$KDIR/modules.dep" ]; then
    echo "模块包内已有 modules.dep（$(wc -l < "$KDIR/modules.dep") 行）"
else
    echo "模块包内没有 modules.dep（depmod 会自动生成）"
fi
echo "--- 关键依赖是否存在 ---"
for m in nf_conntrack.ko nf_reject_ipv4.ko br_netfilter.ko overlay.ko veth.ko usb-storage.ko; do
    printf '%-22s %s\n' "$m" "$(find "$KDIR" -name "$m" | head -n1 || true)"
done

# ---------------------------------------------------------------------------
sep "3) 准备内核构建树（优先用包内 header-*.tar.gz，否则用 deb 里的 linux-headers）"
HROOT=""
HTAR="$(find "$W/kb" -maxdepth 3 -name 'header-*.tar.gz' | head -n1 || true)"
if [ -n "$HTAR" ]; then
    echo "使用包内 header：$HTAR"
    mkdir -p "$W/hdr"
    tar -xzf "$HTAR" -C "$W/hdr"
    HROOT="$W/hdr"
else
    echo "包内无 header-*.tar.gz，改用 deb 包里的 linux-headers"
    curl -fsSL --retry 5 --retry-delay 15 -o "$W/deb.tar.gz" "$DL/deb-$KVER.tar.gz"
    ls -lh "$W/deb.tar.gz"
    mkdir -p "$W/db"
    tar -xzf "$W/deb.tar.gz" -C "$W/db"
    HDEB="$(find "$W/db" -name 'linux-headers-*.deb' | head -n1)"
    [ -n "$HDEB" ] || { echo "❌ deb 包里找不到 linux-headers"; find "$W/db" -maxdepth 2 | head -30; exit 1; }
    echo "使用 headers deb：$HDEB"
    mkdir -p "$W/hdr"
    dpkg-deb -x "$HDEB" "$W/hdr"
    HROOT="$(find "$W/hdr/usr/src" -maxdepth 1 -type d -name 'linux-headers-*' | head -n1)"
fi
[ -n "$HROOT" ] && [ -f "$HROOT/Makefile" ] || { echo "❌ 内核构建树不可用：$HROOT"; ls -l "$HROOT" 2>/dev/null | head -30; exit 1; }
echo "★ 内核构建树：$HROOT"
ls -l "$HROOT" | head -n 30
# 保险：ophub 的 header 包里没有内核顶层 Kconfig，若 make 认为 auto.conf 过期会去重新生成配置而报错。
# 把生成的配置/头文件时间戳推新，避免触发配置再生（不碰 .config，否则反而会触发）。
touch "$HROOT/include/config/auto.conf" "$HROOT/include/generated/autoconf.h" 2>/dev/null || true
touch "$HROOT/include/config/auto.conf.cmd" 2>/dev/null || true
echo "--- .config 关键项 ---"
grep -E '^(CONFIG_MODVERSIONS|CONFIG_MODULE_SIG|CONFIG_MODULE_SIG_FORCE|CONFIG_MODULE_UNLOAD|CONFIG_SMP|CONFIG_PREEMPT|CONFIG_PREEMPT_NONE|CONFIG_LOCALVERSION=|CONFIG_DEBUG_INFO_BTF|CONFIG_MODULE_COMPRESS)' "$HROOT/.config" || echo "（无匹配项）"
echo "--- kernel.release ---"
cat "$HROOT/include/config/kernel.release" 2>/dev/null || echo "（缺 include/config/kernel.release）"
[ -f "$HROOT/Module.symvers" ] && echo "Module.symvers: $(wc -l < "$HROOT/Module.symvers") 行" || echo "⚠️ 没有 Module.symvers"

# ---------------------------------------------------------------------------
sep "4) 拉 OAF 源码并交叉编译 oaf.ko"
git clone --depth 1 -b "$OAF_BRANCH" "$OAF_REPO" "$W/Open-App"
SRC="$W/Open-App/oaf/src"
[ -f "$SRC/Makefile" ] || { echo "❌ OAF 源码结构异常"; find "$W/Open-App" -maxdepth 3 | head -40; exit 1; }
echo "--- OAF 模块源码 ---"
ls -l "$SRC"

KCFLAGS="-Wno-error -Wno-error=missing-prototypes -Wno-error=missing-declarations -Wno-error=unused-variable \
-Wno-error=declaration-after-statement -Wno-error=implicit-fallthrough -Wno-error=missing-braces \
-Wno-error=parentheses -Wno-error=format -Wno-frame-larger-than"

echo "--- 开始编译（失败会把最后 150 行日志打出来）---"
BUILT="$SRC/oaf.ko"
rm -f "$BUILT"
COMPILE_OK=0
if make -C "$HROOT" M="$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" \
        KCFLAGS="$KCFLAGS" WERROR=0 modules -j"$(nproc)" 2>&1 | tail -n 150; then
    if [ -f "$BUILT" ]; then
        COMPILE_OK=1
    fi
fi

if [ "$COMPILE_OK" != "1" ]; then
    echo
    echo "⚠️⚠️⚠️ 对着 ophub 内核直接编译 oaf.ko 失败（源码与 flippy 内核可能不兼容）"
    echo "⚠️ 退回兜底方案：用 rootfs 里 ImmortalWrt 自己编好的 oaf.ko，改写 vermagic 后注入。"
    echo "⚠️ 注意：这条路的成功率取决于 ophub 内核是否开了 CONFIG_MODVERSIONS（开了会因符号校验失败）。"
    RK="$(ls "$WS"/artifact/*rootfs.tar.gz 2>/dev/null | head -n1)"
    echo "rootfs 产物：$RK"
    [ -n "$RK" ] || { echo "❌ 找不到 rootfs（artifact/*rootfs.tar.gz），无法兜底"; exit 1; }
    mkdir -p "$W/immoaf"
    tar -xzf "$RK" --wildcards -C "$W/immoaf" './lib/modules/*/oaf.ko' 2>/dev/null || \
        tar -xzf "$RK" --wildcards -C "$W/immoaf" 'lib/modules/*/oaf.ko' 2>/dev/null || true
    FOUND="$(find "$W/immoaf" -name 'oaf.ko' | head -n1)"
    [ -n "$FOUND" ] || { echo "❌ rootfs 里没找到 oaf.ko（说明 rootfs 编译阶段就没编出来）"; exit 1; }
    cp -f "$FOUND" "$BUILT"
    echo "已取用：$FOUND"
fi
[ -f "$BUILT" ] || { echo "❌ 最终没有可用的 oaf.ko"; ls -l "$SRC"; exit 1; }
echo "★ 使用：$BUILT"
file "$BUILT" || true

# ---------------------------------------------------------------------------
sep "5) 校验 vermagic（不一致则原地改写并复核）"
GOT_VM="$($MODINFO -F vermagic "$BUILT" 2>/dev/null || true)"
echo "★ 新编 vermagic  : [$GOT_VM]"
echo "★ 目标 vermagic  : [$TARGET_VM]"
if [ -n "$TARGET_VM" ] && [ "$GOT_VM" != "$TARGET_VM" ]; then
    echo "⚠️ 两者不一致 —— 尝试原地改写 .modinfo 里的 vermagic 字符串"
    python3 - "$BUILT" "$GOT_VM" "$TARGET_VM" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
data = bytearray(open(path, 'rb').read())
needle = old.encode() + b'\x00'
i = data.find(needle)
if i < 0:
    print('❌ 在 .ko 里找不到 vermagic 字符串'); sys.exit(2)
if len(new) > len(old):
    print('❌ 目标 vermagic 更长（%d > %d），无法原地替换' % (len(new), len(old))); sys.exit(3)
blob = new.encode() + b'\x00' * (len(old) - len(new) + 1)
data[i:i + len(blob)] = blob
open(path, 'wb').write(data)
print('✅ vermagic 已改写为 [%s]' % new)
PYEOF
    NEW_VM="$($MODINFO -F vermagic "$BUILT" 2>/dev/null || true)"
    echo "★ 改写后 vermagic: [$NEW_VM]"
    [ "$NEW_VM" = "$TARGET_VM" ] || { echo "❌ vermagic 改写后仍不一致"; exit 1; }
else
    echo "✅ vermagic 一致（或目标未知），无需改写"
fi

# ---------------------------------------------------------------------------
sep "6) 注入 oaf.ko + depmod 重建索引"
cp -f "$BUILT" "$KDIR/oaf.ko"
chmod 0644 "$KDIR/oaf.ko"
echo "--- oaf.ko 信息 ---"
$MODINFO "$KDIR/oaf.ko" | head -n 12 || true
echo "--- 运行 depmod -b <模块树> -a $KNAME ---"
depmod -b "$W/modroot" -a "$KNAME"
if grep -q 'oaf\.ko' "$KDIR/modules.dep"; then
    echo "✅ modules.dep 已包含 oaf："
    grep 'oaf\.ko' "$KDIR/modules.dep"
else
    echo "❌ modules.dep 里没有 oaf 条目，加载会失败"
    ls -l "$KDIR"/modules.* 2>/dev/null | head
    exit 1
fi

# ---------------------------------------------------------------------------
sep "7) 重新打包 modules + 刷新 sha256sums"
( cd "$W/modroot" && tar -czf "$KB/modules-$KNAME.tar.gz" "$KNAME" )
ls -lh "$KB/modules-$KNAME.tar.gz"
if [ -f "$KB/sha256sums" ]; then
    ( cd "$KB" && sha256sum ./*.tar.gz > sha256sums )
    echo "--- 刷新后的 sha256sums ---"
    cat "$KB/sha256sums"
else
    echo "包内没有 sha256sums，跳过（remake 也不会校验）"
fi

# ---------------------------------------------------------------------------
sep "8) 放到 ophub 的内核目录（remake 见到目录已存在就跳过下载）"
DEST="$ACT/make-openwrt/kernel/$KTAG/$KVER"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$KB"/. "$DEST"/
ls -lh "$DEST"

# ---------------------------------------------------------------------------
sep "9) 生成 openwrt_files：appfilter 启动脚本加 insmod 兜底"
INIT_SRC="$W/Open-App/open-app-filter/files/appfilter.init"
mkdir -p "$KOUT/etc/init.d"
if [ -f "$INIT_SRC" ]; then
    python3 - "$INIT_SRC" "$KOUT/etc/init.d/appfilter" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
old = '\tlsmod |grep "oaf" >/dev/null\n\tif [ $? -ne 0 ];then\n\t\tmodprobe oaf\n\tfi'
new = ('\tlsmod |grep "oaf" >/dev/null\n'
       '\tif [ $? -ne 0 ];then\n'
       '\t\tmodprobe nf_conntrack 2>/dev/null\n'
       '\t\tmodprobe oaf 2>/dev/null\n'
       '\t\tlsmod |grep "oaf" >/dev/null || insmod /lib/modules/$(uname -r)/oaf.ko\n'
       '\tfi')
if old in s:
    s = s.replace(old, new, 1)
    print('✅ 已给 appfilter.init 的 modprobe 加 insmod 兜底')
else:
    s = s.replace('modprobe oaf',
                  'modprobe oaf 2>/dev/null\n\t\tlsmod |grep "oaf" >/dev/null || insmod /lib/modules/$(uname -r)/oaf.ko',
                  1)
    print('⚠️ 没匹配到原始片段，已在 modprobe oaf 后追加兜底')
open(dst, 'w', encoding='utf-8').write(s)
PYEOF
    chmod 0755 "$KOUT/etc/init.d/appfilter"
    echo "--- 生成结果中的 oaf 相关行 ---"
    grep -n 'oaf' "$KOUT/etc/init.d/appfilter" | head -n 20
else
    echo "⚠️ 找不到 appfilter.init（$INIT_SRC），跳过"
fi
find "$KOUT" -type f -printf '%10s  %p\n'

sep "全部完成：oaf.ko 已注入内核模块包，openwrt_files 已生成"
