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
        found="$(find "$c" -maxdepth 4 -type d -name 'amlogic-s9xxx-openwrt' 2>/dev/null | head -n1 || true)"
        if [ -n "$found" ] && [ -d "$found/make-openwrt" ]; then echo "$found"; return 0; fi
    done
    found="$(find / -maxdepth 6 -type d -name 'amlogic-s9xxx-openwrt' 2>/dev/null | head -n1 || true)"
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

MODTAR="$(find "$W/kb" -maxdepth 3 -name 'modules-*.tar.gz' | head -n1 || true)"
[ -n "$MODTAR" ] || { echo "❌ 内核包里找不到 modules-*.tar.gz"; exit 1; }
KB="$(dirname "$MODTAR")"
KNAME="$(basename "$MODTAR" .tar.gz)"; KNAME="${KNAME#modules-}"
echo "★ 内核名（kernel_name）: $KNAME"

# ---------------------------------------------------------------------------
sep "2) 解开模块树，读取目标 vermagic"
# ⚠️ 两个布局细节（都踩过）：
#   a) depmod -b <basedir> 认的是 <basedir>/lib/modules/<ver>/，所以必须解到 lib/modules 下面，
#      否则 depmod 直接报 "could not find module directory"；
#   b) oaf.ko 不能放模块目录顶层 —— ophub remake 第 976 行会执行
#        (cd .../lib/modules/${kernel_name}/ && rm -f build source *.ko && find ./ -type f -name '*.ko' -exec ln -s {} ./ \;)
#      顶层 *.ko 会被 rm 掉。所以要放进子目录（标准的外部模块位置 extra/），
#      它还会顺手给我们做一个顶层 oaf.ko 符号链接。
MROOT="$W/modroot/lib/modules"
mkdir -p "$MROOT"
tar -xzf "$MODTAR" -C "$MROOT"
KDIR="$MROOT/$KNAME"
[ -d "$KDIR" ] || { echo "❌ 模块目录结构异常："; ls -l "$MROOT" | head || true; exit 1; }
NKO="$(find "$KDIR" -name '*.ko' | wc -l)"
echo "模块目录：$KDIR（$NKO 个 .ko）"
echo "顶层 .ko 数量（这些在封装时会被删）：$(find "$KDIR" -maxdepth 1 -name '*.ko' | wc -l)"
SAMPLE="$(find "$KDIR" -name '*.ko' -print -quit 2>/dev/null || true)"
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
    printf '%-22s %s\n' "$m" "$(find "$KDIR" -name "$m" -print -quit 2>/dev/null || true)"
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
    HDEB="$(find "$W/db" -name 'linux-headers-*.deb' | head -n1 || true)"
    [ -n "$HDEB" ] || { echo "❌ deb 包里找不到 linux-headers"; find "$W/db" -maxdepth 2 | head -30 || true; exit 1; }
    echo "使用 headers deb：$HDEB"
    mkdir -p "$W/hdr"
    dpkg-deb -x "$HDEB" "$W/hdr"
    HROOT="$(find "$W/hdr/usr/src" -maxdepth 1 -type d -name 'linux-headers-*' | head -n1 || true)"
fi
[ -n "$HROOT" ] && [ -f "$HROOT/Makefile" ] || { echo "❌ 内核构建树不可用：$HROOT"; ls -l "$HROOT" 2>/dev/null | head -30 || true; exit 1; }
echo "★ 内核构建树：$HROOT"
ls -l "$HROOT" | head -n 30 || true
# ---------------------------------------------------------------------------
# ⚠️ 关键一步 0：禁止 make 去跑 syncconfig
#    ophub 的 header 包只含 include/ + scripts/ + arch 头文件，**没有 Kconfig 树**。
#    只要 make 认为配置需要刷新（include/config/auto.conf[/.cmd] 过期），它就会：
#      1) 现编 scripts/kconfig/conf（这步没问题）
#      2) 跑 syncconfig → "can't find file Kconfig" → 报错退出
#      3) 顺手删掉 include/generated/autoconf.h
#    结果：模块编译必然失败。这里把 Makefile 里所有跑 syncconfig 的**配方行**换成 echo
#    （配方行以 tab 开头；规则行不动，保证 Makefile 语法不变）。
echo "--- 打补丁：禁止 syncconfig（header 包里没有 Kconfig 树，不需要重新生成配置）---"
python3 - "$HROOT/Makefile" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
n = 0
out = []
for l in lines:
    if 'syncconfig' in l and l[:1] == '\t':
        out.append('\t@echo "（已跳过 syncconfig：header 包内没有 Kconfig 树）"')
        n += 1
    else:
        out.append(l)
open(p, 'w', encoding='utf-8', newline='\n').write('\n'.join(out))
print('已替换 %d 行 syncconfig 配方' % n)
PYEOF

# 保险 1：ophub 的 header 包用 `tar -czf header-*.tar.gz *` 打的，通配符不含点开头的文件，
#         所以包里**没有 .config**。make 在准备阶段可能会想去"重新生成配置"而报
#         "Configuration file .config not found"。这里用 include/config/auto.conf 复制一份顶上
#         （auto.conf 的内容就是 CONFIG_x=y/m，格式上等价于精简版 .config）。
if [ ! -f "$HROOT/.config" ] && [ -f "$HROOT/include/config/auto.conf" ]; then
    cp -f "$HROOT/include/config/auto.conf" "$HROOT/.config"
    echo "（包里没有 .config，已用 include/config/auto.conf 复制一份顶上）"
fi
# 保险 2：把生成物的时间戳推新，避免 make 认为配置过期而去重新生成（那需要 .config/Kconfig 链）
touch "$HROOT/include/config/auto.conf" "$HROOT/include/generated/autoconf.h" 2>/dev/null || true
touch "$HROOT/include/config/auto.conf.cmd" 2>/dev/null || true
touch "$HROOT/include/config/kernel.release" "$HROOT/include/generated/utsrelease.h" 2>/dev/null || true

# ---------------------------------------------------------------------------
# ⚠️ 关键一步：header 包里带着 ophub 构建机上编好的"宿主工具"
#    （scripts/basic/fixdep、scripts/mod/modpost 等），它们是**给 ophub 那台机器**编的，
#    在本 runner 上会报 "scripts/basic/fixdep: Exec format error"（Error 126），
#    从而整个模块编译失败。修法：把 scripts/ 下的 .o / 隐藏 .cmd / ELF 可执行文件删掉，
#    让 make 用本机 gcc（HOSTCC）重新编这些工具（源码都在包里）。
echo "--- 清理跨架构的宿主工具（fixdep/modpost 等），让本机重新编 ---"
find "$HROOT/scripts" -name '*.o' -delete 2>/dev/null || true
find "$HROOT/scripts" -name '.*.cmd' -delete 2>/dev/null || true
REMOVED=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    magic="$(head -c 4 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    if [ "$magic" = "7f454c46" ]; then
        echo "  删除: ${f#$HROOT/}"
        rm -f "$f" "${f%.*}.o" "$(dirname "$f")/.$(basename "$f").cmd"
        REMOVED=$((REMOVED+1))
    fi
done < <(find "$HROOT/scripts" -type f -perm -u+x 2>/dev/null)
echo "共清理 $REMOVED 个跨架构宿主工具"

# ---------------------------------------------------------------------------
# ⚠️ 关键一步 1.5：把 scripts/ 里"我们不需要、但 header 包缺源码"的宿主工具摘掉
#    header 包只含 include/ + scripts/ + arch 头文件，没有 security/、tools/ 目录，所以：
#      scripts/selinux/*  → fatal error: classmap.h: No such file or directory
#      scripts/sorttable  → fatal error: tools/be_byteshift.h: No such file or directory
#    这两个一失败，`make scripts` 整个中断，**必需的** scripts/mod/modpost 也就编不出来
#    （modpost 负责生成 .mod.c：vermagic / __this_module 都在里面，没它 oaf.ko 根本链接不出来）。
#    办法：注释掉 scripts/Makefile 里对应的 subdir-/hostprogs- 行，命令行变量再兜一层。
echo "--- 摘掉不需要的宿主工具（selinux / sorttable / gcc-plugins）---"
python3 - "$HROOT" <<'PYEOF'
import os
import sys
root = sys.argv[1]
p = os.path.join(root, 'scripts/Makefile')
if not os.path.exists(p):
    print('⚠️ 没找到 scripts/Makefile')
    sys.exit(0)
lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
KEYS = ('sorttable', 'selinux', 'gcc-plugins')
out = []
n = 0
for l in lines:
    if l[:1] != '\t' and any(k in l for k in KEYS) and ('+=' in l or 'subdir' in l or 'hostprogs' in l):
        out.append('# [inject-oaf] ' + l)
        n += 1
    else:
        out.append(l)
open(p, 'w', encoding='utf-8', newline='\n').write('\n'.join(out))
print('scripts/Makefile：已注释 %d 行' % n)
PYEOF

echo "--- 内核配置（从 include/config/auto.conf 读，包里没有 .config）---"
grep -E '^(CONFIG_MODVERSIONS|CONFIG_MODULE_SIG|CONFIG_MODULE_SIG_FORCE|CONFIG_MODULE_UNLOAD|CONFIG_SMP|CONFIG_PREEMPT|CONFIG_PREEMPT_NONE|CONFIG_LOCALVERSION=|CONFIG_DEBUG_INFO_BTF|CONFIG_MODULE_COMPRESS|CONFIG_MODULE_FORCE_LOAD)' "$HROOT/include/config/auto.conf" 2>/dev/null || echo "（无匹配项）"
echo "--- kernel.release ---"
cat "$HROOT/include/config/kernel.release" 2>/dev/null || echo "（缺 include/config/kernel.release）"
[ -f "$HROOT/Module.symvers" ] && echo "Module.symvers: $(wc -l < "$HROOT/Module.symvers") 行" || echo "⚠️ 没有 Module.symvers"

# ---------------------------------------------------------------------------
# ⚠️ 关键一步 2：显式预构建宿主工具
#    实测 `make -C <header树> M=<模块> modules` **不会**先跑 scripts_basic，
#    它直接就调 scripts/basic/fixdep 了（生成 .*.cmd 依赖用）。
#    ophub 包里那个是别的机器编的（Exec format error），我们删掉后必须自己先编好，
#    否则报 `scripts/basic/fixdep: not found`（Error 127）。
echo "--- 预构建宿主工具（fixdep / modpost，源码都在包里）---"
HOSTLOG="$W/hosttools.log"
# 命令行变量再兜一层：确保这些无关工具不会被拉起（BTF 我们也不需要，顺便省时间）
SKIP_TOOLS=(CONFIG_SECURITY_SELINUX= CONFIG_BUILDTIME_TABLE_SORT= CONFIG_GCC_PLUGINS= CONFIG_DEBUG_INFO_BTF=)
echo "### try 1: make scripts_basic scripts"
make -C "$HROOT" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$(nproc)" "${SKIP_TOOLS[@]}" \
     scripts_basic scripts >"$HOSTLOG" 2>&1 \
    || { echo "⚠️ make 返回非 0，输出如下："; tail -n 30 "$HOSTLOG" || true; }
if [ ! -x "$HROOT/scripts/basic/fixdep" ] || [ ! -x "$HROOT/scripts/mod/modpost" ]; then
    echo "### try 2: make modules_prepare"
    make -C "$HROOT" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$(nproc)" "${SKIP_TOOLS[@]}" \
         modules_prepare >"$HOSTLOG" 2>&1 \
        || { echo "⚠️ make 返回非 0，输出如下："; tail -n 30 "$HOSTLOG" || true; }
fi
MISSING_HOST=""
for f in scripts/basic/fixdep scripts/mod/modpost; do
    if [ -x "$HROOT/$f" ]; then
        echo "✅ 宿主工具就绪：$f"
    else
        echo "❌ 宿主工具缺失：$f"
        MISSING_HOST="$MISSING_HOST $f"
    fi
done
if [ -n "$MISSING_HOST" ]; then
    echo "⚠️⚠️ 缺这些宿主工具，接下来的模块编译一定失败：$MISSING_HOST"
    tail -n 40 "$HOSTLOG" || true
fi

# 复核编译必需的几个文件还在（syncconfig 失败时会删掉 include/generated/autoconf.h）
echo "--- 复核编译必需文件 ---"
MISSING_KEY=""
for f in include/generated/autoconf.h include/generated/utsrelease.h include/config/auto.conf Module.symvers; do
    if [ -e "$HROOT/$f" ]; then
        echo "✅ $f"
    else
        echo "❌ 缺 $f"
        MISSING_KEY="$MISSING_KEY $f"
    fi
done
if [ -n "$MISSING_KEY" ]; then
    echo "⚠️⚠️ 缺关键文件，模块编译会失败：$MISSING_KEY"
fi
# 时间戳再推一次（必须在 .config 之后，避免 make 以为配置过期）
touch "$HROOT/include/config/auto.conf" "$HROOT/include/generated/autoconf.h" 2>/dev/null || true

# ---------------------------------------------------------------------------
sep "4) 拉 OAF 源码并交叉编译 oaf.ko"
git clone --depth 1 -b "$OAF_BRANCH" "$OAF_REPO" "$W/Open-App"
SRC="$W/Open-App/oaf/src"
[ -f "$SRC/Makefile" ] || { echo "❌ OAF 源码结构异常"; find "$W/Open-App" -maxdepth 3 | head -40 || true; exit 1; }
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
    RK="$(ls "$WS"/artifact/*rootfs.tar.gz 2>/dev/null | head -n1 || true)"
    echo "rootfs 产物：$RK"
    [ -n "$RK" ] || { echo "❌ 找不到 rootfs（artifact/*rootfs.tar.gz），无法兜底"; exit 1; }
    mkdir -p "$W/immoaf"
    tar -xzf "$RK" --wildcards -C "$W/immoaf" './lib/modules/*/oaf.ko' 2>/dev/null || \
        tar -xzf "$RK" --wildcards -C "$W/immoaf" 'lib/modules/*/oaf.ko' 2>/dev/null || true
    FOUND="$(find "$W/immoaf" -name 'oaf.ko' | head -n1 || true)"
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
# 放进 extra/ 子目录（不能直接甩在顶层，会被 remake 的 rm -f *.ko 删掉，见 section 2 注释）
mkdir -p "$KDIR/extra"
cp -f "$BUILT" "$KDIR/extra/oaf.ko"
chmod 0644 "$KDIR/extra/oaf.ko"
echo "--- oaf.ko 信息 ---"
$MODINFO "$KDIR/extra/oaf.ko" | head -n 12 || true
echo "--- 运行 depmod -b $W/modroot -a $KNAME ---"
depmod -b "$W/modroot" -a "$KNAME" 2>&1 | tail -n 30 || true
if grep -q 'oaf\.ko' "$KDIR/modules.dep"; then
    echo "✅ modules.dep 已包含 oaf："
    grep 'oaf\.ko' "$KDIR/modules.dep"
else
    echo "❌ modules.dep 里没有 oaf 条目，加载会失败"
    ls -l "$KDIR"/modules.* 2>/dev/null | head || true
    exit 1
fi
# 复核物理文件确实在（且不在顶层）
echo "--- 复核 oaf.ko 物理位置 ---"
find "$KDIR" -name 'oaf.ko' -ls

# ---------------------------------------------------------------------------
sep "7) 重新打包 modules + 刷新 sha256sums"
( cd "$MROOT" && tar -czf "$KB/modules-$KNAME.tar.gz" "$KNAME" )
ls -lh "$KB/modules-$KNAME.tar.gz"
echo "--- 包内确认有 extra/oaf.ko ---"
tar -tzf "$KB/modules-$KNAME.tar.gz" | grep 'oaf\.ko' || { echo "❌ 打好的包里面没有 oaf.ko"; exit 1; }
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
# 兜底：modprobe 失败时直接 insmod。顶层是 ophub 做的符号链接，extra/ 是真实路径，两个都试。
INSMOD = ('for m in /lib/modules/$(uname -r)/oaf.ko '
          '/lib/modules/$(uname -r)/extra/oaf.ko; do\n'
          '\t\t\t[ -f "$m" ] && insmod "$m" && break\n'
          '\t\tdone')
old = '\tlsmod |grep "oaf" >/dev/null\n\tif [ $? -ne 0 ];then\n\t\tmodprobe oaf\n\tfi'
new = ('\tlsmod |grep "oaf" >/dev/null\n'
       '\tif [ $? -ne 0 ];then\n'
       '\t\tmodprobe nf_conntrack 2>/dev/null\n'
       '\t\tmodprobe oaf 2>/dev/null\n'
       '\t\tlsmod |grep "oaf" >/dev/null || ' + INSMOD + '\n'
       '\tfi')
if old in s:
    s = s.replace(old, new, 1)
    print('✅ 已给 appfilter.init 的 modprobe 加 insmod 兜底')
else:
    s = s.replace('modprobe oaf',
                  'modprobe oaf 2>/dev/null\n\t\tlsmod |grep "oaf" >/dev/null || ' + INSMOD,
                  1)
    print('⚠️ 没匹配到原始片段，已在 modprobe oaf 后追加兜底')
open(dst, 'w', encoding='utf-8').write(s)
PYEOF
    chmod 0755 "$KOUT/etc/init.d/appfilter"
    echo "--- 生成结果中的 oaf 相关行 ---"
    grep -n 'oaf' "$KOUT/etc/init.d/appfilter" | head -n 20 || true
else
    echo "⚠️ 找不到 appfilter.init（$INIT_SRC），跳过"
fi
find "$KOUT" -type f -printf '%10s  %p\n'

sep "全部完成：oaf.ko 已注入内核模块包，openwrt_files 已生成"
