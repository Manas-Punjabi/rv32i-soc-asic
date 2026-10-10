# gls_smoke.S — the program post-layout simulation runs on the routed netlist.
#
# Deliberately small: gate-level simulation of the whole SoC is orders of
# magnitude slower than RTL, so this exercises one path of each kind rather than
# repeating the RTL suites. It must also fit entirely in the first 2 KB, because
# the base build has 1024 words of RAM in two 512-word macro banks and only
# bank 0 is preloaded (see scripts/run_gls.sh).
#
#   1  ALU + branches          add/sub/shift/compare, each checked
#   2  memory                  store then load back through the data port
#   3  APB read, slave 0       UART DIV register reads back what was written
#   4  APB read, slave 1       accelerator PARAMS = {DW=32, N=4} = 0x2004
#   5  instruction fetch       a taken branch and a jal, exercising the fetch
#                              queue's redirect path on the real netlist
#
# No stack and no calls: nothing here needs them, and leaving them out keeps the
# image and the run short.
#
# Exit: store to TOHOST. 1 = pass, (check << 1) | 1 = that check failed.

#define TOHOST  0x80000700
#define SCRATCH 0x80000600
#define UART    0x40000000
#define ACCEL   0x40001000

  .section .text
  .globl _start
_start:
  # ---- 1 ALU and branches
  li    t0, 0x12345678
  li    t1, 0x0000FFFF
  and   t2, t0, t1
  li    t3, 0x00005678
  bne   t2, t3, fail1
  add   t2, t0, t1
  li    t3, 0x12355677
  bne   t2, t3, fail1
  sub   t2, t0, t1
  li    t3, 0x12335679
  bne   t2, t3, fail1
  slli  t2, t1, 4
  li    t3, 0x000FFFF0
  bne   t2, t3, fail1
  srai  t2, t0, 8
  li    t3, 0x00123456
  bne   t2, t3, fail1
  sltu  t2, t1, t0
  li    t3, 1
  bne   t2, t3, fail1

  # ---- 2 memory through the data port
  li    a0, SCRATCH
  li    a1, 0xDEADBEEF
  sw    a1, 0(a0)
  lw    a2, 0(a0)
  bne   a2, a1, fail2
  li    a1, 0x5A
  sb    a1, 4(a0)
  lbu   a2, 4(a0)
  bne   a2, a1, fail2

  # ---- 3 APB slave 0: UART DIV
  li    a0, UART
  li    a1, 16
  sw    a1, 16(a0)
  lw    a2, 16(a0)
  bne   a2, a1, fail3

  # ---- 4 APB slave 1: accelerator PARAMS
  li    a0, ACCEL
  lw    a2, 8(a0)
  li    a3, 0x2004
  bne   a2, a3, fail4

  # ---- 5 fetch redirects: a taken branch forward and a jal
  li    t0, 1
  beqz  t0, fail5
  jal   ra, subr
  li    t3, 0xABC
  bne   a4, t3, fail5

  # ---- pass
  li    t0, 1
  j     finish

subr:
  li    a4, 0xABC
  jr    ra

fail1:
  li    t0, (1 << 1) | 1
  j     finish
fail2:
  li    t0, (2 << 1) | 1
  j     finish
fail3:
  li    t0, (3 << 1) | 1
  j     finish
fail4:
  li    t0, (4 << 1) | 1
  j     finish
fail5:
  li    t0, (5 << 1) | 1

finish:
  li    t1, TOHOST
  sw    t0, 0(t1)
1:
  j     1b
