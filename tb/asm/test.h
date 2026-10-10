/* test.h — minimal bare-metal harness for the directed tests in tb/asm.
 *
 * A test ends by storing to `tohost` (placed at 0x80001000 by link.ld, where
 * tb_core watches): 1 = pass, (n << 1) | 1 = failed check n.
 * The testbench's interrupt register is at 0x80001010: bits [2:0] = {ext, timer, soft}.
 */
#define IRQ_REG   0x80001010
#define TOHOST    0x80001000

#define TEST_START            \
  .section .text;             \
  .globl _start;              \
_start:                       \
  la t0, trap_entry;          \
  csrw mtvec, t0

/* the spin loops use `j .` so the macros define no local labels a test could
 * accidentally branch to with 1f/1b */
#define PASS                  \
  li t0, 1;                   \
  li t1, TOHOST;              \
  sw t0, 0(t1);               \
  j .

/* fail with check number n; clobbers t0/t1 */
#define FAIL(n)               \
  li t0, ((n) << 1) | 1;      \
  li t1, TOHOST;              \
  sw t0, 0(t1);               \
  j .

#define CHECK_EQ(n, reg, val) \
  li t6, val;                 \
  beq reg, t6, 9f;            \
  FAIL(n);                    \
9:

/* own section, 64-byte aligned: the same convention Spike's HTIF uses, so one
 * binary terminates on the ISS and on RTL */
#define TOHOST_SECTION        \
  .section .tohost, "aw";     \
  .align 6;                   \
  .globl tohost;              \
tohost: .word 0;              \
  .word 0
