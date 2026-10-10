#!/usr/bin/env bash
# build_fw.sh — build a firmware image for soc_top and run it on tb_soc.
#
#   bash scripts/build_fw.sh [main.c ...]      default: sw/main.c
#
# RV32I with no M extension, so libgcc supplies __mulsi3 and the 64-bit helpers:
# -nostdlib drops the C library but -lgcc is still linked explicitly.
# Produces build/fw/<name>.elf/.hex, runs it on tb_soc and echoes the UART.
set -u
cd "$(dirname "$0")/.."
mkdir -p build/fw

SRCS=${*:-sw/main.c}
NAME=$(basename "${SRCS%% *}" .c)
ELF=build/fw/$NAME.elf
HEX=build/fw/$NAME.hex

riscv64-unknown-elf-gcc \
  -march=rv32i_zicsr -mabi=ilp32 -O2 -Wall -Wextra -Werror \
  -ffreestanding -fno-builtin -nostdlib -nostartfiles \
  -I sw -T sw/link.ld -Wl,--no-warn-rwx-segments \
  sw/crt0.S $SRCS -o "$ELF" -lgcc || exit 1
  # one RAM region holds code and data by design (unified memory), hence RWX

riscv64-unknown-elf-size "$ELF"
python3 scripts/elf2hex.py "$ELF" "$HEX" || exit 1

TOHOST=$(riscv64-unknown-elf-nm "$ELF" | awk '$3=="tohost"{print $1}')
iverilog -g2012 -I tb -s tb_soc -o build/tb_soc_fw \
  rtl/core/*.sv rtl/accel/*.sv rtl/bus/*.sv rtl/periph/*.sv rtl/mem/*.sv rtl/soc_top.sv \
  tb/tb_soc.sv 2>build/tb_soc_fw.iv.log || { grep -v "constant selects" build/tb_soc_fw.iv.log; exit 1; }

vvp -n build/tb_soc_fw +hex="$HEX" +tohost="$TOHOST" +timeout=2000000 | grep -v "sorry:"
