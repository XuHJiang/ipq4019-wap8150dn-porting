# IPQ4019 / WAP8150DN (AP-DK04.1-C1) 移植记录

本仓库整理 IPQ4019（WAP8150DN，DT model `AP-DK04.1-C1`）的内核 / U-Boot 移植学习与验证过程。

## 目录

- `notes/ipq4019-kernel-porting.md`：完整移植笔记（设备信息、Flash 布局、启动链、sysupgrade、工具链、主线 U-Boot 移植全过程）。
- `u-boot/patches/0001-mainline-u-boot-2026.10-ipq4019-ap-dk04-1.patch`：对主线 U-Boot 2026.10 的必要源码修改（diff）。
- `u-boot/files/`：需要新增到 U-Boot 源码树的文件（板级 defconfig、DTS、config header、dt-bindings）。
- `scripts/build-and-test.sh`：构建与验证命令记录。

## 当前状态

主线 U-Boot 2026.10 已完成板级移植，并通过 RAM 链加载验证：
串口 / DRAM / DTS / 64 MiB SPI NOR / FIT `bootm` 启动原厂 Linux / 网络 TFTP / reset 均正常。
**全程未改写设备 flash**，厂商 APPSBL / MIBIB / ART 保持原样。

## 复现方式（概要）

1. 拉主线 U-Boot 2026.10；
2. 应用 `u-boot/patches/` 中的补丁；
3. 把 `u-boot/files/` 下的文件按原路径拷入 U-Boot 源码树；
4. 使用 Arm GNU Toolchain 13.2 (`arm-none-linux-gnueabihf-`) 编译：

   ```sh
   make ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- ipq40xx_ap_dk04_1_defconfig
   make ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- -j$(nproc)
   ```

5. 在厂商 U-Boot 串口中链加载验证：

   ```sh
   tftpboot 0x84000000 u-boot.bin
   go 0x84000000
   ```

   链加载版 `CONFIG_TEXT_BASE=0x84000000`；若要永久写 mtd6，必须另编 `CONFIG_TEXT_BASE=0x87300000` 的 flash 版（未确认 EDL/编程器前不建议刷写）。

## 安全提示

- 只能折腾 mtd8 (`0:HLOS` FIT) 与 mtd9/10 (`rootfs`/`rootfs_data`)。
- 不要写 SBL1 / MIBIB / QSEE / CDT / DDRPARAMS / APPSBL / ART。
- 本仓库不含任何密码 / Token；笔记中的 SSH 模板仅保留占位符。
