# HK1 Box (Amlogic S905X3) ImmortalWrt + OAF 固件

自动编译适合 **HK1 Box / Vontar X3** 刷入的 ImmortalWrt 固件，内置：

- **OAF（OpenAppFilter）**：应用识别 + 家长控制/上网监控（`oaf.ko` + `appfilter`(oafd) + `luci-app-oaf`）
- **Docker**：`docker` / `dockerd` / `luci-app-dockerman`
- **流量监控**：`nlbwmon` + LuCI 界面
- **WiFi**：brcm4339 SDIO 无线网卡用户态（`wpad-mbedtls`）
- 常用工具：curl、nano、htop、bash、fdisk、e2fsprogs、iperf3、tcpdump、samba4、ttyd、upnp

默认管理地址：**192.168.50.101**（无密码，首次登录请立刻设置）

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

## 三、⚠️ 三个必须知道的坑（都已在本仓库里修好）

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
4. 把 `oaf.ko` 注入模块树 → `depmod` 重建 `modules.dep` → 重新打包 `modules-*.tar.gz` 并刷新 `sha256sums`；
5. 把内核包放到 `<action>/make-openwrt/kernel/<tag>/<version>/`，`remake` 见目录已存在就跳过下载；
6. 顺手给 `appfilter` 启动脚本加一行兜底：`modprobe oaf` 失败就 `insmod /lib/modules/$(uname -r)/oaf.ko`。

### 坑 3：`cp --update=none` 需要 coreutils ≥ 9.3
ophub 的 `remake` 用了 `cp -af --update=none`，在 `ubuntu-22.04`（coreutils 8.32）上直接报
`cp: option '--update' doesn't allow an argument` → `OpenWrt: platform-files download failed.`

👉 修法：封装 job 用 `ubuntu-24.04`（coreutils 9.4，ophub 官方 CI 也是这个），
另外脚本里还有一步把 `--update=none` 降级成等价的 `-n` 作兜底。

---

## 四、刷机

1. 下载 Artifacts 里的 `.img`；
2. 用 [balenaEtcher](https://etcher.balena.io/) 或 Rufus 写 **SD 卡 / U 盘**（HK1 Box 优先从 SD 启动；要写 eMMC 得拆机短接或用盒子里的现有系统）；
3. 插卡上电，首次启动约 1~3 分钟（会自动扩容 rootfs）；
4. 网线接盒子网口，浏览器打开 **http://192.168.50.101**。

---

## 五、刷完怎么确认 OAF 真的能用

SSH 登录后：

```sh
# 1. 内核模块在不在、加载没有
uname -r                       # 应为 5.15.222-ophub
ls -l /lib/modules/$(uname -r)/oaf.ko
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
