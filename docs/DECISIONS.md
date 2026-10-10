# Design decisions

Every non-obvious choice in this SoC, with the reason it was made. Where a decision was
later overturned by a measurement, both the original reasoning and what replaced it are
kept — the correction is usually the more useful half.

## Bus and peripherals

| Decision | Reason |
|---|---|
| APB, not AXI-Lite | Both are single-transfer, so neither fixes the 96-bus-cycles-per-8-compute-cycles ratio that dominates the accelerator. APB costs far less RTL and verification. An AXI-Lite-to-APB bridge is the honest way to add the keyword later. |
| 4 KB per slave, decode on `PADDR[19:12]` | Simple, and leaves room for register growth. |
| Unmapped access returns `PSLVERR` in one cycle | A stray pointer in firmware must not hang the bus. |
| Peripherals return `PSLVERR` on unknown offsets | Catches firmware address bugs early. The accelerator wrapper keeps returning 0: already verified, and changing it would need re-verification for no gain. |
| `PSLVERR` dropped by the bridge; word-only peripheral registers | The core has no bus-error exception, and APB3 has no `PSTRB`. Both recorded as limitations rather than hidden. |
| Sticky `done` with write-1-to-clear | The accelerator's `done` is a one-cycle pulse that polled firmware would miss. |
| Matrix writes ignored while busy | Already enforced inside `mm_accel`; the wrapper does not fight it. |
| The accelerator's own RTL is unchanged from the project it came from | Its sign-off results stay valid, so the APB wrapper is the only new logic that needs verifying. |
| UART overrun keeps the old byte | 16550 behaviour: the byte the firmware was about to read is not silently replaced. |
| UART divides the system clock; no second clock domain | A separate baud clock would exist only to have a clock-domain crossing to show. The asynchronous inputs — UART RX and GPIO in — get 2-flop synchronizers, and that is the SoC's real CDC. |

## Core

| Decision | Reason |
|---|---|
| Machine-mode traps and interrupts from the start | The ISA suites cannot run without `mtvec`/`mepc`/`ecall`/illegal-instruction traps. About 150 lines of RTL, and it makes "machine mode only" a true statement rather than an aspiration. |
| RV32I + Zicsr + Zicntr rather than bare RV32I | The ISA suites and interrupts need Zicsr. A superset RTL does not break lockstep co-simulation with Spike run as `--isa=rv32i_zicsr_zicntr_zifencei`. |
| Misaligned data access traps rather than being split in hardware | Spec-legal, and the simpler pipeline. Costs `rv32ui/ma_data`, which is excluded with the reason stated; `rv32mi/ma_addr` verifies the trap actually fires. |
| Cycle and instruction counters in the core (Zicntr) | Cheap, and they give IPC in RTL-only runs. Deliberately unused on the co-simulated path. |
| Data port has a `ready`; the whole pipeline freezes on a stall, **including MEM/WB** | Needed for APB slaves. Letting WB retire during a stall lost forwarded operands — found by the `+stall` test mode, fixed, and pinned by a mutant so it cannot regress. |
| RVFI trace under `` `ifdef RVFI ``: exceptions reported, interrupt pre-emptions not | Matches riscv-formal's meaning of `rvfi_trap`. A pre-empted instruction never executed and is re-fetched, so reporting it would desync an instruction-set simulator. `mem_addr` is word-aligned with lane masks. |

## Memory, and the decision that was overturned

| Decision | Reason |
|---|---|
| One unified RAM, 1 read + 1 read/write port, instead of separate IMEM/DMEM | Spike-linked ELFs and riscv-tests run on the SoC unchanged, `fence.i` works, and the PDK's `sky130_sram_2kbyte_1rw1r_32x512_8` has exactly that port shape. |
| **Superseded:** instruction memory addressed by the next PC | That trick assumed a flop array whose read folds into the address cycle. A real synchronous SRAM latches the address instead and consumes a pipeline stage, so `rv32i_fetch.sv` now owns a decoupled front-end and a taken branch costs two bubbles. Changed after reading the macro's liberty and OpenRAM's read model, before the macro was wired in. |
| Fetch queue depth 3 with a credit rule | At most two beats can land after a stall begins. The queue covers the refill, so a stall costs no extra bubble on resume and no beat is ever dropped. |
| `soc_mem` models the macro's timing even when built from flops | One core is then verified against the timing it actually gets in silicon, and the flop and macro builds stay interchangeable. `tb_soc_mem.sv` compares them cycle for cycle over 6,195 checks. |
| Data port takes a wait state rather than changing the core | The existing `ready` handshake already absorbed it, and `+stall` was already exercising that path. |
| OpenRAM macros rather than flop-based RAM | Measured, not assumed: flop RAM costs roughly 37k generic cells per KB — 105,792 cells for the SoC with 1 KB against 69,175 with none. |

## Benchmarking

| Decision | Reason |
|---|---|
| Timed with the timer peripheral, not `rdcycle` | Lockstep co-simulation compares every instruction against an ISS. MMIO reads can be injected into the ISS; CSR counters cannot be made to agree. Firmware on the compared path never reads `cycle`/`instret`. |
| Firmware times with `mtime`, subtracts the timer-read overhead, averages 16 runs | Co-simulation-safe, and keeps measurement overhead from distorting a 13-cycle compute-and-poll phase. |
| The software baseline is reported as "no M extension, `__mulsi3`" | The 10.7x speedup is against software multiplication. Quoting it bare would flatter the accelerator: a core with `mul` would close much of the gap — and would leave the 97.2 % bus share untouched, which is the real finding. |
| Polling timed as its own phase, not folded into compute | Polling `STATUS` is bus traffic. Hiding it inside "compute" would understate data movement, which is the thing the benchmark exists to expose. |

## Verification

| Decision | Reason |
|---|---|
| `riscv-tests` rather than `riscv-arch-test` | ACT4 needs GCC 15, Ruby/UDB, `uv` and the Sail model just to generate expected results. riscv-tests is self-checking and needs only GCC. Both are BSD-licensed and are run against the core, never copied into this repo. |
| CDC proven by a structural check on the netlist, not a written review | A review is an assertion; a checker with 6 deliberately broken synchronizers is evidence. It also survives future RTL edits, which a review does not. |
| LEC reports "unproven" separately from "not equivalent" | Induction failing to close is a prover limit; a counterexample is a bug. Collapsing the two would either hide a bug behind a timeout or cry wolf over a known SAT limitation. |
| `mm_pe` and `apb_uart` left unproven rather than worked around | Both characterized — a multiplier width sweep, and a counter-versus-programmable-register invariant that is not inductive — and both covered at other verification levels. Forcing a "pass" would be dishonest. |
| Front-end file lists glob the RTL tree instead of being written out by hand | A hand-written list silently went stale when `rtl/core/rv32i_fetch.sv` was added, and the CDC, LEC, clock-gating and DFT targets all stopped running. The physical flow config had always globbed and was unaffected. |

## Physical implementation

| Decision | Reason |
|---|---|
| Flow configuration and scripts carried over unchanged from the matrix-accelerator project | The don't-use cell list and the 20 % repair margins are SKY130HD-wide findings, not design-specific ones. |
| Clock gating applied **before** scan insertion | `sky130_fd_sc_hd` has no scan+enable flop, so enable flops cannot be swapped for `sdf*` and drop out of the chains: 38 % coverage. Gating rewrites them as plain flops behind an ICG first, giving 100 %. Measured both ways. |
| Flops swapped to `sdf*` in Yosys, chains stitched in OpenROAD | OpenROAD's DFT stitches, it does not replace. Handed plain flops it reports "not a scan cell" and builds zero chains. `scripts/scan_swap.v` does the swap with `SCD`/`SCE` tied low. |
| Front-end gating and scan runs use a 2-word memory | Flop-based RAM would dominate the flop counts and the gating and scan totals, and it disappears once the SRAM macro lands. The logic-only numbers are the ones that carry forward. |
| Every clock-gating and DFT artefact is tagged with its mode in the filename | An ungated run overwrote a gated run's statistics once and the two then got compared against each other. Tagged filenames make that mistake impossible rather than merely unlikely. |
| The SRAM macro is held as the PDK's `maglef` abstract for sign-off DRC and LVS | The open DRC deck is not valid inside a sky130 bitcell array: the macro's own GDS reports 5,579,161 errors with nothing of this project in it, and the dominant rule carries foundry waivers the deck does not model. Checking the interior measures the vendor's IP. The abstract has 131 ports, pin metal and no device layers, so the check covers exactly this project's paint. |
| Vendor timing data is not edited to unblock multi-corner optimization | The macro's liberty demands a 0.04 ns input slew that no cell in the library can drive, which aborts the resizer. An SDC statement cannot relax it — timing analysis takes the most restrictive of the library and SDC values, measured with a control. Only editing the liberty would work, and that falsifies characterization data for every downstream consumer. Multi-corner analysis is reported instead, failing corners included. |
| The scan-inserted physical variant is reported as its own pair, never beside the sign-off run | The flow has no DFT support, so the scan netlist must be synthesized outside it and injected. That synthesis is not the flow's own, and produces roughly 29 % more cells, which needs a looser floorplan to route. The scan-versus-no-scan delta is valid; the absolute numbers are not comparable to the sign-off setup. |
| One flow setup per set of numbers | Changing the don't-use list, repair margins, utilization or corner setup re-maps the whole design. Mixing numbers from two setups produces a table that is individually true and collectively meaningless. |
