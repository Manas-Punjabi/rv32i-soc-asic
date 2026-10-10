/* link.ld — directed tests: code at the reset vector, tohost at +0x1000, data after. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text   : { *(.text) }
  . = 0x80001000;
  .tohost : { *(.tohost) }
  . = 0x80002000;
  .data   : { *(.data) }
  .bss    : { *(.bss) }
}
