# soc_smoke.S — every peripheral reached through the core's data port and the APB
# bridge, on soc_top. Runs on tb_soc (uart_rx and gpio_in are looped back there).
#
#  1  GPIO: OUT drives the pins, IN reads them back through the synchronizer; SET/CLR
#  2  unmapped addresses: an APB slave that does not exist and a hole outside RAM/APB
#     both return 0 and do not hang
#  3  timer: mtime advances; mtimecmp raises a machine timer interrupt that is taken
#  4  UART: a byte ('Z') is sent and received back (loopback); then "OK\n" is printed.
#     tb_soc's monitor sees the whole line, "ZOK\n", and checks it (soc_smoke.expect)
#  5  accelerator: PARAMS, a 4x4 multiply of all-ones by all-twos, three results
#include "test.h"

#define UART      0x40000000
#define ACCEL     0x40001000
#define TIMER     0x40002000
#define GPIO      0x40003000
#define NOSLAVE   0x40005000
#define HOLE      0x10000000

  TEST_START
  li   s1, 0                  # trap count

  # ---- 1 GPIO
  li   s2, GPIO
  li   t0, 0xA5
  sw   t0, 0(s2)              # OUT
  nop; nop; nop; nop
  lw   t1, 4(s2)              # IN (looped back, 2-flop synchronizer)
  CHECK_EQ(1, t1, 0xA5)
  li   t0, 0x18
  sw   t0, 8(s2)              # SET
  lw   t1, 0(s2)
  CHECK_EQ(2, t1, 0xBD)
  li   t0, 0xC1
  sw   t0, 12(s2)             # CLR
  lw   t1, 0(s2)
  CHECK_EQ(3, t1, 0x3C)

  # ---- 2 unmapped
  li   t0, NOSLAVE
  lw   t1, 0(t0)
  CHECK_EQ(4, t1, 0)
  sw   t1, 0(t0)
  li   t0, HOLE
  lw   t1, 0(t0)
  CHECK_EQ(5, t1, 0)
  sw   t1, 0(t0)
  lw   t1, 0(s2)              # GPIO still intact after the stray accesses
  CHECK_EQ(6, t1, 0x3C)

  # ---- 3 timer
  li   s3, TIMER
  lw   t0, 0(s3)              # MTIME_LO
  lw   t1, 0(s3)
  bltu t0, t1, 1f
  FAIL(7)
1:
  addi t2, t1, 300            # compare = now + 300
  li   t0, -1
  sw   t0, 12(s3)             # MTIMECMP_HI = all ones
  sw   t2, 8(s3)              # MTIMECMP_LO
  sw   zero, 12(s3)           # MTIMECMP_HI = 0
  li   t0, 0x80
  csrw mie, t0                # MTIE
  csrsi mstatus, 0x8          # MIE
  li   t3, 100000
2:
  addi t3, t3, -1
  beqz t3, 3f
  beqz s1, 2b
3:
  csrci mstatus, 0x8
  CHECK_EQ(8, s1, 1)
  la   t0, log
  lw   t1, 0(t0)
  CHECK_EQ(9, t1, 0x80000007)

  # ---- 4 UART
  li   s4, UART
  li   t0, 16
  sw   t0, 16(s4)             # DIV = 16 (tb decodes at 16)
  li   t0, 0x5A
  sw   t0, 0(s4)              # TXDATA
4:
  lw   t1, 8(s4)              # STATUS
  andi t1, t1, 0x4            # rx_valid
  beqz t1, 4b
  lw   t1, 4(s4)              # RXDATA
  CHECK_EQ(10, t1, 0x5A)
  la   t4, msg
5:
  lbu  t0, 0(t4)
  beqz t0, 7f
6:
  lw   t1, 8(s4)
  andi t1, t1, 0x1            # tx_ready
  beqz t1, 6b
  sw   t0, 0(s4)
  addi t4, t4, 1
  j    5b
7:
  lw   t1, 8(s4)
  andi t1, t1, 0x2            # tx_idle
  beqz t1, 7b
  li   t0, 0x18
  sw   t0, 8(s4)              # clear overrun/frame from the echoed message
8:
  lw   t1, 8(s4)
  andi t1, t1, 0x4
  beqz t1, 9f
  lw   t1, 4(s4)              # drain the echoed bytes
  j    8b
9:

  # ---- 5 accelerator
  li   s5, ACCEL
  lw   t1, 8(s5)              # PARAMS
  CHECK_EQ(11, t1, 0x2004)
  li   s8, ACCEL + 0x400      # A window (offsets >= 0x800 do not fit an S immediate)
  li   s9, ACCEL + 0x800      # B window
  li   s10, ACCEL + 0xC00     # C window
  li   t0, 1
  li   t1, 2
  li   t2, 0
10:
  slli t3, t2, 2
  add  t4, s8, t3
  sw   t0, 0(t4)              # A[i] = 1
  add  t4, s9, t3
  sw   t1, 0(t4)              # B[i] = 2
  addi t2, t2, 1
  li   t3, 16
  bne  t2, t3, 10b
  li   t0, 1
  sw   t0, 0(s5)              # CTRL.start
11:
  lw   t1, 4(s5)              # STATUS
  andi t1, t1, 0x2            # done
  beqz t1, 11b
  lw   t1, 0(s10)             # C[0]
  CHECK_EQ(12, t1, 8)
  lw   t1, 20(s10)            # C[5]
  CHECK_EQ(13, t1, 8)
  lw   t1, 60(s10)            # C[15]
  CHECK_EQ(14, t1, 8)
  li   t0, 2
  sw   t0, 4(s5)              # clear done

  PASS

  .align 2
trap_entry:
  csrr s6, mcause
  la   s7, log
  sw   s6, 0(s7)
  addi s1, s1, 1
  li   s6, TIMER
  li   s7, -1
  sw   s7, 12(s6)             # MTIMECMP_HI = all ones: clears the interrupt
  mret

  .data
  .align 2
log: .word 0
msg: .string "OK\n"

  TOHOST_SECTION
