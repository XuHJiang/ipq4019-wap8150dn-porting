# IPQ4019（WAP8150DN）内核 / U-Boot 移植笔记

> 维护规则：每次咨询后把新增知识点补进对应章节，并在文末「咨询记录」追加一条。
> 不在笔记中保存明文密码/密钥；调试脚本统一放 `D:\TMP\opencode`。
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
- 把它们拷到 U-Boot 的 `arch/arm/dts/` 和 `dts/upstream/src/arm/`（因 `CONFIG_OF_UPSTREAM=y`，实际从后者找）。
- 从 Linux `include/dt-bindings/` 补拷头文件：`clock/qcom,gcc-ipq4019.h`、`interrupt-controller/arm-gic.h`、`irq.h`、`gpio/gpio.h`、`input/input.h`、`input/linux-event-codes.h`。
- 新建 `qcom-ipq4019-ap.dk04.1-c1-u-boot.dtsi`，包含：
  - `#include "qcom-ipq4019-u-boot.dtsi"`
  - `chosen { stdout-path = "serial0:115200n8"; }`，alias `serial0 = &blsp1_uart1`
  - `&blsp1_uart1` / `&blsp1_spi1` 加 `u-boot,dm-pre-reloc; status="okay";`
  - `&tlmm` / `&gcc` / `&spi_0_pins` 加 `u-boot,dm-pre-reloc`
  - `&nand { status = "disabled"; }`（本机无 NAND）
  - `&mdio { status = "okay"; u-boot,dm-pre-reloc; }`
  - `&switch { status = "okay"; mac-address = [00 11 22 33 44 55]; ports { phy-mode = "psgmii"; }; }`
  - `&swport5 { status = "okay"; }`（WAN 口，PHY4，厂商日志中唯一 link up 的口）
- `CONFIG_DEFAULT_DEVICE_TREE="qcom-ipq4019-ap.dk04.1-c1"`。

### 6.4 必要源码补丁（共 6 个既有文件）

| 文件 | 改动 |
|---|---|
| `arch/arm/mach-ipq40xx/Kconfig` | 增加 `config SYS_CONFIG_NAME` 默认 `ipq40xx_ap_dk04_1` |
| `arch/arm/mach-ipq40xx/cpu.c` | 补 `get_tbclk()`(48 MHz)、`timer_read_counter()`(CP15 CNTVCT)、`print_cpuinfo()`、`reset_cpu()`；reset 写 pshold `0x4ab000`=0 |
| `arch/arm/mach-ipq40xx/include/mach/gpio.h` | 同步 snapdragon 版本，补 `struct msm_special_pin_data`、`special_pins_data`、`msm_pinctrl_is_reserved` 声明 |
| `drivers/gpio/Kconfig` | `MSM_GPIO` 依赖从 `ARCH_SNAPDRAGON` 扩为 `ARCH_SNAPDRAGON || ARCH_IPQ40XX` |
| `drivers/spi/spi-qup.c` | 补开 iface(AHB) 时钟；`qup_spi_hw_init()` 强制 `SPI_CONFIG_INPUT_FIRST`（BIT9） |
| `include/phy_interface.h` | 增加 `PHY_INTERFACE_MODE_PSGMII` 与 `"psgmii"` 字符串 |
| `drivers/net/essedma.c` | `essedma_of_phy()` 中 `phy_config()` 前设 `phydev->autoneg = AUTONEG_ENABLE`；`#if 0` 跳过 `psgmii_self_test()`（其 `qca8075_ess_reset()` 用 `phydev[num_phy-1]`，单端口时是 WAN PHY4，会写 BMCR 冲掉 autoneg） |

新增文件：板级 defconfig、板级 config header（`CFG_SYS_INIT_RAM_ADDR 0x87000000` / `SIZE 0x10000`）、3 个 DTS + 板级 u-boot.dtsi、dt-bindings 头文件。

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

## 10. 咨询记录

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
