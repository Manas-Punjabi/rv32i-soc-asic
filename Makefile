# rv32i-soc-asic
#   make verify        all RTL-level checks; stops with an error on the first failure
#   make lint          Verilator -Wall on every finished block
#   make sim-periph    APB testbenches: fabric+accelerator, UART, timer, GPIO
#   make sim-apb       just the fabric + accelerator wrapper testbench
#   make sim-core      riscv-tests rv32ui + rv32mi + tb/asm on the core, plain and with
#                      random data-port stalls, RVFI trace checked (needs
#                      riscv64-unknown-elf-gcc and RISCV_TESTS, default ~/src/riscv-tests)
#   make mutate-core   28 known bugs injected into the core, all must be caught (~8 min)
#   make mutate-periph 12 known bugs injected into the peripherals
#   make sim-soc       the same suites plus tb/asm_soc on soc_top (memory, bridge, peripherals)
#   make bench         build sw/ and run the matmul benchmark on soc_top
#   make cdc           structural CDC check on the synthesized netlist (+ mutate-cdc)
#   make lec           logical equivalence, RTL vs synthesized netlist, per module
#   make clock-gate    insert ICGs and report the cell/area delta   (needs Docker)
#   make dft           insert scan chains and report coverage       (needs Docker)
#   make sta           post-route STA at tt/ss/ff                   (needs Docker)
#   make drc / lvs     Magic sign-off DRC / Netgen LVS, SRAM macros held as abstracts
#   make gls / gls-sdf post-layout GLS, functional / SDF + must-fail control
#   make asic ...      ORFS RTL-to-GDSII                            (needs Docker)
REPO_ROOT := $(abspath .)
FLOW_VARIANT ?= base
# ORFS itself lives in the container, so there is no FLOW_HOME on this side;
# scripts/orfs.sh owns the invocation and mounts this as /orfs_work.
ORFS_WORK ?= $(HOME)/ASIC/rv32i-soc-asic-work
export REPO_ROOT ORFS_WORK

RTL_ACCEL = rtl/accel/mm_pe.sv rtl/accel/mm_accel.sv
RTL_BUS   = rtl/bus/apb_fabric.sv
RTL_PERIPH= rtl/periph/apb_mm_accel.sv
RTL_CORE  = $(wildcard rtl/core/*.sv)
RTL_SOC   = $(RTL_CORE) $(RTL_ACCEL) $(wildcard rtl/bus/*.sv) $(wildcard rtl/periph/*.sv) rtl/mem/soc_mem.sv rtl/soc_top.sv
PERIPHS   = apb_uart apb_timer apb_gpio

RUN = sky130hd/soc_top/$(FLOW_VARIANT)

# logic-only checks (clock-gate, dft); never forwarded to `make asic` (see ORFS_VARS)
MEM_WORDS ?= 2
.PHONY: verify lint sim-periph sim-apb sim-core mutate-core mutate-periph mutate-cdc \
        sim-soc sim-mem bench bench-check cdc lec clock-gate dft sta drc lvs gls gls-sdf \
        asic gui report sweep clean
verify: lint sim-mem sim-periph sim-core sim-soc bench-check
	@echo "== verify: all RTL-level checks passed =="

# the benchmark is also a functional check: both paths must agree element by element
bench-check:
	@mkdir -p build
	@bash scripts/build_fw.sh 2>&1 | grep -E "^(BENCH OK|FAIL)|^PASS" | head -2 | tee build/bench.out
	@grep -q "^BENCH OK" build/bench.out && grep -q "^PASS" build/bench.out

lint:
	@for n in 2 4 8; do \
	  verilator --lint-only -Wall $(RTL_PERIPH) $(RTL_ACCEL) --top-module apb_mm_accel -GN=$$n \
	    && echo "lint clean apb_mm_accel N=$$n" || exit 1; \
	done
	@verilator --lint-only -Wall $(RTL_BUS) --top-module apb_fabric && echo "lint clean apb_fabric"
	@for p in $(PERIPHS); do \
	  verilator --lint-only -Wall rtl/periph/$$p.sv --top-module $$p && echo "lint clean $$p" || exit 1; \
	done
	@verilator --lint-only -Wall $(RTL_CORE) --top-module rv32i_core && echo "lint clean rv32i_core"
	@verilator --lint-only -Wall -DRVFI $(RTL_CORE) --top-module rv32i_core && echo "lint clean rv32i_core RVFI"
	@verilator --lint-only -Wall $(RTL_SOC) --top-module soc_top && echo "lint clean soc_top"
	@verilator --lint-only -Wall -DRVFI $(RTL_SOC) --top-module soc_top && echo "lint clean soc_top RVFI"

sim-periph:
	@bash scripts/run_periph_tests.sh

# soc_mem built from flops vs from the SRAM macros, compared cycle for cycle.
# tb/timescale.v must come first: the PDK model carries no timescale of its own.
SRAM_V = $(HOME)/.volare/sky130A/libs.ref/sky130_sram_macros/verilog/sky130_sram_2kbyte_1rw1r_32x512_8.v
sim-mem:
	@mkdir -p build
	@iverilog -g2012 -s tb_soc_mem -o build/tb_soc_mem \
	  tb/timescale.v $(SRAM_V) rtl/mem/soc_mem.sv tb/tb_soc_mem.sv 2>/dev/null
	@vvp -n build/tb_soc_mem | grep -E "^PASS|^FAIL|^  FAIL" | tee build/sim_mem.out
	@grep -q "^PASS" build/sim_mem.out

# just the fabric + accelerator wrapper; the build recipe lives in one place
sim-apb:
	@bash scripts/run_periph_tests.sh accel

sim-core:
	@bash scripts/run_isa_tests.sh 2>&1 | grep -v "sorry:" | tail -1 | grep " 0 failed"
	@bash scripts/run_isa_tests.sh --stall 2>&1 | grep -v "sorry:" | tail -1 | grep " 0 failed"

mutate-core:
	@bash scripts/mutate_core.sh

mutate-periph:
	@bash scripts/mutate_periph.sh

sim-soc:
	@bash scripts/run_isa_tests.sh --soc 2>&1 | grep -v "sorry:" | tail -1 | grep " 0 failed"

bench:
	@bash scripts/build_fw.sh

# ---- front-end sign-off: CDC, LEC, clock gating, scan --------------------
# A wildcard, not a hand-written list: a hand-written list silently goes stale
# when a file is added (Yosys then fails with "Module ... is not part of the
# design" and every check below stops running). flow/config.mk globs too.
SYNTH_RTL = $(sort $(wildcard rtl/*/*.sv) $(wildcard rtl/*.sv))

build/fe/soc_top.json: $(SYNTH_RTL)
	@mkdir -p build/fe
	@yosys -p "read_verilog -sv -DSYNTHESIS $(SYNTH_RTL); chparam -set MEM_WORDS 256 soc_top; \
	  synth -top soc_top -flatten; write_json $@" > build/fe/synth.log 2>&1 || \
	  { tail -20 build/fe/synth.log; exit 1; }

cdc: build/fe/soc_top.json
	@python3 scripts/cdc_check.py $< --top soc_top \
	  --async-in uart_rx --async-in gpio_in --async-reset rst_n

mutate-cdc:
	@bash scripts/mutate_cdc.sh

lec:
	@bash scripts/lec_check.sh

# these two run Yosys 0.68 / OpenROAD inside the ORFS container: Docker must be up
clock-gate:
	@bash scripts/clock_gate.sh $(MEM_WORDS)

# post-route STA at tt/ss/ff on a completed flow variant
sta:
	@bash scripts/run_sta.sh $(FLOW_VARIANT)

# sign-off DRC and LVS, SRAM macros held as the PDK's abstract view
drc:
	@bash scripts/run_drc.sh $(FLOW_VARIANT)
lvs:
	@bash scripts/run_lvs.sh $(FLOW_VARIANT)

# post-layout GLS. `gls` is functional; `gls-sdf` back-annotates delays and
# also runs the must-fail control -- a delay-annotated run that passes at every
# period is not applying delays.
gls:
	@bash scripts/run_gls.sh $(FLOW_VARIANT)
gls-sdf:
	@bash scripts/run_gls.sh $(FLOW_VARIANT) --sdf --period 15
	@echo "control at 5 ns (must FAIL):"
	@rm -f build/gls/tb_gls_$(FLOW_VARIANT)_sdf
	@bash scripts/run_gls.sh $(FLOW_VARIANT) --sdf --period 5 2>&1 | tail -2

dft:
	@bash scripts/dft_scan.sh $(MEM_WORDS)

# ORFS runs in the container (scripts/orfs.sh: pinned image, --user, LEC_CHECK=0,
# PDK mounted at /pdk for the SRAM macro views)
# knobs are forwarded only when set on the command line or in the environment, so
# flow/config.mk keeps its own defaults. A defined-anywhere test is not enough:
# MEM_WORDS ?= 2 above (for the logic-only clock-gate/dft checks) must not reach
# the flow, or a bare `make asic FLOW_VARIANT=base` builds a 2-word RAM.
# INFER_CLKGATES=1 makes ORFS's own synth.tcl run Yosys `clockgate`, which gives
# clock gating a post-route power number: same flow setup, same period, gating
# the only difference.
ORFS_VARS = CLOCK_PERIOD CORE_UTILIZATION PLACE_DENSITY MM_N MM_DW SPLIT_MUL \
            MEM_WORDS MEM_SRAM SYNTH_MEMORY_MAX_BITS INFER_CLKGATES MULTI_CORNER
asic:
	@bash scripts/orfs.sh --make FLOW_VARIANT=$(FLOW_VARIANT) \
	  $(foreach v,$(ORFS_VARS),$(if $(filter command environment,$(firstword $(origin $(v)))),$(v)=$($(v)),)) $(ORFS_ARGS)
gui:
	@bash scripts/orfs.sh --make FLOW_VARIANT=$(FLOW_VARIANT) gui_final
report:
	@python3 scripts/parse_reports.py --logs $(ORFS_WORK)/logs/$(RUN) \
	                                  --reports $(ORFS_WORK)/reports/$(RUN)
# PPA sweep across clock targets around the sign-off run's 13.28 ns minimum period.
# Results and how to read them: docs/implementation.md.
sweep:
	@python3 scripts/sweep.py --periods 12 13 15 20 --out results/sweep.csv
	@python3 scripts/plot_sweep.py results/sweep.csv docs/ppa_sweep.png
clean:
	rm -rf build
