# Verification

Every check has a command and a result. `make verify` runs the RTL-level ones (lint, the
memory-model comparison, the peripheral testbenches, the ISA tests on the core and on the SoC,
and the firmware benchmark) in about two minutes, and stops with a non-zero exit status at the
first failure. The rest need longer runs or the physical flow.

| Check | Command | Result |
|---|---|---|
| Lint, every block with and without the RVFI trace | `make lint` | Verilator 5.020 `-Wall`, clean |
| Flop vs SRAM memory model, cycle by cycle | `make sim-mem` | 6,195 checks pass |
| Peripheral testbenches | `make sim-periph` | 554 checks: accelerator wrapper 175, UART 299, timer 54, GPIO 26 |
| ISA tests on the core, always-ready and with random data-port stalls | `make sim-core` | 57 / 57 in both modes |
| ISA tests on the whole SoC | `make sim-soc` | 57 / 57 |
| Firmware benchmark, both paths agree | `make bench` | identical results element by element; 10.7× |
| Mutation testing | `make mutate-core`, `make mutate-periph`, `make mutate-cdc` | 28 / 28 core, 12 / 12 peripheral, 6 / 6 synchronizer bugs caught |
| Clock-domain crossings, structural | `make cdc` | 9 asynchronous inputs synchronized, reset synchronizer verified |
| Logic equivalence, RTL vs netlist, per module | `make lec` | 12 of 14 proven, 0 not equivalent |
| Post-layout simulation | `make gls`, `make gls-sdf` | functional pass; with delays, pass at 15 and 8 ns, fail at 5 ns as a control |
| Lockstep co-simulation | [rv32i-soc-validation](https://github.com/Manas-Punjabi/rv32i-soc-validation) | every retired instruction matches a Spike-validated reference model over 319 programs |

The ISA tests need `riscv64-unknown-elf-gcc` (Ubuntu's `gcc-riscv64-unknown-elf` 13.2, which
has the `rv32i/ilp32` multilib) and a clone of `riscv-software-src/riscv-tests` with its `env`
submodule at `$RISCV_TESTS` (default `~/src/riscv-tests`). The suites are run against the
design, never copied into this repository. The memory-model comparison needs the SKY130 PDK's
SRAM model. GitHub Actions runs everything in `make verify` except that comparison on every
push.

## ISA tests

`scripts/run_isa_tests.sh` builds each program with GCC 13.2
(`-march=rv32i_zicsr_zifencei`), riscv-tests' own `p` environment, and reads `tohost` from
each ELF. riscv-tests is the suite Spike and Rocket use; it is self-checking and needs only
GCC. (riscv-arch-test's current framework generates its reference signatures with the Sail
model and needs GCC 15, which Ubuntu 24.04 does not ship.)

| Suite | Count | What it checks |
|---|---|---|
| riscv-tests `rv32ui` | 41 | every base instruction, with 0/1/2-nop bypass variants, `fence.i`, load/store ordering |
| riscv-tests `rv32mi` | 14 | CSR instructions, illegal instruction, `ecall`, `ebreak`, misaligned load/store/fetch traps, `mepc`/`mcause`, counters |
| `tb/asm/irq.S` | 1 (15 checks, 6 traps) | interrupts: masked by `mstatus.MIE`, masked per source by `mie`, `mcause` and `mstatus` inside the handler, restore on `mret`, priority external > software > timer, exact `mepc` in a loop |
| `tb/asm/fence_i.S` | 1 (5 checks) | a store to code just ahead of the fetch point is visible after `fence.i`, inside and outside the front-end's read-ahead window |
| `tb/asm_soc/soc_smoke.S` | 1, SoC only | every peripheral through the core's data port and the APB bridge (see below) |

Excluded, with the reason: `rv32ui/ma_data` needs hardware misaligned access (this core traps,
and `rv32mi/ma_addr` verifies the trap fires); `rv32mi/breakpoint` needs trigger CSRs;
`rv32mi/pmpaddr` needs PMP. On the SoC, `irq.S` is also excluded because it drives the core's
interrupt pins directly; `soc_smoke.S` takes a real timer interrupt instead.

**Random stalls.** `make sim-core` runs every program twice: once with an always-ready data
port and once (`+stall`) with the port's `ready` dropped at random. The stall mode is what
exercises the pipeline freeze: a mutant that lets MEM/WB advance during a stall passes every
plain run and is killed only by it.

**RVFI trace.** `tb_core` and `tb_soc` check the retirement trace on every program: `order`
contiguous from 0, x0 never written with a value, each record's `pc_wdata` equal to the next
record's `pc_rdata` (one discontinuity allowed per taken interrupt), and no side effects on
trapped records.

**SoC smoke test.** `soc_smoke.S` exercises GPIO out and in through a loopback plus SET/CLR, a
non-existent APB slave and an address hole (both return 0 without hanging), a timer interrupt
taken through `mtimecmp`, a UART byte looped back, `"OK\n"` printed and compared against
`soc_smoke.expect`, and a 4×4 multiply on the accelerator.

## Peripheral testbenches

`tb/tb_apb_*.sv`, sharing `tb/apb_tasks.svh`.

| Testbench | Tests | Checks | What is notable |
|---|---|---|---|
| `tb_apb_accel` | A0–A8 | 175 | reset state; PARAMS; load, start, poll and read against a reference model; sticky `done`; back-to-back runs without reloading; writes ignored while busy; `PSLVERR` on an unmapped slave, a misaligned access and an out-of-range index |
| `tb_apb_uart` | U0–U12 | 299 | bit-level reference receiver on `tx_o`; asynchronous reference transmitter on `rx_i` with ±2 % baud error and random phase; back-to-back bytes with no gap; overrun keeps the first byte; framing error; glitch rejection; interrupt gating; full loopback |
| `tb_apb_timer` | T0–T7 | 54 | rate against elapsed cycles; interrupt rises exactly at `mtime == mtimecmp`; 64-bit compare where HI and LO disagree; the race-free update sequence never glitches the interrupt |
| `tb_apb_gpio` | G0–G5 | 26 | SET/CLR bitwise, including clearing a bit already 0; synchronizer latency exactly 2; mid-cycle input change |

## Mutation testing

Each mutant is one deliberate bug injected into a copy of the RTL; the suite must fail. This
measures whether the tests detect defects, not merely whether they pass.

- **Core, 28 / 28** (`scripts/mutate_core.sh`): forwarding removed (MEM→EX, WB→EX, register-file
  bypass), load-use stall removed, `bge` as `blt`, `jalr` keeping bit 0, half-word misaligned
  check dropped, `mret` not restoring MIE, interrupt priority swapped, a trapping instruction
  writing rd, `sra` as `srl`, `sb` byte lane stuck, `lb` zero-extending, `dmem_ready` ignored,
  MEM/WB advancing during a stall, `csrrc` as `csrrs`, illegal-instruction trap removed; RVFI
  trace faults (wrong `pc_wdata`, x0 with a value, bubbles reported); in the fetch front-end,
  the issue credit, the queue and stage-2 flush on redirect, the beat's PC, a beat dropped on a
  stall and a stale redirect address; and `fence.i` without its flush, or with the flush but
  without the replay.
- **Peripherals, 12 / 12** (`scripts/mutate_periph.sh`): start-bit recheck removed, overrun
  keeping the new byte, stop bit missing, sampling at the bit edge, second TX byte dropped,
  interrupt enables ignored, `>` for `>=`, LO-only compare, `mtimecmp` resetting to 0,
  one-flop synchronizer, CLR as XOR, `PSLVERR` removed.
- **Synchronizers, 6 / 6** (`scripts/mutate_cdc.sh`), below.

## Flop vs SRAM memory model

`tb/tb_soc_mem.sv` drives the flop build and the SRAM-macro build of `soc_mem` (with the PDK's
behavioural model) with the same stimulus and compares both against a reference: every word
written and read back on the data port, every word read on the fetch port at the macro's
N+2 timing, byte-enable writes, and back-to-back accesses that alternate between the two
macro banks. 6,195 checks.

`tb/timescale.v` must be the first file in any simulation that includes the PDK's SRAM model:
the model has no `` `timescale `` of its own, and under a coarse inherited one its internal
delay suspends the input register for the whole run, so the macro silently does nothing.

## Clock-domain crossings

The SoC has one clock domain, so the only crossings are the asynchronous input pins and the
asynchronous reset. `scripts/cdc_check.py` checks them on the flattened gate-level netlist.
For each asynchronous input it requires exactly one consumer and that consumer a flop (no logic
in front of the first stage), that flop driving exactly one cell, also a flop (no fan-out from
the metastable stage), and only the second flop's output reaching the rest of the design. For
the reset it requires that the raw pin reaches only the reset synchronizer's own flops.

```
uart_rx:    ok  2-flop synchronizer ($_DFF_PN1_ -> $_DFF_PN1_), synchronized value feeds 6 cell(s)
gpio_in[0..7]: ok  2-flop synchronizer ($_DFF_PN0_ -> $_DFF_PN0_), ...
rst_n:      reaches 2 cells (2 flops, 0 combinational)
            ok  raw reset reaches 2 flop reset pin(s): the reset synchronizer.
CDC: PASS
```

`scripts/mutate_cdc.sh` breaks the synchronizers six ways (second stage removed, logic in front
of stage 1, stage 1 read directly as well, each on a GPIO input and on the UART RX pin) and the
checker catches all six, each with its specific reason.

## Logic equivalence

`scripts/lec_check.sh` builds an explicit miter in Yosys and proves each module's elaborated
RTL equivalent to its synthesized netlist.

| Result | Modules |
|---|---|
| **Equivalent (12)** | `rv32i_core`, `rv32i_alu`, `rv32i_regfile`, `rv32i_decode`, `rv32i_csr`, `rv32i_fetch`, `mm_accel`, `apb_mm_accel`, `apb_fabric`, `apb_master`, `apb_timer`, `apb_gpio` |
| **Unproven (2)** | `mm_pe`, `apb_uart` |
| **Not equivalent (0)** | — |

The whole core proves in 6 seconds. The two unproven modules are prover limits, not
mismatches: the script reports the two cases separately, and neither log contains a
counterexample.

- **`mm_pe`** holds N parallel DW×DW multipliers, and multiplier equivalence by SAT grows
  exponentially with operand width. `scripts/lec_mmpe_widths.sh` sweeps the width:

  | DW | 2 | 4 | 8 | 16 | 32 |
  |---|---|---|---|---|---|
  | | proven (0 s) | proven (0 s) | proven (15 s) | timeout | timeout |

  The same RTL proves at DW ≤ 8, and `mm_accel`, which instantiates four of these, proves at
  its own level in 43 s.
- **`apb_uart`**: induction closes on 109 of 140 cells. The remaining 31 are the receive
  bit-timing state, all gated by `rx_cnt == div_q - 1` where `div_q` is a programmable 16-bit
  register; the invariant relating the counter to the register is not inductive at any bounded
  depth (raising the depth from 20 to 60 changed nothing).

Both are covered elsewhere: `mm_pe` by the accelerator's own sign-off and the 175 APB checks,
`apb_uart` by 299 checks against a bit-level reference model and 6 mutants, and both by
post-layout simulation.

Two method notes: memories must be mapped to flops on both sides (`memory`, not
`memory -nomap`), or the register file's read ports have no counterpart in the synthesized mux
tree; and `setundef -undriven -zero` is needed afterwards, because `memory_map` leaves the
read-mux bits for x0 undriven.

## Post-layout simulation

`bash scripts/run_gls.sh base [--sdf] [--period NS]` runs `tb/asm_gls/gls_smoke.S` on the
routed netlist with the SKY130 cell models and the PDK's behavioural model for the SRAM macros.

| Run | Result |
|---|---|
| functional (cell models without delays) | pass, 90 cycles (RTL: 88) |
| with SDF delays, 15 ns (the sign-off period) | pass, 90 cycles |
| with SDF delays, 8 ns | pass |
| with SDF delays, 5 ns | fail (timeout) |
| with SDF delays, 3 ns | fail (timeout) |

A gate-level netlist has no memory array to load a program into, but the SRAM macro's
behavioural model does, so the image is loaded straight into bank 0. `sw/link_gls.ld` keeps the
whole program inside the first 2 KB, which also avoids the 4 KB RAM's address aliasing putting
`.tohost` on top of the reset vector.

**What this establishes, and what it does not.** Delays are applied: the same image passes at
15 and 8 ns and fails at 5 and 3 ns. But the 8 ns run passes although static timing puts the
minimum period at 13.28 ns: Icarus implements no timing checks (setup, hold, recovery and width
are not verified here; static timing analysis is the authority), and a program this small does
not exercise the worst path, which runs from branch resolution to the SRAM address inputs.
Post-layout simulation confirms that the routed netlist functions with real delays; it is not
evidence for Fmax.

Running delays through Icarus needs three adaptations, applied by the script: a patched cell
library (`scripts/sky130_icarus_sdf_lib.py`: `_delayed` wires tied through, specify paths made
level-sensitive), de-dotted instance names in the netlist and SDF (`scripts/sdf_dedot.py`), and
`iverilog -Tmax`. The `FUNCTIONAL` macro must not be defined on a delay run: every cell model is
`` `ifdef FUNCTIONAL `` zero-delay `` `else `` timing, so defining it removes the specify blocks
and the SDF silently attaches to nothing. The must-fail control at 5 ns is what catches that.
