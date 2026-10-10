# ORFS config for the SoC. Carried over from matmul-accel-asic: the don't-use
# cell list and the 20% repair margins are SKY130HD findings, not design-specific.
# OpenROAD-flow-scripts design config (SKY130HD)
# Invoked from the repo Makefile, which sets REPO_ROOT.
export DESIGN_NAME     = soc_top
export DESIGN_NICKNAME = soc_top
export PLATFORM        = sky130hd

export VERILOG_FILES   = $(sort $(wildcard $(REPO_ROOT)/rtl/*/*.sv) $(wildcard $(REPO_ROOT)/rtl/*.sv))
export SDC_FILE        = $(REPO_ROOT)/flow/constraint.sdc

# Architecture knobs (overridable: make asic MM_N=2 MM_DW=16)
MM_N  ?= 4
MM_DW ?= 32
SPLIT_MUL ?= 0

# Memory: 2 x sky130_sram_2kbyte_1rw1r_32x512_8 = 1024 words = 4 KB.
# Flop RAM measured ~37k generic cells per KB in Yosys, so 4 KB of flops would
# be larger than the rest of the SoC put together. Set MEM_SRAM=0 to build the
# flop variant instead (keep MEM_WORDS small if you do).
MEM_WORDS ?= 1024
MEM_SRAM  ?= 1
export VERILOG_TOP_PARAMS = N $(MM_N) DW $(MM_DW) SPLIT_MUL $(SPLIT_MUL) \
                            MEM_WORDS $(MEM_WORDS) USE_SRAM $(MEM_SRAM)

# The macro's views come from the volare PDK, which scripts/orfs.sh mounts at
# /pdk (the ORFS image's sky130hd platform ships no SRAM macros). Only a TT
# liberty exists for this macro -- see docs/implementation.md on multi-corner STA.
SRAM_MACRO = sky130_sram_2kbyte_1rw1r_32x512_8
SRAM_REF   = /pdk/sky130A/libs.ref/sky130_sram_macros
ifeq ($(MEM_SRAM),1)
export ADDITIONAL_LEFS += $(SRAM_REF)/lef/$(SRAM_MACRO).lef
export ADDITIONAL_LIBS += $(SRAM_REF)/lib/$(SRAM_MACRO)_TT_1p8V_25C.lib
export ADDITIONAL_GDS  += $(SRAM_REF)/gds/$(SRAM_MACRO).gds
# keep standard cells and routing off the macros
export MACRO_PLACE_HALO    ?= 40 40
export MACRO_PLACE_CHANNEL ?= 80 80
# platform PDN plus the macros' vccd1/vssd1 supplies -- see flow/pdn.tcl
export PDN_TCL = $(REPO_ROOT)/flow/pdn.tcl
endif

# Optional multi-corner analysis and optimization: MULTI_CORNER=1.
#
# OFF by default, and that is deliberate rather than a limitation. ORFS does
# support corners (CORNERS + <CORNER>_LIB_FILES, all stages); it is the sky130hd
# platform's default config that is tt-only. Turning this on re-maps the whole
# design, so every published number -- the sweep, the sign-off run, the
# clock-gating A/B -- comes from the single-corner setup and would have to be
# re-run before any multi-corner number could sit beside it.
#
# The macro is characterized at TT only, so it is read at TT in all three
# corners: standard cells move, the macro does not. That approximation is the
# same one the post-route STA reports record.
SC_LIB_DIR  = /OpenROAD-flow-scripts/flow/platforms/sky130hd/lib
PDK_SC_LIB  = /pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib
ifeq ($(MEM_SRAM),1)
  CORNER_SRAM_LIB = $(SRAM_REF)/lib/$(SRAM_MACRO)_TT_1p8V_25C.lib
else
  CORNER_SRAM_LIB =
endif
ifeq ($(MULTI_CORNER),1)
export CORNERS      = tt ss ff
export TT_LIB_FILES = $(SC_LIB_DIR)/sky130_fd_sc_hd__tt_025C_1v80.lib $(CORNER_SRAM_LIB)
export SS_LIB_FILES = $(PDK_SC_LIB)/sky130_fd_sc_hd__ss_100C_1v60.lib $(CORNER_SRAM_LIB)
export FF_LIB_FILES = $(PDK_SC_LIB)/sky130_fd_sc_hd__ff_n40C_1v95.lib $(CORNER_SRAM_LIB)
endif

# Timing knob, read by constraint.sdc
export CLOCK_PERIOD ?= 15.0   # the core, not the accelerator, will set this

# Floorplan / placement knobs
export CORE_UTILIZATION ?= 35
export PLACE_DENSITY    ?= 0.60
export TNS_END_PERCENT  = 100

# Cells from the PDK's libs.tech/openlane/sky130_fd_sc_hd/drc_exclude.cells list.
# a2111oi_0 and buf_16 each failed Magic DRC (licon.8a) inside the cell on matmul-accel-asic;
# the rest of the list is excluded pre-emptively. o21ai_0, a21boi_0, and2_0, o311ai_0
# are on that list too but passed Magic's full deck and stay allowed.
export DONT_USE_CELLS += sky130_fd_sc_hd__a2111oi_0 sky130_fd_sc_hd__buf_16 \
  sky130_fd_sc_hd__clkdlybuf4s15_1 sky130_fd_sc_hd__clkdlybuf4s18_1 \
  sky130_fd_sc_hd__fa_4 sky130_fd_sc_hd__mux4_4 sky130_fd_sc_hd__or2_0 \
  sky130_fd_sc_hd__xor3_1 sky130_fd_sc_hd__xor3_2 sky130_fd_sc_hd__xor3_4 \
  sky130_fd_sc_hd__xnor3_1 sky130_fd_sc_hd__xnor3_2 sky130_fd_sc_hd__xnor3_4

# Pre-route repair_design works on global-route estimates; antenna jumpers and detailed-route
# detours push a few long two-pin nets just past max-slew/max-cap. 20 % margin absorbs that
# (matmul-accel-asic base: 2 violating nets -> 0, WNS +0.20 ns, area +0.01 %).
export SLEW_MARGIN = 20
export CAP_MARGIN  = 20
