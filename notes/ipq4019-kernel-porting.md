# IPQ4019（WAP8150DN）内核 / U-Boot 移植笔记

> 维护规则：每次咨询后把新增知识点补进对应章节，并在文末「咨询记录」追加一条。
> 不在笔记中保存明文密码/密钥；调试脚本统一放 `D:\TMP\opencode`。
> **推送策略（2026-11-25 用户要求）：后续咨询只更新本地笔记，暂不推送 GitHub；等用户明确通知后一次性推送。**
> **执行策略（2026-11-25 用户要求）：后续移植操作全部由用户自己执行，我只负责讲解思路、给出命令、判读用户贴回的输出，不再代为在编译机/设备上执行。**
> 本文已把早期被实测推翻的推断更正并合并（保留必要的历史说明），以「最终结论」为准。

---

## 0. 目标与当前状态

**目标**：把该设备的厂商内核（Linux 4.4.60）升级/移植到新内核，并理解整条启动链；保留启动、Flash 布局、WiFi 校准和 overlay 机制。

**当前状态（2026-11-24）**：

- 已完成设备识别、Flash 布局、启动链、cmdline、sysupgrade 机制、完整启动日志分析。
- 已用**全新主线 U-Boot 2026.10** 完成板级移植，并通过 **RAM 链加载**验证：
  - 串口、DRAM、DTS、时钟/pinctrl 正常；
  - **64 MiB SPI NOR** 识别正常（`mx66l51235l`）；
  - 能读取 mtd8 的 FIT 并 `bootm` 启动原厂 Linux 4.4.60 进入系统；
  - 网络开机自动 link up，TFTP 可用；`reset` 正常；
  - 镜像无调试打印。
- **全程没有写 flash**：厂商 APPSBL（U-Boot）、MIBIB、ART 全部保持原样。

---

## 1. 设备概览

| 项目 | 值 |
|---|---|
| 主机名 | `WAP8150DN` |
| SoC | Qualcomm IPQ4019（4×Cortex-A7，ARMv7l，SMP） |
| DT model | `Qualcomm Technologies, Inc. IPQ4019/AP-DK04.1-C1` |
| 内核 | `Linux 4.4.60 #1 SMP PREEMPT`，gcc 4.8.3 (Linaro 2014.04) |
| 内存 | 256 MiB DDR |
| Flash | **64 MiB SPI NOR**（Macronix；U-Boot 表 `MX25L51245G`，Linux m25p80 表 `mx66l51235l`；早期推断的 32 MiB / W25Q256 已被推翻） |
| 用户态 | OpenWrt 风格：squashfs 根 + JFFS2 overlay，BusyBox 1.25.1，nginx |
| 固件基线 | OpenWrt Chaos Calmer 15.05.1，`DISTRIB_TARGET=ipq806x/generic`，rev `b5ee05b+r49254` |
| 用户态 libc | uClibc-ng 1.0.14（NPTL），**soft-float ABI**（EABI5，`e_flags=0x05000200`） |
| 构建工具链 | Linaro GCC 4.8.3（`Linux/Linaro GCC 4.8-2014.04 Release2025Q3+r49254`） |
| 原厂 Bootloader | U-Boot 2012.07（CC 15.05.1，`4cb049f+r49254`，2021-01-14），`bootcmd=bootipq` |
| 内核 cmdline | `rootfsname=rootfs rootwait clk_ignore_unused` |
| 设备访问 | `root@172.18.0.136`（密码不入库） |
| 编译机 | `xuhj@10.10.10.135`（Ubuntu 20.04，x86_64） |

设备侧工具很少：无 `mtd_debug`/`flash_erase`/`mtdinfo`/`od`；有 `devmem`、`hexdump`、`fw_printenv`、`ubinfo`。

---

## 2. Flash、分区与启动链

### 2.1 Flash 芯片与驱动

| 项目 | 最终结论 |
|---|---|
| 类型 | SPI NOR，`spi0.0` @ `78b5000.spi` |
| 容量 | **64 MiB（0x0400_0000）** |
| 芯片 | Macronix 512 Mbit：U-Boot ID 表叫 `MX25L51245G`，Linux m25p80 叫 `mx66l51235l` |
| 页/sector | U-Boot 硬件视角：page 256 B、sector 4 KiB；Linux `/proc/mtd` erasesize 64 KiB（DTS/驱动口径） |
| Linux 驱动 | `m25p80`（`drivers/mtd/devices/m25p80.c`），靠 JEDEC ID 匹配；日志：`found mx66l51235l, expected n25q128a11` |
| U-Boot 驱动 | 独立的 `sf` 框架（`spi_flash.c` + ID 表 + QUP SPI 控制器），与 Linux m25p80 是两套实现 |
| DTS compatible | `n25q128a11`（Micron 16 MiB）是错误匹配串，实际芯片由 JEDEC ID 决定 |

**重要纠正历史**：早期根据同类板日志 `w25q256 (32768 Kbytes)` 推断为 32 MiB Winbond；后来完整 U-Boot 日志明确打印 `SF: Detected MX25L51245G ... total 64 MiB`、`ipq_spi ... size: 0x4000000`，Linux 也打印 `mx66l51235l (65536 Kbytes)`，故以 **64 MiB** 为准。

`/sys/bus/spi/drivers` 下有 `m25p80`、`mt29f`、`spidev` 三个已注册驱动，但目录存在 ≠ 有设备绑定：

- `m25p80`：本板 Flash 实际绑定者；
- `mt29f`：美光 SPI NAND 驱动，厂商内核通用编译进来，**本机无 NAND**；
- `spidev`：用户态 SPI 驱动，本机未声明设备节点，不能用来读 RDID。

确认方法：`readlink /sys/bus/spi/devices/spi0.0/driver` 应指向 `m25p80`；`dmesg | grep -i -E 'm25p|spi|nor|flash'` 可看探测日志。

### 2.2 分区表（物理偏移）

| MTD | 名称 | 起始 | 大小 | 结束 | 用途 |
|---|---|---|---|---|---|
| mtd0 | `0:SBL1` | `0x0000_0000` | 256 KiB | `0x0004_0000` | 二级引导加载器 |
| mtd1 | `0:MIBIB` | `0x0004_0000` | 128 KiB | `0x0006_0000` | 分区表（magic `0x55EE73AA`，11 项） |
| mtd2 | `0:QSEE` | `0x0006_0000` | 384 KiB | `0x000C_0000` | 安全执行环境（TZ） |
| mtd3 | `0:CDT` | `0x000C_0000` | 64 KiB | `0x000D_0000` | 板级配置表（`CDT\0`） |
| mtd4 | `0:DDRPARAMS` | `0x000D_0000` | 64 KiB | `0x000E_0000` | DDR 训练参数 |
| mtd5 | `0:APPSBLENV` | `0x000E_0000` | 64 KiB | `0x000F_0000` | U-Boot 环境变量 |
| mtd6 | `0:APPSBL` | `0x000F_0000` | 512 KiB | `0x0017_0000` | U-Boot 本体 |
| mtd7 | `0:ART` | `0x0017_0000` | 64 KiB | `0x0018_0000` | WiFi 校准/ART、MAC |
| mtd8 | `0:HLOS` | `0x0018_0000` | 4 MiB | `0x0058_0000` | FIT 镜像（kernel+DTB） |
| mtd9 | `rootfs` | `0x0058_0000` | 22 MiB | `0x01B8_0000` | squashfs 根文件系统 |
| mtd10 | `rootfs_data` | `0x016D_0000` | 4.6875 MiB | `0x01B8_0000` | JFFS2 overlay（与 rootfs 尾部重叠） |
| mtd11 | `mib0` | `0x01B8_0000` | 64 KiB | `0x01B9_0000` | MIB 数据，当前全 `0xFF` |

- 已分区到 `0x1B9_0000` = **27.5625 MiB**；64 MiB 芯片尾部 `0x1B9_0000–0x400_0000` 共 **36.4375 MiB 未分区**。
- 分区只覆盖前 27.56 MiB；不要据此认为 Flash 只有 32 MiB。

### 2.3 MIBIB 分区表格式

`/dev/mtd1` 偏移 `0x100` 起：

```
header (16B):
  magic   = 0x55EE73AA ("aa 73 ee 55")
  version = 0xE35EBDDB
  field   = 0x00000004
  count   = 0x0000000B  (11 项)

entry (28B = 0x1C):
  char name[16]
  u32  offset   // 单位 64 KiB
  u32  size     // 单位 64 KiB
  u32  flags    // 0x0000FFFF
```

- 11 项依次为：`0:SBL1`、`0:MIBIB`、`0:QSEE`、`0:CDT`、`0:DDRPARAMS`、`0:APPSBLENV`、`0:APPSBL`、`0:ART`、`0:HLOS`、`rootfs`、`mib0`。
- **MIBIB 里没有 `rootfs_data`**，它是内核 mtdsplit 根据 squashfs 实际大小动态拆出来的。
- MIBIB 的 offset/size 与 DTS `reg` 一致。

### 2.4 rootfs 内部拆分（overlay 关键）

```
0x0058_0000  ┌────────────────────────────┐
             │ squashfs                   │ bytes_used = 0x0114_3C70 ≈ 17.27 MiB
0x016C_4000  │ 结束标记 DE AD C0 DE        │
0x016D_0000  ├────────────────────────────┤ ← squashfs 后第一个 64K 边界
             │ rootfs_data (JFFS2)        │ 0x4B_0000 = 4.6875 MiB
0x01B8_0000  └────────────────────────────┘
```

- 拆分点 `0x016D_0000` 已用 JFFS2 cleanmarker 验证。
- `mtd9 rootfs` 与 `mtd10 rootfs_data` **地址重叠**，分区大小不能直接相加。
- 新 rootfs 的 squashfs 必须结束在 `0x16D0000` 之前，否则 overlay 偏移错位。
- squashfs 是 XZ 压缩；overlay 是 JFFS2 + LZMA。

### 2.5 空间占用（按 64 MiB 芯片）

| 区域 | 大小 | 占比 |
|---|---|---|
| 启动链（SBL1→ART） | 1.5 MiB | 2.3% |
| HLOS（FIT 内核） | 4 MiB | 6.25% |
| rootfs squashfs | 17.3125 MiB | 27.1% |
| rootfs_data（overlay） | 4.6875 MiB | 7.3% |
| mib0 | 64 KiB | 0.1% |
| 已分区小计 | 27.5625 MiB | 43.1% |
| **未分配尾部** | **36.4375 MiB** | **56.9%** |

尾部空间理论上可扩大 HLOS/rootfs，但改 MIBIB + DTS + U-Boot 写死偏移风险很高，不建议。

### 2.6 启动链与信任根

```
PBL（片内 Boot ROM，不可改）
  → SBL1（mtd0，读 MIBIB/CDT/DDRPARAMS 初始化 DDR）
  → QSEE / TZ（mtd2）
  → APPSBL / U-Boot（mtd6，bootcmd=bootipq）
  → HLOS FIT（mtd8）
  → squashfs rootfs（mtd9）
  → rootfs_data overlay（mtd10）
  → init / procd / WiFi 等业务
```

- **PBL vs SBL1**：PBL 是 IPQ4019 片内 mask ROM，是信任根，不可擦写；`mtd0 "0:SBL1"` 是 Flash 中可写的第一阶段 bootloader，口头常被误称为 bootrom。
- PBL 按启动配置（本机 `Boot Config 0x21`）选定 SPI NOR，把 SBL1 搬到片内 SRAM，按 QFPROM 熔丝验签（若安全启动使能）后跳转。
- **SBL1 只从 PBL 选定的启动介质（本机 SPI NOR）加载后续镜像**：它读同一 Flash 上的 MIBIB，找到 `0:APPSBL`（`0xF0000`，512 KiB），把 U-Boot 搬到 DDR 的 `0x87300000` 后跳转。不会从 USB/网口/eMMC 另找 U-Boot；要换启动介质必须整条链一起换。
- 网络/USB 加载 U-Boot 只能发生在已有代码运行之后（如 RAM 链加载），属于上层手段，不是 SBL 的能力。
- 防回滚 `Version Rollback Feature Disabled` 只说明防回滚关闭，不能证明 APPSBL 验签关闭；PBL 日志有 `auth_hash_seg`/`elf_segs_hash_verify`，至少 SBL1 被校验。

**完整启动日志时间线（实测）**：

- PBL @261 µs → @696197 µs（~696 ms，主要耗在校验 SBL1）；
- SBL1 @696222 µs → @1354987 µs（加载 QSEE 299560 B、SEC 2048 B、APPSBL 424503 B，DDR 672 MHz，Flash 吞吐 ~2008 KB/s）；
- U-Boot 从 `0x84000000` 启动 FIT，kernel load/entry `0x80208000`，DTB 放 `0x86FF7000`；
- Linux 挂 rootfs @2.539 s，`mount_root` 切 overlay @10.49 s，procd init @12.35 s，WiFi0/WiFi1 attach @31/34 s。

### 2.7 HLOS / FIT 与 bootipq

- 原厂 U-Boot `bootcmd=bootipq`，逻辑为：
  ```sh
  sf probe && sf read <addr> 0x180000 <size> && bootm <addr>#config@ap.dk04.1-c1
  ```
  它只读物理偏移，不认识 `0:HLOS` 这个名字。
- 当前 mtd8 FIT：magic `d0 0d fe ed`，totalsize `0x3d74c0` = 4,028,608 B（3.84 MiB），分区 4 MiB，剩约 162 KiB。
- `dumpimage -l`：
  - `kernel@1`：gzip，3,717,583 B，load=entry=`0x80208000`，crc32+sha1；
  - 14 个 FDT（18–28 KiB，共约 296 KiB）和 14 个 config；本板用 `fdt@ap.dk04.1-c1` / `config@ap.dk04.1-c1`；
  - FDT 带 `dload_type@18 { qcom,msm-imem-dload-type; }` 和 `bootargs-append="clk_ignore_unused"`。
- cmdline 实际：`rootfsname=rootfs rootwait clk_ignore_unused`（`rootfsname=` 是 OpenWrt 补丁，主线内核不认，要用 `root=/dev/mtdblock9 rootfstype=squashfs`）。
- **FIT 为什么小**：kernel gzip 后 3.55 MiB（未压缩约 7.6 MB，压缩比 ~2.1:1）；DTB 只是数据；273 个 `.ko` 在 rootfs 不在 FIT；生产 FIT 无 initramfs；32 位 ARM 精简配置。
- `HLOS` = High-Level Operating System，高通对 Normal World 非安全 OS（Linux/Rich OS）的称呼，与 Secure World 的 QSEE/TZ 相对。

### 2.8 完整固件升级（sysupgrade / platform.sh）

- 厂商 `sysupgrade` 接受**外层 FIT**（“FIT 套 FIT”）：
  - `hlos` 段 = mtd8 里的内层 FIT（逐字节相同）→ 写 mtd8；
  - `fs` / `rootfs` 段 = rootfs 镜像 → 写 mtd9（带 `-j $CONF_TAR` 时把配置集成进尾部 JFFS2）。
- `/lib/upgrade/platform.sh` 流程：
  ```
  sysupgrade <itb>
    ├─ platform_check_image: image_is_FIT → mandatory 段检查 → ddr 一致性
    │    → optional/ignored 告警 → image_demux（解包到 /tmp）→ dumpimage -c
    ├─ 保存配置 /tmp/sysupgrade.tgz；-T 到此退出
    ├─ ubus call system upgrade → kill_remaining → run_ramfs
    └─ platform_do_upgrade
         ├─ 镜像与 /tmp/<sec>.bin 存在性检查（缺失直接 reboot）
         ├─ for sec in $(print_sections): flash_section（段名前缀映射）
         ├─ switch_layout linux
         ├─ do_flash_bootconfig（来自 /proc/boot_info，不来自镜像）
         ├─ platform_version_upgrade（写 QFPROM）
         └─ erase_emmc_config
  ```
- `flash_section` 主要映射：`hlos*`→`0:HLOS`；`rootfs*`/`fs*`→`rootfs`；`sbl1*`→`0:SBL1`；`u-boot*`→`0:APPSBL`；`tz*`→QSEE；`mibib*`→`0:MIBIB`；未知段忽略。
- 关键细节：
  - `print_sections` 依赖 GNU awk 的 `gensub`（busybox awk 没有）；
  - mandatory 检查是 OR 且不判设备类型；`mibib`/`bootconfig` 被告警忽略；`sb11` 是拼写错误；
  - `do_flash_mtd` 用 `dd ... bs=$writesize conv=sync | mtd $append -e ... write - ...`；
  - 无段大小/分区大小校验，超长镜像会先擦后写失败；
  - `platform_version_upgrade` 写 QFPROM，自制镜像应避免 `*_version` 段。
- **结论**：保留 SBL1/MIBIB/QSEE/APPSBL/ART，只替换 `hlos` + `fs` 即完成一次完整固件升级，不需要动 bootloader。

---

## 3. RAM / 地址空间布局（厂商 4.4 内核）

### 3.1 物理内存

| 物理地址 | 大小 | 用途 |
|---|---|---|
| `0x8000_0000 – 0x8FFF_FFFF` | 256 MiB | DDR |
| `0x87B0_0000 – 0x87FF_FFFF` | 5 MiB | DT `reserved-memory/rsvd1`，`no-map` |
| `0x8000_0000 – 0x87AF_FFFF` | 123 MiB | memblock 可用区 1 |
| `0x8800_0000 – 0x8FFF_FFFF` | 128 MiB | memblock 可用区 2 |

memblock 保留约 10.1 MiB：

- `0x8020_4000 – 0x8099_C7DB`：内核镜像（约 7.6 MB）
- `0x86FF_7000 – 0x86FF_F867`：约 34 KiB
- `0x8FD4_6000 – 0x8FEC_FFFF`：约 1.5 MiB
- `0x8FED_9000 – 0x8FFF_BFFF`：约 1.1 MiB
- `0x8FFF_C040 – 0x8FFF_FFFF`：约 16 KiB

```
MemTotal = 246684 KiB (240.9 MiB)
         = 256 MiB - 5 MiB (no-map) - 10.1 MiB (memblock reserved)
```

### 3.2 虚拟地址空间（`CONFIG_VMSPLIT_3G=y`）

| 虚拟地址 | 大小 | 用途 |
|---|---|---|
| `0x0000_0000 – 0xBF00_0000` | 3 GiB−16 MiB | 用户空间 |
| `0xBF00_0000 – 0xBFE0_0000` | 14 MiB | 模块区（262 个模块占 8.7 MiB） |
| `0xBFE0_0000 – 0xC000_0000` | 2 MiB | pkmap |
| `0xC000_0000 – 0xD000_0000` | 256 MiB | 低端直接映射（`_stext=0xC0208280`） |
| `0xD080_0000 – 0xFF80_0000` | 752 MiB | vmalloc 区 |
| `0xFEE0_0000 – 0xFF00_0000` | 2 MiB | PCI IO ioremap |
| `0xFF7D_0000 – 0xFF80_0000` | 192 KiB | per-CPU 区 |
| `0xFFFF_0000` | — | 异常向量页 |

早期把模块区记成 16 MiB 不够精确：实测是 **14 MiB 模块区 + 2 MiB pkmap**。

### 3.3 运行时占用与碎片化

```
MemFree       80.6 MiB
MemAvailable 132.8 MiB
Slab          58.0 MiB（SUnreclaim 52.7 MiB）
Buffers       22.0 MiB
Cached        33.6 MiB
vmalloc RAM   ~27.4 MiB
进程 RSS      37.5 MiB / 136 进程
```

- vmalloc 主要来自 `load_module` 10.7 MiB、`devm_ioremap` 10.3 MiB、`__wifi_cmem_allocation` 6.5 MiB 等。
- buddyinfo：空闲页 ~20.6k，大部分在 17 个 order-10 块；**order-0 仅 99 页（~396 KB）**。
- `CONFIG_COMPACTION=n`、`CONFIG_SWAP=n`、`CONFIG_HIGHMEM=y`（实际未用）、`CONFIG_SLUB=y`。

---

## 4. 编译工具链与 ABI

### 4.1 实测 ABI 结论

| 项目 | 实测值 | 工具链要求 |
|---|---|---|
| 架构 | `armv7l`，CPU part `0xc07`（Cortex-A7） | `-march=armv7-a -mtune=cortex-a7` |
| FPU | VFPv3/VFPv4/NEON | `-mfpu=neon-vfpv4` |
| EABI | 小端，EABI5，`e_flags=0x05000200` | `arm-linux-gnueabi`（不是 `gnueabihf`） |
| 浮点 ABI | soft-float | 动态链接必须与 soft-float 库配套 |
| libc | uClibc-ng 1.0.14（NPTL） | 复用原 rootfs 时不能换 musl/glibc |
| 内核 | 4.4.60，AEABI，非 LPAE，4K 页 | 新内核保持 AEABI/非 LPAE/4K 页 |
| 模块 | 273 个 `.ko`，`MODULE_STRIPPED=y` | 换内核必须全部重编/移植 |

判定：`readelf -h /bin/busybox | grep Flags`，`0x5000200`=soft-float，`0x5000400`=hard-float。

### 4.2 场景与推荐工具链

| 场景 | 推荐工具链 |
|---|---|
| 复现/维护厂商 4.4.60 | OpenWrt CC 15.05.1 SDK 的 `arm-openwrt-linux-uclibcgnueabi-`（GCC 4.8.3）或 QSDK 工具链 |
| 移植新内核、保留原 rootfs | `arm-linux-gnueabi-` GCC 12/13（soft-float） |
| 全新 OpenWrt 固件 | 当前 OpenWrt SDK（`ipq40xx`，`arm_cortex-a7_neon-vfpv4`，musl），整包替换 |
| 只做 initramfs bring-up | 任意现代 `arm-linux-gnueabi-` |

### 4.3 编译 zImage / DTB

```sh
sudo apt install gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
    build-essential flex bison bc libssl-dev libelf-dev pahole \
    u-boot-tools device-tree-compiler

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- multi_v7_defconfig
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- -j$(nproc) zImage dtbs
```

- `arm-linux-gnueabi-gcc` 是交叉工具链的 C 编译器驱动，`-dumpmachine` 应输出 `arm-linux-gnueabi`。
- **DTB 由主机 `dtc` 生成**，不是交叉编译器产物；`CROSS_COMPILE` 对 dtb 无影响。
- `make zImage dtbs` 只产出内核和 DTB，**不会编译 U-Boot**；U-Boot 是独立项目。

### 4.4 高版本内核源码选择

- **首选 Linux 6.12 LTS**：
  ```sh
  git clone --depth 1 -b linux-6.12.y \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.12
  ```
- **更贴近本板**：OpenWrt ipq40xx 内核树（`make target/linux/prepare V=s`），已带 mtdsplit/rootfsname/IPQ40xx 补丁；但 WiFi 是 ath10k/ath11k 而非厂商 `qca_ol`。
- **主线支持**：`multi_v7_defconfig` 含 `CONFIG_ARCH_IPQ40XX`；DTS 在 `arch/arm/boot/dts/qcom/qcom-ipq4019*.dts*`（Linux 6.12 已有本板完整 DTS）。但分区需按本板 MIBIB 调整，rootfs_data 固定在 `0x16D0000`。
- 必开配置：`CONFIG_SQUASHFS_XZ`、`CONFIG_JFFS2_LZMA`、`CONFIG_OVERLAY_FS`、`CONFIG_MTD_BLOCK`、`CONFIG_MTD_OF_PARTS`、`CONFIG_MTD_SPI_NOR`/`m25p80`、`CONFIG_SPI_QUP`、`CONFIG_SERIAL_MSM`、`CONFIG_ARM_UNWIND`；不要 LPAE。
- 用 `multi_v7_defconfig` 起步是因为主线没有本板专用 defconfig；先用它保证基础驱动齐全，再 menuconfig 裁剪并 `savedefconfig`。

---

## 5. 驱动 / 软件栈（移植难点）

- QCA NSS 网络加速：`qca_nss_drv`(570KB)、`qca_nss_gmac`、`qca_nss_*`、`ecm`(957KB)、`shortcut-fe`、`qca_mcs`
- 交换芯片：`qca_ssdk`(2MB)、`qca_85xx_sw`
- WiFi：`qca_ol`(1.09MB)、`umac`(1.65MB)、`ath_dfs`、`ath_spectral`、`qca_nss_cfi_ocf`、`mem_manager`
- 加密：`qcrypto`、`qca_nss_crypto`、`cryptodev`
- 共 **273 个 `.ko`**（运行加载 262 个）/ 8.7 MiB，模块区 14 MiB 已用一半多。
- 启动日志确认：`qca_ol`/`umac` 厂商 WiFi（`athwlan.bin` + `boardData_1_0_IPQ4019_DK04_{2G,5G}.bin`，Firmware build 83），非 ath10k；`qca-ssdk` 成功但 `nss is not enabled on this platform`（NSS 卸载未启用）。
- preinit 中两次 12064 字节 dd 是从 ART 提取校准到 `/tmp/wifi0.caldata` / `wifi1.caldata`。
- 这些 out-of-tree 厂商驱动是移植到新内核的最大工作量；主线要换 `ath10k`，NSS 加速需另找方案。

---

## 6. 主线 U-Boot 2026.10 板级移植（完整记录）

### 6.1 策略与安全边界

- 不从网上拉现成 U-Boot 二进制刷 mtd6（板级强相关，且可能有验签）。
- 用**最新主线 U-Boot** 做基线，补板级 defconfig/DTS/驱动补丁；通过 **RAM 链加载**验证，不写 flash。
- **绝对不要动**：mtd0 SBL1、mtd1 MIBIB、mtd2 QSEE、mtd3 CDT、mtd4 DDRPARAMS、mtd6 APPSBL、mtd7 ART（WiFi 校准/MAC）。
- **谨慎可动**：mtd5 APPSBLENV（U-Boot 环境变量）。
- **可自由折腾但有约束**：mtd8 FIT、mtd9/10 rootfs；升级走厂商 sysupgrade 的 `hlos`/`fs` 段。
- 未确认 EDL/编程器可用之前，**不要写 mtd6**。备份只是必要条件，不是恢复手段。

### 6.2 源码、工具链与关键符号

- 源码：主线 U-Boot（`https://github.com/u-boot/u-boot`），版本 **2026.10**。
- 工具链：系统 `arm-linux-gnueabi-gcc` 是 7.3，主线 U-Boot 要求 ≥10；改用 **Arm GNU Toolchain 13.2.Rel1**（`arm-none-linux-gnueabihf-`，硬浮点，仅用于 U-Boot，不链接用户态库）。
- 主线现状：`configs/` 只有 `qcom_defconfig`（`CONFIG_ARCH_SNAPDRAGON=y`）及 ipq5424/ipq9574 等，没有 IPQ4019/AP-DK04 defconfig；但 `arch/arm/mach-ipq40xx/`、`ARCH_IPQ40XX`、`qcom-ipq4019-u-boot.dtsi`、MSM 串口/smem/essedma 驱动都存在。属于“有 SoC 层、无 board 层”。
- 关键 Kconfig 符号：`CONFIG_SPI_QUP`、`CONFIG_MSM_SERIAL` / `CONFIG_DEBUG_UART_MSM`、`CONFIG_ESSEDMA`、`CONFIG_MDIO_IPQ4019`、`CONFIG_CMD_SF`、`CONFIG_FIT` / `CONFIG_CMD_BOOTM`。

### 6.3 DTS 来源与板级片段

- Linux 6.12 `arch/arm/boot/dts/qcom/` 下已有完整 DTS：
  ```
  qcom-ipq4019.dtsi
  qcom-ipq4019-ap.dk04.1.dtsi
  qcom-ipq4019-ap.dk04.1-c1.dts
  ```
  **若内核/U-Boot 都没有 IPQ4019 DTS**，获取顺序：① 找其它 Linux 版本 / OpenWrt `target/linux/ipq40xx` / QSDK 的 DTS；② 找同 SoC 近似板 DTS 改写（model/compatible、memory、chosen、pinctrl、fixed-partitions、SPI/UART/MDIO）；③ 从设备现有 FIT 里直接抽 DTB 反编译：`dd if=/dev/mtd8 of=/tmp/fit.itb` → `dumpimage -l` 找 `fdt@ap.dk04.1-c1` 的 position → `dumpimage -i /tmp/fit.itb -o /tmp/board.dtb -T flat_dt -p <pos> fdt@ap.dk04.1-c1` → `dtc -I dtb -O dts -o board.dts /tmp/board.dtb`，得到厂商原始 DTS 再按 U-Boot 需要补 `u-boot,dm-pre-reloc`/`chosen/stdout-path`。DTS 是数据，没有它内核就不知道硬件；有现成 DTB 也能直接给内核用。
- 把它们拷到 U-Boot 的 `arch/arm/dts/` 和 `dts/upstream/src/arm/`（因 `CONFIG_OF_UPSTREAM=y`，实际从后者找）。
- `CONFIG_OF_UPSTREAM` 的作用：让 U-Boot 从 `dts/upstream/src/<arch>/`（上游 Linux DTS 副本）取**基础 DTS**，而不是从传统 `arch/arm/dts/`；板级 `-u-boot.dtsi` 片段仍由 U-Boot 自己维护。`ARCH_IPQ40XX` 对它只是 `imply`（默认开），可以在 defconfig 里写 `# CONFIG_OF_UPSTREAM is not set` 关掉，此时只需把 DTS 放在 `arch/arm/dts/`。它与 `CONFIG_OF_CONTROL` 不同：后者必须保持 y，因为要把 DTB 编进 u-boot.bin。我们为了避免路径问题两个目录都拷了，所以关掉也能编。
- 实测若 defconfig 没设 `CONFIG_DEFAULT_DEVICE_TREE`、且没拷 DTS，链接完 `u-boot` 后报错 `Device Tree Source (dts/upstream/src/arm/unset.dtb) is not correctly specified. Please define 'CONFIG_DEFAULT_DEVICE_TREE'`，`dts/Makefile:54` 失败。修复：defconfig 加 `CONFIG_DEFAULT_DEVICE_TREE="qcom-ipq4019-ap.dk04.1-c1"`，拷入上述 DTS + dt-bindings + 板级 u-boot.dtsi，重新 defconfig 后再 make。也可临时用 `make DEVICE_TREE=<name>`，但 defconfig 更持久。
- 从 Linux `include/dt-bindings/` 补拷头文件：`clock/qcom,gcc-ipq4019.h`、`interrupt-controller/arm-gic.h`、`irq.h`、`gpio/gpio.h`、`input/input.h`、`input/linux-event-codes.h`。
- 为什么叫这个名字、为什么必须存在：U-Boot 规定“板级 `-u-boot.dtsi` overlay”的文件名 = `CONFIG_DEFAULT_DEVICE_TREE` 的值 + `-u-boot.dtsi`。构建时若找到该文件，会在用 `dtc` 编译基础 `.dts` 时自动把它 include 进去。目的：**不修改上游 Linux 的 DTS**，把只跟 U-Boot 有关的改动（重定位前就要用的 `u-boot,dm-pre-reloc`、U-Boot 的 `chosen/stdout-path`、U-Boot 才需要的 mdio/switch/MAC/端口使能、本机无 NAND 要关掉等）单独放在 overlay。没有它，基础 DTS 在 Linux 里是对的，但在 U-Boot 阶段串口/SPI/网卡可能未就绪，就会出现 `sf probe` 读不到 ID、`Net: No ethernet found` 等。我们两个目录都放了，所以无论 OF_UPSTREAM 开关都能命中。
- 新建 `qcom-ipq4019-ap.dk04.1-c1-u-boot.dtsi`，包含：
  - `#include "qcom-ipq4019-u-boot.dtsi"`
  - `chosen { stdout-path = "serial0:115200n8"; }`，alias `serial0 = &blsp1_uart1`
  - `&blsp1_uart1` / `&blsp1_spi1` 加 `u-boot,dm-pre-reloc; status="okay";`
  - `&tlmm` / `&gcc` / `&spi_0_pins` 加 `u-boot,dm-pre-reloc`
  - `&nand { status = "disabled"; }`（本机无 NAND）
  - `&mdio { status = "okay"; u-boot,dm-pre-reloc; }`
  - `&switch { status = "okay"; mac-address = [00 11 22 33 44 55]; ports { phy-mode = "psgmii"; }; }`
  - `&swport5 { status = "okay"; }`（WAN 口，PHY4，厂商日志中唯一 link up 的口）
- `CONFIG_DEFAULT_DEVICE_TREE="qcom-ipq4019-ap.dk04.1-c1"` **只是设备树的名字，不含路径也不含 `.dts`**。`dts/Makefile` 的做法：
  - `DEVICE_TREE := $(CONFIG_DEFAULT_DEVICE_TREE:"%"=%)`；
  - 若 `CONFIG_OF_UPSTREAM=y`（本板由 `ARCH_IPQ40XX` imply 默认开）→ `dt_dir := dts/upstream/src/$(ARCH)`，即权威文件是 **`dts/upstream/src/arm/qcom-ipq4019-ap.dk04.1-c1.dts`**；
  - 若关掉 OF_UPSTREAM → `dt_dir := arch/$(ARCH)/dts`，即 **`arch/arm/dts/qcom-ipq4019-ap.dk04.1-c1.dts`**。
  - 该 `.dts` 通过相对 include 引用同目录的 `qcom-ipq4019-ap.dk04.1.dtsi` → `qcom-ipq4019.dtsi`；`dt-bindings` 头文件来自 `include/dt-bindings/`。
  - 编译生成 `dts/upstream/src/arm/qcom-ipq4019-ap.dk04.1-c1.dtb`（或 arch/arm/dts/ 下），再拷成 `dts/dt.dtb`、`u-boot.dtb`，最后 CAT 进 `u-boot.bin`。
  - U-Boot 还会自动找同名加 `-u-boot.dtsi` 的片段：`qcom-ipq4019-ap.dk04.1-c1-u-boot.dtsi`（我们两个目录都放了，所以无论从哪找都能命中）。

### 6.4 必要源码补丁（共 6 个既有文件）

| 文件 | 改动 |
|---|---|
| `arch/arm/mach-ipq40xx/Kconfig` | 增加 `config SYS_CONFIG_NAME` 默认 `ipq40xx_ap_dk04_1` |
| `arch/arm/mach-ipq40xx/cpu.c` | 补 `get_tbclk()`(48 MHz)、`timer_read_counter()`(CP15 CNTVCT)、`print_cpuinfo()`、`reset_cpu()`；reset 写 pshold `0x4ab000`=0。实测若不补会在链接时报 `undefined reference to reset_cpu/get_tbclk/print_cpuinfo/timer_read_counter`（common 代码要这些 SoC 级函数，主线 ipq40xx cpu.c 只实现了 dram_init/caches/board_init）。`print_cpuinfo` 返回 int（写成 void 会 conflicting types）；`reset_cpu` 需 `#include <asm/io.h>` 用 writel。 |
| `arch/arm/mach-ipq40xx/include/mach/gpio.h` | 同步 snapdragon 版本，补 `struct msm_special_pin_data`、`special_pins_data`、`msm_pinctrl_is_reserved` 声明；实测若不改会在 `pinctrl-qcom.c` 报 `implicit declaration of msm_pinctrl_is_reserved`、`struct msm_pin_data has no member special_pins_data`、`conflicting types for msm_pinctrl_is_reserved`（GCC 把 implicit declaration 当 error）。原因：通用 `drivers/pinctrl/qcom/pinctrl-qcom.c` 由 Snapdragon 和 IPQ40xx 共用，但 ipq40xx 的 mach/gpio.h 版本过旧缺这些定义。修复：`cp arch/arm/mach-snapdragon/include/mach/gpio.h arch/arm/mach-ipq40xx/include/mach/gpio.h` 后重编。clock-qcom.c 的 `%llx` 格式警告非致命，可忽略。 |
| `drivers/gpio/Kconfig` | `MSM_GPIO` 依赖从 `ARCH_SNAPDRAGON` 扩为 `ARCH_SNAPDRAGON || ARCH_IPQ40XX` |
| `drivers/spi/spi-qup.c` | 补开 iface(AHB) 时钟；`qup_spi_hw_init()` 强制 `SPI_CONFIG_INPUT_FIRST`（BIT9） |
| `include/phy_interface.h` | 增加 `PHY_INTERFACE_MODE_PSGMII` 与 `"psgmii"` 字符串 |
| `drivers/net/essedma.c` | `essedma_of_phy()` 中 `phy_config()` 前设 `phydev->autoneg = AUTONEG_ENABLE`；`#if 0` 跳过 `psgmii_self_test()`（其 `qca8075_ess_reset()` 用 `phydev[num_phy-1]`，单端口时是 WAN PHY4，会写 BMCR 冲掉 autoneg） |

新增文件：板级 defconfig、板级 config header（`CFG_SYS_INIT_RAM_ADDR 0x87000000` / `SIZE 0x10000`）、3 个 DTS + 板级 u-boot.dtsi、dt-bindings 头文件。

> 实测：若没加 `SYS_CONFIG_NAME` 和板级 config header，编译会在汇编阶段报 `arch/arm/cpu/armv7/start.S:287: Error: syntax error -- 'ldr r0,=((CFG_SYS_INIT_RAM_ADDR+CFG_SYS_INIT_RAM_SIZE-240))'`（crt0.S:106 同样）。原因：`CFG_SYS_INIT_RAM_ADDR/SIZE` 是板级头文件里的宏，不是 Kconfig 选项；未定义时宏展开为空，汇编器看到 `((+ -240))` 就报语法错。修复就是在 mach Kconfig 里加 `config SYS_CONFIG_NAME` 默认 `ipq40xx_ap_dk04_1`，并创建 `include/configs/ipq40xx_ap_dk04_1.h` 定义这两个宏，然后重新 `make <defconfig>`。
>
> `include/configs/` 里大多是板级头文件，但也有 SoC/通用头文件（如 `qcom.h`、`am33xx.h`、`ti.h`），不是每个文件都对应一块具体板；真正被本次编译选中的那个由 `CONFIG_SYS_CONFIG_NAME` 决定。机制：`scripts/Makefile.autoconf` 会生成 `include/config.h`，其中有一行 `#include <configs/$(CONFIG_SYS_CONFIG_NAME).h>`；所以 `CONFIG_SYS_CONFIG_NAME="ipq40xx_ap_dk04_1"` 就会包含 `include/configs/ipq40xx_ap_dk04_1.h`（值不含 `.h`）。该头文件提供少数还没迁到 Kconfig 的低级 `CFG_*` 宏；绝大多数选项来自 Kconfig（`include/generated/autoconf.h`）。也可直接在 defconfig 写 `CONFIG_SYS_CONFIG_NAME="ipq40xx_ap_dk04_1"` 覆盖默认值。验证：`grep -n 'SYS_CONFIG_NAME' .config include/config/auto.conf; grep -n 'configs/' include/config.h`。

### 6.5 defconfig 关键项（`configs/ipq40xx_ap_dk04_1_defconfig`）

```
CONFIG_TEXT_BASE=0x84000000                 # 链加载版：链接基址=加载地址
CONFIG_ARM=y
CONFIG_ARCH_IPQ40XX=y
CONFIG_DEFAULT_DEVICE_TREE="qcom-ipq4019-ap.dk04.1-c1"
CONFIG_SYS_LOAD_ADDR=0x84000000
CONFIG_MTD=y
CONFIG_SPI=y / CONFIG_DM_SPI=y / CONFIG_SPI_QUP=y
CONFIG_DM_SPI_FLASH=y / CONFIG_CMD_SF=y / CONFIG_SPI_FLASH_MACRONIX=y
CONFIG_MSM_SERIAL=y / CONFIG_DEBUG_UART=y / CONFIG_DEBUG_UART_MSM=y
CONFIG_DEBUG_UART_BASE=0x78af000 / CONFIG_DEBUG_UART_CLOCK=1843200
CONFIG_FIT=y / CONFIG_CMD_BOOTM=y
CONFIG_ENV_IS_NOWHERE=y
CONFIG_POWER_DOMAIN=y
CONFIG_DM_GPIO=y / CONFIG_MSM_GPIO=y
CONFIG_DM_MDIO=y / CONFIG_MDIO_IPQ4019=y
CONFIG_ESSEDMA=y / CONFIG_PHYLIB=y
CONFIG_CMD_MII=y / CONFIG_CMD_MDIO=y / CONFIG_CMD_ETHSW=y
CONFIG_USE_IPADDR=y / CONFIG_USE_NETMASK=y / CONFIG_USE_SERVERIP=y
CONFIG_IPADDR="172.18.0.136" / CONFIG_SERVERIP="172.18.0.134" / CONFIG_NETMASK="255.255.255.0"
# CONFIG_TOOLS_LIBCRYPTO is not set
# CONFIG_TOOLS_KWBIMAGE is not set
# CONFIG_TOOLS_MKEFICAPSULE is not set
```

> 关掉 TOOLS_* 是为了绕过编译机缺失的 OpenSSL/GnuTLS 头文件。`CONFIG_TOOLS_KWBIMAGE` 会 select LIBCRYPTO，必须一起关。字符串配置必须带引号，否则被解析为空。
> 实测若最小 defconfig 不含这三行，编译会在 host tools 阶段报 `include/image.h:1606: fatal error: openssl/evp.h: No such file or directory`（`tools/aisimage.o`/`amlimage.o`/`fit_common.o`）。这是**主机工具**编译问题，不是 ARM 目标代码；修复就是在 defconfig 加 `# CONFIG_TOOLS_LIBCRYPTO is not set`、`# CONFIG_TOOLS_KWBIMAGE is not set`、`# CONFIG_TOOLS_MKEFICAPSULE is not set`，然后重新 `make <defconfig>`。
> 实测坑：`CONFIG_SYS_LOAD_ADDR` 是 string 类型，写成 `=0x84000000`（无引号）会在 `syncconfig` 时报 `.config:194:warning: symbol value '' invalid for SYS_LOAD_ADDR`，并触发 `Restart config...` 交互式询问同一项多次而卡住。必须写成 `CONFIG_SYS_LOAD_ADDR="0x84000000"`；改完重新 `make <defconfig>` 生成干净 `.config` 再编译。

**真正编译镜像的命令**（必须用 Arm GNU 13.2，系统 `arm-linux-gnueabi-` 是 GCC 7.3，会在 `checkgcc10` 处失败）：

```sh
cd ~/u-boot-clean
TC=$HOME/arm-gnu-toolchain-13.2.Rel1-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-
make ARCH=arm CROSS_COMPILE=$TC ipq4019_defconfig    # 或自己的 defconfig 名
make ARCH=arm CROSS_COMPILE=$TC -j$(nproc)
ls -lh u-boot.bin u-boot.dtb
```

产物在源码树根目录：`u-boot.bin`（含 DTB）、`u-boot.dtb`。建议用 `timeout 600 make ...` 或别把输出无限重定向到日志（曾出现过 17GB 失控日志占满磁盘）。

### 6.6 链加载与 TEXT_BASE 坑

- 正确流程（用厂商 U-Boot 中转）：
  ```sh
  tftpboot 0x84000000 u-boot.bin
  go 0x84000000
  ```
- 失败历史与结论：
  - 首次 `go 0x84000000` data abort：因为当时 `CONFIG_TEXT_BASE=0x87300000`（SBL1 加载 APPSBL 的地址），链接基址 ≠ 加载地址。
  - 改 `tftpboot 0x87300000` 报 `load address not allowed`：那是厂商 U-Boot 自身运行区，不能覆盖。
  - 解决：链加载版 `CONFIG_TEXT_BASE=0x84000000`（链接基址 = 加载地址）。
  - 后来 `tftpboot 0x85000000 ... go 0x85000000` 卡死同理：必须在其链接基址运行。
- 若将来做永久 flash 版，必须另编 `CONFIG_TEXT_BASE=0x87300000` 的镜像，写到 mtd6 后由 SBL1 原生加载；之后运行时在 0x87300000，0x85000000 空闲，可用作 tftp 数据中转。

**`CONFIG_TEXT_BASE` vs `CONFIG_SYS_LOAD_ADDR`（两者不必相同）**：

| 选项 | 作用 | 何时生效 |
|---|---|---|
| `CONFIG_TEXT_BASE` | U-Boot **自身的链接基址**（链接脚本 `u-boot.lds` 用它）。早期代码按它计算全局数据/重定位偏移，所以镜像首次执行的地址必须等于它，否则 data abort | 链接阶段 + 上电/链加载瞬间 |
| `CONFIG_SYS_LOAD_ADDR` | `tftpboot`/`load` 等**不指定地址时的默认下载目的地**，也是 `bootm` 不带地址时的默认镜像地址 | 运行时命令默认参数 |

- 两者**没有必须相等的要求**。我们的链加载版把它们都设成 `0x84000000` 只是为了省事：`tftpboot u-boot.bin` 不写地址时正好落到链接基址。
- 如果每次都显式写 `tftpboot 0x84000000 ...`，`SYS_LOAD_ADDR` 写成别的值也不影响链加载。
- 永久 flash 版可以是 `TEXT_BASE=0x87300000`（SBL1 加载点）、`SYS_LOAD_ADDR=0x84000000`（tftp 内核/FIT 用），两者不同很正常。
- 关键约束只有一个：**U-Boot 镜像首次被执行的地址必须等于它的 `CONFIG_TEXT_BASE`**（除非该版本支持任意地址重定位）。
- 常见混淆：这里的“加载地址”指的是 **`go <addr>` 时 U-Boot 自身开始执行的地址**，不是 `SYS_LOAD_ADDR`。`SYS_LOAD_ADDR` 只是 `tftpboot` 不写地址时的默认存放位置；即使它不等于 TEXT_BASE，只要显式 `tftpboot 0x84000000 u-boot.bin; go 0x84000000`，就与 TEXT_BASE 一致，不会 data abort。反过来，若 `tftpboot u-boot.bin`（落到 SYS_LOAD_ADDR）后 `go` 到那个地址，则那个地址必须等于 TEXT_BASE。
- 因此**如果坚持“tftpboot 不写地址 + go 到该默认地址”这套操作来加载新 U-Boot，则 `CONFIG_SYS_LOAD_ADDR` 必须等于该 U-Boot 的 `CONFIG_TEXT_BASE`**，否则文件落在 A、`go` 到 A 执行，而镜像是按 B 链接的，必然 data abort。注意这条只对“下载的是 U-Boot 二进制并要 go 执行”成立；若下载的是 FIT/kernel 再 `bootm`，与 TEXT_BASE 无关。

### 6.7 SPI NOR 排障结论（`sf probe` 从 ff ff ff 到成功）

关键证据链与最终结论：

1. 加调试打印确认：`probe base=78b5000`、BEGIN `set_cs val=0`（CS 拉低）、发送 `tx0=9f`、读回全 `ff`。
2. `dm tree` 显示 clock/pinctrl/gpio/spi_qup 全部 `[+]`；反编译 DTB 确认 pinctrl/pre-reloc 和 `cs-gpios` 配置生效。
3. pinmux 打印：gpio 13/14/15 func=5 → mux=1，即 `blsp_spi0`，正确；CS pin gpio12 为 gpio 功能。
4. QUP 寄存器：`QUP_CONFIG=0x107` 正常，但 `SPI_CONFIG=0` —— `SPI_CONFIG_INPUT_FIRST`(BIT9) 没置位（`qup_spi_set_mode()` 未被调用）。
5. **最终修复**：`qup_spi_hw_init()` 强制 `val |= SPI_CONFIG_INPUT_FIRST;` → `SPI_CONFIG=0x200`，读回 `c2 20 1a c2`，识别成功：
   ```
   SF: Detected mx66l51235l with page size 256 Bytes, erase size 64 KiB, total 64 MiB
   ```
6. 曾尝试并排除：`cs-gpios` 改 `GPIO_ACTIVE_LOW`（错误方向——驱动 BEGIN 写 0，ACTIVE_HIGH 才是物理低有效）；只开 core clock 不开 iface clock（需补）。两者最终状态：CS 保持原厂 `GPIO_ACTIVE_HIGH`，iface clock 已补开。

### 6.8 网络与 reset 修复结论

- `reset` 卡死：旧 `reset_cpu()` 是死循环；改为写 `qcom,pshold`（`0x4ab000`）=0（参考 Linux `msm-poweroff.c`）。
- 网卡从无到有：
  1. 补 PSGMII 枚举 → essedma 可编译；
  2. defconfig 开 ESSEDMA/MDIO_IPQ4019/PHYLIB；
  3. 板级 DTS：`&switch { status="okay"; phy-mode="psgmii"; mac-address=[...]; }`、`&mdio { status="okay"; }`；
  4. 启用 `&swport5`（WAN/PHY4）——否则 `num_phy=0`，`qca8075_ess_reset()` 取 `phydev[-1]` 导致 data abort。
- ARP 失败根因与修复：
  - 现象：`eth0` 注册但 `ARP Retry count exceeded`；`mii info` 显示 PHY4 停在 10HDX；BMCR=`0x0040`（未开 AN），BMSR=`0x7949`（link down）。
  - 手动 `mii write 4 0 0x1200` 后 PHY4=100FDX、TFTP 可下载，证明是 autoneg 未启动。
  - 修复 1：`essedma_of_phy()` 中 `phy_config()` 前设 `phydev->autoneg = AUTONEG_ENABLE`。
  - 修复 2（关键）：`#if 0` 跳过 `psgmii_self_test()`——它调用的 `qca8075_ess_reset()` 用 `phydev[num_phy-1]`（单端口时是 WAN PHY4）反复写 BMCR `0x005b/0x001b`，把 autoneg 冲掉。
  - 最终版本开机自动 link up、TFTP 直接可用，无需手动 `mii write`。
- 诊断命令已编入：`mii info`、`mii read/write`、`mdio list`、`ethsw`。

### 6.9 最终验证状态

- 最终链加载版 `u-boot.bin`：**462,424 字节**，banner `U-Boot 2026.10-dirty`，无 `DBG QUP:`/`DBG PINMUX:` 打印，已放到本机 TFTP 根目录。
- 已验证能力：串口、DRAM、DTS、时钟/pinctrl、64 MiB SPI NOR、FIT `bootm` 启动原厂 Linux 进系统、网络 TFTP、reset。
- 典型操作：
  ```sh
  # 厂商 U-Boot 中链加载
  tftpboot 0x84000000 u-boot.bin
  go 0x84000000

  # 新 U-Boot 中验证
  sf probe
  sf read 0x85000000 0x180000 0x400000
  bootm 0x85000000#config@ap.dk04.1-c1

  # 网络
  mii info
  tftpboot 0x85000000 u-boot.bin
  reset
  ```
- 主线 `bootm` 只读标准 `bootargs`，厂商 FIT 用 `bootargs-append`；若 rootfs 挂不上，先 `setenv bootargs 'rootfsname=rootfs rootwait clk_ignore_unused'`。

### 6.10 变砖边界

- 软砖（U-Boot 能跑）：串口 TFTP 可救。
- APPSBL 坏且进不去 U-Boot：TFTP 手段失效；只能靠 Boot ROM EDL/9008（本机未实测）或外部 SPI 编程器（CH341A + SOIC 夹）配合备份。
- 结论：未确认恢复通道前不写 mtd6；学习目的已通过 RAM 链加载达成。

---

## 7. 内核移植要点与风险

1. **DT compatible 不可信**：`n25q128a11` 是 16 MiB 型号，实际 64 MiB Macronix；用 `jedec,spi-nor` 让 ID 自动识别。
2. **HLOS 是 FIT**：必须保留 `config@ap.dk04.1-c1` / 本板 DTB、load/entry `0x80208000`、gzip 内核、≤4 MiB。
3. **ART/校准必须保留**：`0:ART` 在 `0x170000`，含 WiFi 校准和 MAC；主线内核用 `nvmem-cells` 读取。
4. **rootfs_data 是运行时拆分的**：依赖 mtdsplit；新内核/OpenWrt 需保留，否则 overlay 起不来。新 squashfs 必须结束在 `0x16D0000` 前。
5. **内存紧张**：256 MB、无 swap、无 compaction；Slab 58 MB（54 MB 不可回收），vmalloc 约 27 MB（RAM 部分）。
6. **模块区 14 MiB**（+pkmap 2 MiB）：262 个模块占 8.7 MiB，新内核带大量 out-of-tree 模块需评估。
7. **bootloader 环境**：mtd5 里是 U-Boot env（`bootcmd=bootipq`、IP、MAC），改前先备份。
8. **先备份整片 Flash**：至少备份 SBL1/MIBIB/QSEE/APPSBL/ART/HLOS/rootfs，并记录芯片型号。
9. **主线支持情况**：主线有 IPQ4019/AP-DK04 DTS，但本板是厂商定制，需基于 DK04 改；WiFi 要换 ath10k，NSS 不可用。
10. **替换 mtd8 不是一步到位**：保留 FIT 配置名/加载地址/4 MiB 上限；DTB 带固定分区；主线用 `root=` 而非 `rootfsname=`；先 TFTP + bootm 在 RAM 验证，再写 flash。
11. **串口是生命线**：波特率 115200，`bootdelay=2`；没有串口不要直接写 mtd8。
12. **完整固件升级有现成机制**：厂商 sysupgrade 接受外层 FIT（`hlos`+`fs`），只写 mtd8/mtd9。
13. **不要刷 bootloader/ART**：SBL1/QSEE/APPSBL/MIBIB 刷错会变砖；ART 丢了不可恢复。`sysupgrade` 的 `mibib`/`bootconfig` 段会被忽略。

---

## 8. 待确认 / 下一步

- [x] 设备识别、Flash 容量（64 MiB）、芯片型号
- [x] U-Boot 版本、bootargs、FIT 结构、串口参数
- [x] 完整启动日志与上电流程
- [x] sysupgrade / platform.sh 升级流程
- [x] 主线 U-Boot 2026.10 板级移植并在 RAM 中完整验证
- [ ] 备份整片 Flash（至少 mtd5/6/7）并计算 md5
- [ ] 确认 EDL/9008 或 SPI 编程器是否可用（未确认前不刷 mtd6）
- [ ] 选定目标内核版本（建议 Linux 6.12 LTS / OpenWrt ipq40xx 内核）
- [ ] 用主线/OpenWrt DTS 做最小系统，TFTP + initramfs 启动
- [ ] 迁移 SPI NOR、pinctrl、clock、USB、PCIe、GMAC、WiFi（ath10k）
- [ ] 评估 NSS/ECM 替代方案（软件转发或其他）

---

## 9. 常用检查命令

```sh
# vim swap 文件（SSH/vim 异常退出后残留，导致下次打开提示 E325）
# vim 先试 .swp；若已存在则依次用 .swo/.swn/.../.swz，异常退出会堆积一堆
rm -f configs/.*.sw?                 # 删掉该文件所有 swap 变体
rm -f /var/tmp/ipq*.sw? /tmp/.*.sw?  # vim 目录备选路径也可能有残留
# 或打开时按 D 删除；想避免再生成：vim -n <file> 或在 ~/.vimrc 写 set noswapfile
ps -ef | grep '[v]im'                 # 确认是否真有另一个 vim 在编辑
vim -c 'echo &directory' -c q         # 看 vim 把 swap 放哪（默认 .,/var/tmp,/tmp）

# 编译机磁盘空间 / 清理
df -h / /home
du -sh ~/* 2>/dev/null | sort -h | tail -20
du -sh ~/u-boot ~/u-boot-clean ~/linux-6.12 ~/arm-gnu-toolchain-13.2.Rel1-* 2>/dev/null
# 注意：du ~/* 不含隐藏目录，隐藏目录/系统目录常在别处占满 30G 根分区
du -sh ~/.[!.]* 2>/dev/null | sort -h | tail -20
du -sh /var /usr /opt /root /snap 2>/dev/null | sort -h
du -sh /var/* 2>/dev/null | sort -h | tail -20
du -sh /tmp/* 2>/dev/null | sort -h | tail -20     # 曾出现 17G 的失控编译日志
sudo lsof 2>/dev/null | grep deleted | awk '{print $7,$9}' | sort -n | tail  # 删了但被进程占用则不释放
# 教训：后台编译命令若失败，make 仍可能继续写日志；用 timeout/pkill 并先确认日志大小
# 源码树内编译产物（先试这个，安全）
cd ~/u-boot-clean && make ARCH=arm CROSS_COMPILE=$TC distclean
# 下载缓存 / 旧 tar 包
ls -lh ~/arm-gnu-toolchain-13.2.Rel1-*tar.xz /tmp/*.log /tmp/*.json 2>/dev/null

# Flash / 分区
cat /proc/mtd
hexdump -Cv -n 1024 /dev/mtd1          # MIBIB 表
hexdump -Cv -n 96 /dev/mtd9            # squashfs 超级块
for m in /sys/class/mtd/mtd*; do echo "$m $(cat $m/name) $(cat $m/size)"; done

# RAM
cat /proc/meminfo /proc/iomem /proc/vmallocinfo /proc/buddyinfo
cat /sys/kernel/debug/memblock/reserved

# 设备树 / ABI
cat /proc/device-tree/model
readelf -h /bin/busybox | grep Flags   # 0x5000200=soft-float
zcat /proc/config.gz | grep -E "AEABI|ARM_LPAE|VMSPLIT|MODVERSIONS|MODULE_STRIPPED"

# FIT / U-Boot（设备侧）
dd if=/dev/mtd8 of=/tmp/fit.itb
dumpimage -l /tmp/fit.itb
fw_printenv
mtd write fit.itb mtd8

# 主线 U-Boot 串口中
sf probe
sf read 0x85000000 0x180000 0x400000
bootm 0x85000000#config@ap.dk04.1-c1
mii info
mdio list
tftpboot 0x85000000 u-boot.bin
reset

# 厂商 sysupgrade（外层 FIT）
dumpimage -l /tmp/full.itb
sysupgrade -T /tmp/full.itb
sysupgrade -n /tmp/full.itb
```

SSH 执行器（本机，密码运行时通过环境变量传入）：

```powershell
$env:SSH_PASS='<密码>'
& D:\TMP\opencode\venv\Scripts\python.exe D:\TMP\opencode\ssh_run.py --host 172.18.0.136 --user root -- "命令"
```

---

## 10. 移植方法论与排障流程（怎么做的）

这一节记录「如何得出上面的结论」，而不只是结论本身。核心原则是：**不改 flash、每次只改一处、用证据定位、失败可回滚**。

### 10.1 总体循环

```
静态分析源码/配置
  → 改一处代码或 defconfig
  → 编译
  → 厂商 U-Boot 里 TFTP 下载 + go 链加载（RAM，不写 flash）
  → 看串口日志/命令输出
  → 用 addr2line / dm tree / 寄存器打印定位
  → 回到第一步
```

失败时**断电重启即恢复原 U-Boot**，所以可以无限试错。

#### defconfig 的作用，以及为什么先找它

- `defconfig` 是 **Kconfig 选项的最小种子文件**：`make <board>_defconfig` 会读入它，展开生成完整的 `.config`；后续 `make` 只看 `.config`。
  - 所以 3 行的 defconfig 可以展开成几千行的 `.config`：Kconfig 会把**每一个符号**都写进去（包括 `# CONFIG_... is not set` 的未启用项）、带上注释和自动生成的头部；`ARCH_IPQ40XX` 的 `select`/`imply` 还会连带打开一批选项。这是正常的，不代表配置错了。
  - 统计 Enabled 项：`grep -c '^CONFIG_' .config`；统计 n 项：`grep -c '^# CONFIG_' .config`；`wc -l` 看总行数。
  - 用户最小 defconfig 只有 4 行时，`.config` 里出现的 `CONFIG_SYS_BOOTM_LEN=0x800000`、`CONFIG_WATCHDOG_TIMEOUT_MSECS=60000` 等都是 Kconfig **默认值**，不是从 defconfig 来的；而 `CONFIG_SYS_LOAD_ADDR=`（空）说明该 string 选项既没在 defconfig 设置、也没有可用默认值，这正是 `syncconfig` 弹交互询问的原因。
  - 为什么 4 行能展开成几千行：**Kconfig 是全源码树的全局选项数据库**，不是只处理你写下的那几个符号的依赖关系。`make <defconfig>` 会把所有 `Kconfig`（arch/、drivers/、cmd/、fs/、net/…）里定义的**每一个符号**都写进 `.config`：值为 y/m/字符串的写成 `CONFIG_X=y`，未启用的写成 `# CONFIG_X is not set`，再加上注释和自动生成头部。所以几千行里绝大多数是 `# ... is not set`，真正 `=y` 的往往只有一两百个。那 4 行只是覆盖默认值 + 触发 select/imply，不是展开全部内容的来源。
  - **Kconfig 如何决定编译哪些文件**：`.config` 经 `syncconfig` 生成 `include/config/auto.conf`、`include/autoconf.mk`、`include/generated/autoconf.h`；各目录 `Makefile` 用 `obj-$(CONFIG_FOO) += foo.o`（如 `drivers/spi/Makefile` 的 `obj-$(CONFIG_SPI_QUP) += spi-qup.o`、`cmd/Makefile` 的 `obj-$(CONFIG_CMD_SF) += sf.o`）。CONFIG=y → 编进 `built-in.o`；=m → 模块；=n → 不编。C 代码通过 `<config.h>`/autoconf.h 拿到 `CONFIG_` 宏。DTS 由 `CONFIG_DEFAULT_DEVICE_TREE` + `CONFIG_OF_UPSTREAM` 决定，交给 `dtc`。
  - `.config` 是生成物，不提交；改完后用 `make savedefconfig` 把它压缩回精简的 defconfig。
- U-Boot/Linux 有成千上万个 Kconfig 选项，绝大多数默认都是 n。defconfig 记录了某一块板“已知能工作”的基线：ARCH/CPU、串口地址与时钟、SPI/MTD、FIT/bootm、env 位置、`CONFIG_TEXT_BASE`、默认设备树等。
- **同 SoC 不同板子的 defconfig 仍不同**：串口接哪个 UART、Flash 型号/大小、env 在哪个分区、启动介质、MAC/PHY 等都因板而异。所以不能只按 SoC 随便找一个 defconfig 用，要找**本板**的。
- 在 `configs/` 里 `grep -iE 'ipq|qcom|dk|ap'` 就是在问：“上游是否已经有人为这块板做过基线配置？”：
  - 有 → 从它起步，按需微调，工作量小；
  - 没有 → 自己 `make defconfig` 起步，用 `menuconfig` 勾选必要项，最后 `make savedefconfig` 生成自己的 defconfig（我们的 `ipq40xx_ap_dk04_1_defconfig` 就是这么来的）。
- 没有正确 defconfig 的后果：编译可能过，但串口没输出、SPI 不 probe、FIT 起不来，或 `TEXT_BASE` 不对导致链加载 data abort——这正是我们后面逐项补齐的内容。

#### “主线有 SoC 层支持”是什么意思

主线代码是分层的：

| 层次 | 内容 | 主线是否具备 |
|---|---|---|
| SoC / arch 层 | `CONFIG_ARCH_IPQ40XX`、`arch/arm/mach-ipq40xx/cpu.c`、clock (`CLK_QCOM_IPQ4019`)、pinctrl (`PINCTRL_QCOM_IPQ4019`)、串口 `serial_msm`、SPI `spi-qup`、SMEM、`essedma` 等 SoC 内部 IP 的驱动 | ✅ 有 |
| 板级层 | defconfig、完整板级 DTS（串口接哪路、Flash 型号/大小、env 偏移、`TEXT_BASE`、MAC/PHY/交换端口） | ❌ 没有本板的 |
| 外设/板载设备层 | 具体 SPI NOR 芯片、具体 PHY、具体 switch 配置 | 部分有，需板级 DTS 绑定 |

“有 SoC 层”只表示：**芯片内部的 IP 块怎么驱动，主线已经写好了**，我们不用从零写 clock/pinctrl/串口驱动；但这些驱动默认是 `n`，需要在 defconfig 里打开，并通过 DTS 把本板的硬件接法告诉它们。所以 Phase 1 的结论是“有引擎，但没车壳/线束”，后面工作是建板级配置，而不是从零造引擎。

主线 `ARCH_IPQ40XX`（`arch/arm/Kconfig:798`）具体做了什么（实测 v2026.10）：

- `select`：
  - `CPU_V7A`、`DM`、`DM_GPIO`、`DM_SERIAL`、`DM_RESET`、`GPIO_EXTRA_HEADER`
  - `PINCTRL`、`CLK`、`OF_CONTROL`
  - `CLK_QCOM_IPQ4019`（`drivers/clk/qcom/clock-ipq4019.c`，GCC @ `0x1800000`）
  - `PINCTRL_QCOM_IPQ4019`（`drivers/pinctrl/qcom/pinctrl-ipq4019.c`，TLMM @ `0x1000000`）
- `imply`：`CMD_DM`、`OF_UPSTREAM`（所以 DTS 要放到 `dts/upstream/src/arm/`）
- `arch/arm/mach-ipq40xx/Kconfig` 提供默认值：`SYS_SOC="ipq40xx"`、`SYS_MALLOC_F_LEN=0x2000`、`TEXT_BASE=0x87300000`、`NR_DRAM_BANKS=1`
- 源码存在但**默认 n、需 defconfig 打开**的 SoC 相关驱动：
  - `CONFIG_SPI_QUP` → `drivers/spi/spi-qup.c`（QUP SPI @ `0x78b5000`），`depends on ARCH_IPQ40XX`
  - `CONFIG_MSM_SERIAL` / `CONFIG_DEBUG_UART_MSM` → `drivers/serial/serial_msm.c`（UART @ `0x78af000`）
  - `CONFIG_SMEM` → `drivers/smem/`（`depends on ARCH_SNAPDRAGON || ARCH_IPQ40XX`）
  - `CONFIG_ESSEDMA` → `drivers/net/essedma.c`（`depends on DM_ETH && ARCH_IPQ40XX`）
  - `CONFIG_MDIO_IPQ4019` → `drivers/net/mdio-ipq4019.c`（`depends on DM_MDIO`）
  - `CONFIG_FIT`、`CONFIG_CMD_BOOTM`、`CONFIG_CMD_SF`、`CONFIG_DM_SPI_FLASH` 等通用选项
- 注意依赖陷阱：`CLK_QCOM` 是 `def_bool n` 且 `depends on CLK && DM_RESET && POWER_DOMAIN`，所以 defconfig 还必须开 `CONFIG_POWER_DOMAIN=y`，否则出现 unmet dependency 警告。实测用户运行 `make ... ipq4019_defconfig` 时打印：
  ```
  WARNING: unmet direct dependencies detected for CLK_QCOM
    Depends on [n]: (ARCH_SNAPDRAGON [=n] || ARCH_IPQ40XX [=y]) && CLK [=y] && DM_RESET [=y] && POWER_DOMAIN [=n]
    Selected by [y]:
    - CLK_QCOM_IPQ4019 [=y] && (...)
  ```
  这是 Kconfig 警告（非致命），表示 `ARCH_IPQ40XX` 自动 `select CLK_QCOM_IPQ4019` → 又 `select CLK_QCOM`，但 CLK_QCOM 还要求 POWER_DOMAIN=y。修复：在 defconfig 加 `CONFIG_POWER_DOMAIN=y` 后重新生成 .config。另：若用系统 `arm-linux-gnueabi-`（GCC 7.3）编译，后续 `make` 会触发 `checkgcc10` 失败，必须用 Arm GNU 13.2 工具链。

**“SoC 支持”≠“驱动已经编进镜像”**，它其实是三件不同的事：

1. **代码存在**：源码树里有 `spi-qup.c` / `serial_msm.c` / `essedma.c` 等驱动，且 Kconfig 条目写明了 `depends on ARCH_IPQ40XX` 或 `ARCH_SNAPDRAGON || ARCH_IPQ40XX`——说明这些驱动“能用于这个 SoC”。
2. **默认是否打开**：只有 `ARCH_IPQ40XX` 用 `select` 自动打开的（如 `CLK_QCOM_IPQ4019`、`PINCTRL_QCOM_IPQ4019`）才会真编进镜像；`SPI_QUP`、`MSM_SERIAL`、`ESSEDMA`、`SMEM`、`FIT`、`CMD_SF` 等默认是 `n`，必须在 defconfig 里写 `=y`。
3. **硬件是否绑定**：即使驱动编进去了，U-Boot 还需要 DTS 告诉它“串口是 `blsp1_uart1@78af000`、SPI 是 `blsp1_spi1@78b5000`、Flash 挂在这个控制器下、CS 用 gpio12”等；没有板级 DTS，驱动probe 不到设备。

一句话：**SoC 层只保证“有合适的驱动且能编译”，defconfig 决定“哪些驱动真编进去”，DTS 决定“编进去的驱动对应哪块硬件”。**

### 10.2 每一步用的工具和判据

| 阶段 | 手段 | 关键判据 |
|---|---|---|
| 确认主线支持什么 | `ls configs/`、`grep -R ARCH_IPQ40XX arch/arm`、`find arch/arm/dts -name '*ipq4019*'`、`git status --short` | 有 SoC 层但无 defconfig / board DTS |
| 编译报错 | 直接读编译器输出；`grep -R` 找符号定义 | `PHY_INTERFACE_MODE_PSGMII undeclared` → 补枚举；`pinctrl` 结构体缺成员 → 同步 gpio.h |
| 链加载 data abort | 看 `pc/lr`，用 `arm-none-linux-gnueabihf-addr2line -e u-boot -f -C <reloc_pc>` | 定位到 `phy_write`/`qca8075_ess_reset` 等具体函数 |
| 设备是否绑定 | `dm tree` | `[+]`=probed，`[ ]`=未 probe；`spi_qup [+]` 但 `flash@0 [ ]` 说明探针还没跑 |
| DTS 是否生效 | `scripts/dtc/dtc -I dtb -O dts u-boot.dtb` 反编译；`dbg PINMUX` 打印 | 确认 `cs-gpios`、pre-reloc、pin mux 真进了镜像 |
| SPI 读不到 ID | 加 `DBG QUP:` 打印 CS 值 / tx / rx；读 QUP 寄存器 | CS/命令正常但 rx 全 ff → 看 `SPI_CONFIG` 是否置 INPUT_FIRST |
| 网卡不通 | `mii info`、`mii read/write`、`mdio list`、`ethsw`、`ping` | BMCR/BMSR 判断 link 与 autoneg 状态 |
| 复位卡死 | 查 Linux `msm-poweroff.c` 找到 pshold 寄存器 | 写 0 触发冷复位 |

### 10.3 关键排障实例（从现象到根因）

1. **`go 0x84000000` 立刻 data abort**
   - 现象：`pc=84024d30`，`r3=87358fa4`（0x873xxxxx）。
   - 推理：全局数据指针按链接基址 `0x87300000` 算，但镜像跑在 `0x84000000`。
   - 处理：链加载版 `CONFIG_TEXT_BASE=0x84000000`（链接基址=加载地址）。

2. **`tftpboot 0x87300000` 报 load address not allowed**
   - 推理：`0x87300000` 是厂商 U-Boot 自身运行区，不能覆盖自身。
   - 结论：链加载只能用空闲 RAM，且必须等于新 U-Boot 链接基址。

3. **`sf probe` 返回 `ff ff ff`**
   - 先排除：ID 表、设备绑定（`dm tree`）、pinctrl/pre-reloc（反编译 DTB）、CS 极性（打印 BEGIN/END 写值）、iface 时钟（补开）、引脚复用（`DBG PINMUX` 确认 gpio13/14/15 mux=blsp_spi0）。
   - 最后读 QUP 寄存器：`QUP_CONFIG=0x107` 正常，`SPI_CONFIG=0` —— `INPUT_FIRST` 没置位。
   - 修复：`qup_spi_hw_init()` 强制 `val |= SPI_CONFIG_INPUT_FIRST` → rx 变成 `c2 20 1a c2`，识别成功。

4. **`Net: No ethernet found`**
   - `dm tree` 里 `ethernet 0 [ ] essedma` → probe 失败。
   - 逐项补：`&switch status="okay"`、`phy-mode="psgmii"`、`mac-address`、启用 `&swport5`。
   - 漏掉 `&swport5` 时 `num_phy=0`，`qca8075_ess_reset()` 取 `phydev[-1]` → data abort（用 addr2line 定位）。

5. **ARP Retry count exceeded**
   - `mii info` 显示 PHY4 停在 10HDX；`BMCR=0x0040`（未开 AN），`BMSR=0x7949`（link down）。
   - 手动 `mii write 4 0 0x1200` 后 link up、TFTP 通 → 证明是 autoneg 没启动。
   - 加 `phydev->autoneg = AUTONEG_ENABLE` 后仍不行 → 继续查发现 `psgmii_self_test()` 里的 `qca8075_ess_reset()` 又把 BMCR 写坏。
   - 最终修复：`#if 0` 跳过自测。

### 10.4 重要经验

- **不要同时改多处**：每次只动一个变量，否则无法判断哪个修复生效。
- **优先用现成证据**：Linux 6.12 的 DTS、Linux `msm-poweroff.c`、U-Boot 驱动源码里都有答案，比猜快得多。
- **打印比推理可靠**：加临时 `DBG` 打印确认 CS/命令/寄存器，定位后删除（干净版已从 git 还原/删除调试代码）。
- **地址类问题先怀疑链接基址**：`go` 卡死或 data abort，先看 `CONFIG_TEXT_BASE` 与加载地址是否一致。
- **网口问题先问“link up 了吗”**：`mii info` / BMCR / BMSR 比看 `Net:` 输出有效。
- **备份与回滚**：实验全程 RAM 链加载，断电即恢复；刷 mtd6 前必须有 EDL/编程器 + 备份。

### 10.5 如果你想自己重做

1. 拉主线 U-Boot 2026.10，应用仓库里的 patch，拷入 `u-boot/files/`；
2. 编译，拿 `u-boot.bin` 放到 TFTP 根目录；
3. 在厂商 U-Boot 里 `tftpboot 0x84000000 u-boot.bin; go 0x84000000`；
4. 按上面 10.2 的判据逐项验证：`dm tree` → `sf probe` → `mii info` → `sf read` + `bootm`；
5. 出错时先对照 10.3 的“现象→根因”表，再决定改哪一处。

---

## 11. 咨询记录

### 2026-11-23

- 建立 SSH 连接（老 dropbear 只支持 ssh-rsa；用 paramiko 3.5.1 非交互执行）。完成设备识别、RAM 布局、Flash 布局、MIBIB/squashfs/rootfs_data 分析。
- 工具链/ABI：EABI5 + soft-float，uClibc-ng 1.0.14，GCC 4.8.3 Linaro；固件基线 OpenWrt CC 15.05.1 `ipq806x/generic`。
- mtd8 FIT 启动：`config@ap.dk04.1-c1`、kernel load/entry `0x80208000`、14 个 FDT；cmdline `rootfsname=rootfs rootwait clk_ignore_unused`。
- 完整固件升级：厂商 sysupgrade 用外层 FIT（`hlos`+`fs`），只写 mtd8/mtd9；`platform.sh` 流程完整梳理。
- 早期结论中“Flash 32 MiB、模块区 16 MiB”等已被后续实测更正。

### 2026-11-24

- 启动信任链：PBL（片内 ROM）→ SBL1 → QSEE → APPSBL → HLOS；确认 SBL 只从 PBL 选中的 SPI NOR 加载 APPSBL 到 DDR `0x87300000`。
- FIT 存放：内层 FIT 在 mtd8；外层升级 FIT 在 `/tmp`；HLOS = High-Level Operating System。
- Flash 容量纠正为 **64 MiB Macronix**（MX25L51245G / mx66l51235l），推翻早期 32 MiB 推断；`/sys/bus/spi/drivers` 中 m25p80 才是实际驱动，mt29f/spidev 未绑定。
- 完整启动日志逐段分析：PBL/SBL1 时序、U-Boot FIT 加载地址、Linux 4.4.60 启动、驱动栈（qca_ol、qca-ssdk、NSS 未启用、ART caldata 提取）等。
- 可折腾范围：只有 mtd8 FIT 与 mtd9/10 rootfs；SBL1/MIBIB/QSEE/CDT/DDRPARAMS/APPSBL/ART 不能碰；APPSBLENV 谨慎可动。
- 高版本内核源码：推荐 Linux 6.12 LTS 或 OpenWrt ipq40xx 内核树；zImage 用 `arm-linux-gnueabi-`，DTB 由 dtc 生成；`multi_v7_defconfig` 是公版起点。
- 主线 U-Boot 移植：从主线 2026.10 起步，补 defconfig/DTS/驱动补丁，换 Arm GNU 13.2 工具链；解决 TEXT_BASE、SPI `INPUT_FIRST`、网卡 PSGMII/端口/autoneg、reset 等问题。
- 最终：干净版链加载 U-Boot（462,424 B）完整验证通过——串口、DRAM、SPI NOR、FIT bootm 启动原系统、网络 TFTP、reset 全部正常；全程未写 flash，保留厂商 bootloader。
- 安全结论：未确认 EDL/编程器前不写 mtd6；备份本身没用，必须有恢复通道。
