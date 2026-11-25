#!/bin/sh
# 构建与链加载验证流程记录（在编译机 10.10.10.135 上执行）
TC=$HOME/arm-gnu-toolchain-13.2.Rel1-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-

cd ~/u-boot
make ARCH=arm CROSS_COMPILE=$TC ipq40xx_ap_dk04_1_defconfig
make ARCH=arm CROSS_COMPILE=$TC -j$(nproc)

# 把 ~/u-boot/u-boot.bin 放到 TFTP 根目录后，在设备厂商 U-Boot 串口执行：
#   tftpboot 0x84000000 u-boot.bin
#   go 0x84000000
#
# 进入新 U-Boot 后验证：
#   sf probe
#   sf read 0x85000000 0x180000 0x400000
#   bootm 0x85000000#config@ap.dk04.1-c1
#   mii info
#   tftpboot 0x85000000 u-boot.bin
#   reset
