# fence_i.S — fence.i must make a store to nearby code visible to the next fetches.
#
# Each check overwrites the instruction `pad` slots after a fence.i with
# `addi a0, x0, 1` and falls through into it. The original there is `addi a0, x0, 2`.
# Zifencei: fetches after fence.i observe every earlier store, so a0 must be 1.
#
#  1-4  pad = 0, 1, 2, 3   (inside the fetch front-end's read-ahead window)
#  5    pad = 6            (outside it: a control that a read-ahead bug would not affect)
#
# rv32i_fetch.sv reads ahead (two reads in flight, a 3-entry queue), so fence.i must
# flush the front-end, or checks 1-3 would run the stale instruction. riscv-tests'
# fence_i writes code far from the fetch point and jumps to it, which a redirect
# already flushes, so it cannot see this case. rv32i_core.sv makes fence.i redirect,
# or replay when a store is still in MEM.
#include "test.h"

  TEST_START

  lw    s1, patched              # the replacement instruction word

#define CASE(n, pad)                 \
  la    t0, 1f;                      \
  li    a0, 0;                       \
  sw    s1, 0(t0);                   \
  fence.i;                           \
  .rept pad; nop; .endr;             \
1:                                   \
  addi  a0, x0, 2;                   \
  CHECK_EQ(n, a0, 1)

  CASE(1, 0)
  CASE(2, 1)
  CASE(3, 2)
  CASE(4, 3)
  CASE(5, 6)
  PASS

trap_entry:                      # no trap is expected
  FAIL(99)

  .data
  .align 2
patched: addi a0, x0, 1          # assembled as data, copied over code above

  TOHOST_SECTION
