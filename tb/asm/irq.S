# irq.S — machine-mode interrupt behaviour that the ISA suites do not cover.
#
#  1  a pending interrupt is ignored while mstatus.MIE = 0
#  2  taking it: mcause, mstatus.MIE/MPIE inside the handler, restore on mret
#  3  mie masks each source individually
#  4  priority when all three are pending: external, then software, then timer
#  5  mepc is exact: a loop interrupted mid-way still produces the right sum
#
# The handler logs mcause, clears the line it is servicing and returns. It uses
# only s3..s7, which main never touches, so it can interrupt main anywhere.
#include "test.h"

  TEST_START

  li   s1, 0              # s1 = trap count
  li   s2, IRQ_REG
  la   s0, log

  # ---- 1: MIE = 0, timer pending: no trap
  csrw mstatus, zero
  li   t0, 0x80           # mie.MTIE
  csrw mie, t0
  li   t0, 2              # raise timer
  sw   t0, 0(s2)
  nop; nop; nop; nop
  CHECK_EQ(1, s1, 0)
  csrr t0, mip
  CHECK_EQ(2, t0, 0x80)   # visible in mip even while masked
  sw   zero, 0(s2)

  # ---- 2: enable and take it
  li   t0, 2
  sw   t0, 0(s2)          # raise timer first, then enable
  li   t0, 0x8            # mstatus.MIE
  csrs mstatus, t0
  nop; nop; nop; nop
  CHECK_EQ(3, s1, 1)
  lw   t0, 0(s0)
  CHECK_EQ(4, t0, 0x80000007)
  la   t1, mst
  lw   t0, 0(t1)          # mstatus inside the handler: MIE=0, MPIE=1, MPP=11
  CHECK_EQ(5, t0, 0x1880)
  csrr t0, mstatus        # after mret: MIE restored, MPIE=1
  CHECK_EQ(6, t0, 0x1888)

  # ---- 3: mie masking: only MTIE enabled; ext and soft pending do nothing
  li   t0, 5              # ext + soft
  sw   t0, 0(s2)
  nop; nop; nop; nop
  CHECK_EQ(7, s1, 1)
  li   t0, 0x800          # add MEIE
  csrs mie, t0
  nop; nop; nop; nop
  CHECK_EQ(8, s1, 2)      # ext taken, soft still masked
  lw   t0, 4(s0)
  CHECK_EQ(9, t0, 0x8000000b)
  sw   zero, 0(s2)

  # ---- 4: priority with all enabled and all pending
  li   t0, 0x888          # MEIE | MTIE | MSIE
  csrw mie, t0
  li   t0, 7
  sw   t0, 0(s2)
  nop; nop; nop; nop; nop; nop; nop; nop
  CHECK_EQ(10, s1, 5)
  lw   t0, 8(s0)
  CHECK_EQ(11, t0, 0x8000000b)
  lw   t0, 12(s0)
  CHECK_EQ(12, t0, 0x80000003)
  lw   t0, 16(s0)
  CHECK_EQ(13, t0, 0x80000007)

  # ---- 5: interrupt in the middle of a loop; sum 1..100 must still be 5050
  li   a0, 0
  li   a1, 1
  li   a2, 101
loop:
  add  a0, a0, a1
  addi a1, a1, 1
  li   t0, 50
  bne  a1, t0, 1f
  li   t0, 2
  sw   t0, 0(s2)          # raise timer when a1 == 50
1:
  bne  a1, a2, loop
  CHECK_EQ(14, a0, 5050)
  CHECK_EQ(15, s1, 6)

  PASS

  .align 2
trap_entry:
  csrr s3, mcause
  la   s4, log
  slli s5, s1, 2
  add  s4, s4, s5
  sw   s3, 0(s4)          # log[count] = mcause
  csrr s4, mstatus
  la   s5, mst
  sw   s4, 0(s5)
  addi s1, s1, 1
  # clear the line for this cause: ext -> bit2, soft -> bit0, timer -> bit1
  lw   s6, 0(s2)
  li   s7, 0x8000000b
  bne  s3, s7, 2f
  andi s6, s6, 3
  j    3f
2:
  li   s7, 0x80000003
  bne  s3, s7, 4f
  andi s6, s6, 6
  j    3f
4:
  andi s6, s6, 5
3:
  sw   s6, 0(s2)
  mret

  .data
  .align 2
log: .fill 16, 4, 0
mst: .word 0

  TOHOST_SECTION
