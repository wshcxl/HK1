# HK1 Box (Amlogic S905X3) ImmortalWrt + OAF 固件

自动编译适合 **HK1 Box / Vontar X3** 刷入的 ImmortalWrt 固件，内置：

- **OAF（OpenAppFilter）**：应用识别 + 家长控制/上网监控（`oaf.ko` + `appfilter`(oafd) + `luci-app-oaf`）
- **Docker**：`docker` / `dockerd` / `luci-app-dockerman`
- **流量监控**：`nlbwmon` + LuCI 界面
- **WiFi**：brcm4339 SDIO 无线网卡用户态（`wpad-mbedtls`）
- 常用工具：curl、nano、htop、bash、fdisk、e2fsprogs、iperf3、tcpdump、samba4、ttyd、upnp

默认管理地址：**192.168.1.96**（无密码，首次登录请立刻设置；IP 烤在固件里，刷完直接用，不用再改）

---

## 一、怎么编译

仓库 → Actions → `Build HK1 Box ImmortalWrt + OAF` → Run workflow。

| 输入 | 说明 |
| --- | --- |
| `zh_default` | true = LuCI 默认中文（两种都内置中文语言包，可随时切换） |
| `immortalwrt_branch` | 默认 `openwrt-23.05`（内核 5.15，对 OAF 内核模块最友好） |
| `kernel` | ophub 内核**具体版本**，默认 `5.15.222`。**改了它就要同时改 `inject-oaf.sh` 的编译目标**，否则 oaf.ko 加载不了 |
| `rootfs_run_id` | 可选。填某次成功运行的 run id，则**跳过 rootfs 编译、只重跑封装**（约 8 分钟，用于快速调试封装环节） |

编译产物：Actions 运行页面底部的 Artifacts → `hk1box-immortalwrt-oaf`（里面是 `.img`）。

---

## 二、为什么是"两段式"编译

ImmortalWrt / OpenWrt 官方**没有 amlogic 目标**，不能直接编出盒子能刷的镜像。所以：

1. **第一段**：按 `armsr/armv8` 目标编一个 rootfs（rootfs.tar.gz），所有软件包都在这里进来；
2. **第二段**：用 [ophub/amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt) 把 rootfs 塞进一份带 **Amlogic 专用内核 + u-boot** 的磁盘镜像里，板子选 `s905x3-hk1`。

内核用的是 ophub 的 `kernel_stable/5.15.222`（`5.15.222-ophub`），不是我们编的。

---

## 三、⚠️ 四个必须知道的坑（都已在本仓库里修好）

### 坑 1：`appfilter` 同名包被遮蔽
IMM 自带的 `net/open-app-filter` 和 `wshcxl/Open-App` 的 `open-app-filter` **都定义名为 `appfilter` 的包**。
`./scripts/feeds install -a` 按包名去重、且 `packages` 源排在 `oaf` 源前面 → 我们的 `appfilter` 被跳过，
编到 LuCI 时报 `cannot find dependency appfilter for luci-app-oaf`。

👉 修法见 `fix-oaf.sh`：删掉 IMM 的链接，手工把 Open-App 的 `open-app-filter` 链进编译树；
同时给 `oaf` 内核模块补上缺失的 `Build/Prepare`。

### 坑 2：封装会把 `/lib/modules` 全删掉 → oaf.ko 丢失
ophub 的 `remake` 流程是：
```
解开 rootfs  →  rm -rf /lib/modules/*  →  解入 ophub 内核自带的 modules-*.tar.gz
```
也就是说**我们自己编的 `oaf.ko` 会被丢掉**，而 OAF 的用户态程序开机是 `modprobe oaf`，
模块没了 OAF 就等于废掉。

👉 修法见 `inject-oaf.sh`（在调用 ophub action 之前运行）：
1. 下载 ophub 对应版本的内核包（内含编译该内核时的 **header 树**：`.config` / `Module.symvers` / `include/generated`）；
2. 用这棵 header 树**对着 ophub 内核交叉编译 `oaf.ko`**（vermagic 天然一致）；
3. 校验 vermagic，不一致就原地改写 `.modinfo` 里的字符串并复核；
4. 把 `oaf.ko` 注入模块树 → `depmod` 重建 `modules.dep` → 重新打包 `modules-*.tar.gz` 并刷新 `sha256sums`（放哪个目录有讲究，见坑 4）；
5. 把内核包放到 `<action>/make-openwrt/kernel/<tag>/<version>/`，`remake` 见目录已存在就跳过下载；
6. 顺手给 `appfilter` 启动脚本加一行兜底：`modprobe oaf` 失败就 `insmod /lib/modules/$(uname -r)/oaf.ko`。

### 坑 3：`cp --update=none` 需要 coreutils ≥ 9.3
ophub 的 `remake` 用了 `cp -af --update=none`，在 `ubuntu-22.04`（coreutils 8.32）上直接报
`cp: option '--update' doesn't allow an argument` → `OpenWrt: platform-files download failed.`

👉 修法：封装 job 用 `ubuntu-24.04`（coreutils 9.4，ophub 官方 CI 也是这个），
另外脚本里还有一步把 `--update=none` 降级成等价的 `-n` 作兜底。

### 坑 4：模块目录顶层**恰好只能有 1 个子目录**
ophub 的 `remake` 里有这么一条硬检查（就在解完模块包、做完软链之后）：
```sh
[[ "$(ls ${rootfs}/lib/modules/${kernel_name} -l | grep "^d" | wc -l)" -eq "1" ]] || error_msg "/usr/lib/modules kernel folder is missing."
```
`ls -l | grep "^d"` 数的是**顶层子目录个数**，要求**正好等于 1**（ophub 自己的包就是 `kernel/` 这一个，
2089 个 `.ko` 全在 `kernel/` 底下）。所以文档里常见的"外部模块放 `extra/`"那种写法**在 ophub 这里会翻车**：
多出一个顶层目录 → 封装在 `(3/6) Replacing kernel files` 直接报
`[💔] /usr/lib/modules kernel folder is missing.`

👉 修法：`oaf.ko` 放进**已有的那个顶层目录**里，也就是 `lib/modules/5.15.222-ophub/kernel/oaf.ko`；
`remake` 后面那句 `find ./ -type f -name '*.ko' -exec ln -s {} ./ \;` 会照样在顶层给它做好
`oaf.ko -> ./kernel/oaf.ko` 软链，`modprobe oaf` / `insmod .../oaf.ko` 都能用。
`inject-oaf.sh` 里现在还会在重打包后**硬校验顶层目录数 = 1**，不满足就当场失败，
不会白等二十分钟才在 ophub 那步报错。

> 另一个坑中坑：`inject-oaf.sh` 的 header 树是从 ophub 内核包里解出来的，里面有**别的机器编好的宿主工具**
> （`scripts/basic/fixdep`、`scripts/mod/modpost` 等 13 个 ELF），在别的 runner 上跑会 `Exec format error`(126)
> 或 `not found`(127)。脚本里会先把这些 ELF 删掉让本机 gcc 重编；同时 header 包**没有 Kconfig 树、也没有 `.config`**，
> 所以 `syncconfig` 必须跳过、配置从 `include/config/auto.conf` 读。

---

## 四、刷机

产物是 `openwrt_amlogic_s905x3-hk1_k5.15.222_<日期>.img.gz`（约 300 MB，解开 ~2.4 GB；`hk1-upload` 那版会带 WiFi 用户态）。

1. 下载 Artifacts 里的 `.img.gz`（Etcher 能直接吃 `.gz`，不用手动解压；想手动解就用 7-Zip）；
2. 用 [balenaEtcher](https://etcher.balena.io/) 或 Rufus 写 **SD 卡 / U 盘**（HK1 Box 优先从 SD 启动；要写 eMMC 得拆机短接或用盒子里的现有系统）；
3. 插卡上电，首次启动约 1~3 分钟（会自动扩容 rootfs）；
4. 网线接盒子网口，浏览器打开 **http://192.168.1.96**。

> 盒子当**旁路由**用（推荐，省事）：网线把盒子接到主路由/交换机，然后家里的设备把网关/DNS 指向
> `192.168.1.96`，全家流量就会经过盒子，OAF 才能认应用、限速、看记录；
> 只想先看后台的话不用改网关，但 OAF 会是空的。

> 每次封装结束，CI 都会把镜像 `gunzip` 出来挂载一遍、逐文件确认
> `/lib/modules/5.15.222-ophub/kernel/oaf.ko`、顶层软链 `oaf.ko -> ./kernel/oaf.ko`、
> `modules.dep` 里的 oaf 条目、以及 `/etc/init.d/appfilter` 的 insmod 兜底都在，
> 缺任何一样就直接把这次运行判红，不会出现"打包成功其实 OAF 是死的"。

---

## 五、刷完怎么确认 OAF 真的能用

SSH 登录后：

```sh
# 1. 内核模块在不在、加载没有
uname -r                       # 应为 5.15.222-ophub
ls -l /lib/modules/$(uname -r)/oaf.ko            # 顶层软链（ophub 封装时做的）
ls -l /lib/modules/$(uname -r)/kernel/oaf.ko     # 真实文件
lsmod | grep oaf
dmesg | grep -i oaf

# 2. 模块依赖索引里有没有 oaf（modprobe 靠它）
grep oaf /lib/modules/$(uname -r)/modules.dep

# 3. 服务有没有跑起来
/etc/init.d/appfilter status   # 或
ps | grep -E 'oafd|rule_manager'
logread | tail -50

# 4. LuCI 里确认
#    菜单应出现 OAF 相关页面（应用过滤 / 用户管理 / 上网记录等）
```

如果 `lsmod | grep oaf` 有输出、LuCI 里 OAF 页面能打开并显示设备列表，就算成功。

**常见问题**

| 现象 | 原因 / 处理 |
| --- | --- |
| `insmod: invalid module format` | oaf.ko 与内核 vermagic 不匹配 → 说明封装时注入的内核版本和 `kernel` 输入不一致，用同一个版本重编 |
| LuCI 有 OAF 菜单但功能报错 | 多半是 `oaf.ko` 没加载，先看 `lsmod | grep oaf` |
| OAF 看不到任何流量 | OAF 需要关掉硬件 NAT，`hnat.sh` 会在服务启动时自动处理；确认 `/etc/config/fwxd` 里 `disable_hnat` 为 `0` |

---

## 六、仓库文件说明

| 文件 | 作用 |
| --- | --- |
| `.github/workflows/build-openwrt.yml` | 主流程：编译 rootfs + ophub 封装 |
| `.config` | ImmortalWrt 配置（要加/减软件包改这里） |
| `diy-part1.sh` | 编译前：把 `wshcxl/Open-App` 作为 `oaf` feed 加进去 |
| `diy-part2.sh` | 编译前：改默认 IP、按需设默认中文 |
| `fix-oaf.sh` | 编译前：解决 appfilter 同名遮蔽 + 补 oaf 内核模块的 Build/Prepare（坑 1） |
| `inject-oaf.sh` | 封装前：对着 ophub 内核重编 oaf.ko 并注入 + 修启动脚本（坑 2） |

---

## 七、注意

- 本仓库用到的 GitHub Token 只是临时的，用完请到 GitHub → Settings → Developer settings → Personal access tokens 撤销。
- 内核版本与 oaf.ko 是**绑定**的：改 `kernel` 输入必须让 `inject-oaf.sh` 用同一个版本重新编译，否则模块加载不了。

---

<sub>本仓库骨架来自 [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt) 模板；封装流程来自 [ophub/amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt)。</sub>
