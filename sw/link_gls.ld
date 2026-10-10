/* link_gls.ld — image for post-layout gate-level simulation.
 *
 * The base build has 1024 words (4 KB) of RAM as two 512-word macro banks, and
 * soc_top aliases the RAM across the whole 0x8xxx_xxxx window. The ordinary
 * scripts put .tohost at 0x8000_1000, which is offset 4 KB and therefore aliases
 * straight back onto offset 0 -- on top of the reset vector.
 *
 * So everything here lives in the first 2 KB: code from 0x8000_0000, a scratch
 * word at 0x8000_0600 and tohost at 0x8000_0700. That is bank 0 only, which is
 * also why run_gls.sh needs to preload just one bank.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 2K
}

SECTIONS
{
  .text 0x80000000 : { *(.text) } > RAM
  .tohost 0x80000700 : { PROVIDE(tohost = .); . += 8; } > RAM
}
