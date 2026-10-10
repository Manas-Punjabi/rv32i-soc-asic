#!/usr/bin/env bash
# run_gls.sh — post-layout gate-level simulation of the routed netlist.
#
#   bash scripts/run_gls.sh [FLOW_VARIANT] [--sdf] [--period NS]
#       default: base, functional (unit delay), 10 ns
#
# Two modes, in the order matmul-accel-asic used them:
#
#   functional  -DFUNCTIONAL -DUNIT_DELAY="#1": proves the routed netlist is
#               functionally right, with no timing.
#   --sdf       IOPATH delays back-annotated from OpenSTA's write_sdf. Delays
#               only: Icarus implements no timing checks, so setup/hold/recovery
#               are NOT verified here (post-route STA covers those statically).
#
# THE THREE THINGS ICARUS NEEDS (all from matmul-accel-asic, all still needed)
#
#  1. A patched cell library. The stock models drive their UDPs from `X_delayed`
#     wires that only $setuphold would drive; Icarus leaves them undriven and
#     every flop outputs X. And their specify paths are edge-sensitive while
#     write_sdf emits edge-less IOPATHs, so clk->Q delay silently becomes zero.
#     scripts/sky130_icarus_sdf_lib.py fixes both.
#  2. De-dotted names. Icarus splits SDF instance names on '.' even inside an
#     escaped identifier, so netlist and SDF are rewritten together
#     (scripts/sdf_dedot.py). It is also what makes the testbench able to reach
#     into the macro's memory array.
#  3. `iverilog -Tmax`. OpenSTA writes SDF triples as min::max with typ empty.
#
# A control run at a period that must fail is included: a delay-annotated
# simulation that passes at every period is not actually applying delays.
set -u
cd "$(dirname "$0")/.."
VARIANT=base
SDF=0
PERIOD=10
while [[ $# -gt 0 ]]; do
  case $1 in
    --sdf) SDF=1;;
    --period) shift; PERIOD=$1;;
    *) VARIANT=$1;;
  esac
  shift
done

export PDK_ROOT=${PDK_ROOT:-$HOME/.volare}
WORK=${ORFS_WORK:-$HOME/ASIC/rv32i-soc-asic-work}
R=$WORK/results/sky130hd/soc_top/$VARIANT
SC=$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd
SRAM_V=$PDK_ROOT/sky130A/libs.ref/sky130_sram_macros/verilog/sky130_sram_2kbyte_1rw1r_32x512_8.v
mkdir -p build/gls docs

# ---- 1. the program ------------------------------------------------------
echo "1  build gls_smoke"
riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
  -T sw/link_gls.ld tb/asm_gls/gls_smoke.S -o build/gls/gls_smoke.elf || exit 1
python3 scripts/elf2hex.py build/gls/gls_smoke.elf build/gls/gls_smoke.hex || exit 1

# ---- 2. patched cell library -------------------------------------------
if [[ ! -f build/gls/sky130_fd_sc_hd_icarus.v ]]; then
  echo "2  patch the cell library for Icarus"
  python3 scripts/sky130_icarus_sdf_lib.py "$SC/verilog/sky130_fd_sc_hd.v" \
    build/gls/sky130_fd_sc_hd_icarus.v || exit 1
else
  echo "2  patched cell library already built"
fi

# ---- 3. SDF from OpenSTA, and de-dot the pair ---------------------------
if [[ $SDF -eq 1 && ! -f build/gls/${VARIANT}.sdf ]]; then
  echo "3  write SDF with OpenSTA"
  cat > build/gls/write_sdf.tcl <<TCL
read_liberty /OpenROAD-flow-scripts/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_liberty /pdk/sky130A/libs.ref/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib
read_verilog /orfs_work/results/sky130hd/soc_top/$VARIANT/6_final.v
link_design soc_top
read_sdc /orfs_work/results/sky130hd/soc_top/$VARIANT/6_final.sdc
read_spef /orfs_work/results/sky130hd/soc_top/$VARIANT/6_final.spef
write_sdf -digits 3 /work/build/gls/${VARIANT}.sdf
exit
TCL
  bash scripts/orfs.sh "sta -no_splash -exit /work/build/gls/write_sdf.tcl" \
    > build/gls/write_sdf.log 2>&1 || { tail -10 build/gls/write_sdf.log; exit 1; }
fi

# the netlist is de-dotted into a different file per mode: the SDF mode must
# rewrite netlist and SDF together, and reusing the functional netlist would
# leave no matching SDF
if [[ $SDF -eq 1 ]]; then
  if [[ ! -f build/gls/${VARIANT}_dedot.sdf ]]; then
    echo "   de-dot the netlist and SDF together"
    python3 scripts/sdf_dedot.py "$R/6_final.v" build/gls/${VARIANT}.sdf \
      build/gls/${VARIANT}_dedot.v build/gls/${VARIANT}_dedot.sdf || exit 1
  fi
else
  if [[ ! -f build/gls/${VARIANT}_dedot.v ]]; then
    echo "   de-dot the netlist"
    # no SDF yet: run the same substitution on the netlist alone
    python3 - "$R/6_final.v" build/gls/${VARIANT}_dedot.v <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
esc = re.compile(r"\\(\S+)")
open(dst, "w").write(esc.sub(lambda m: "\\" + m.group(1).replace(".", "_"), open(src).read()))
print("wrote", dst)
PY
  fi
fi

# ---- 4. build and run ---------------------------------------------------
HALF=$(python3 -c "print($PERIOD/2.0)")
if [[ $SDF -eq 1 ]]; then
  echo "4  build (SDF, period ${PERIOD} ns)"
  OUT=build/gls/tb_gls_${VARIANT}_sdf
  # -Tmax: OpenSTA writes SDF triples as min::max with typ empty.
  #
  # FUNCTIONAL must NOT be defined here. Every cell in sky130_fd_sc_hd.v is
  # `ifdef FUNCTIONAL <zero-delay model> `else <timing model with specify> `endif,
  # so defining it compiles the zero-delay variant, the 1664 specify blocks are
  # never seen, and $sdf_annotate silently has nothing to attach to. The giveaway
  # was the control run passing at 8 ns when the design's minimum period is
  # 12.73 ns.
  iverilog -g2012 -Tmax -o "$OUT" \
    -DHALF_PERIOD="$HALF" \
    -DSDF_FILE="\"build/gls/${VARIANT}_dedot.sdf\"" \
    -s tb_gls tb/timescale.v "$SRAM_V" \
    build/gls/sky130_fd_sc_hd_icarus.v "$SC/verilog/primitives.v" \
    build/gls/${VARIANT}_dedot.v tb/tb_gls.sv 2> build/gls/iverilog_sdf.log \
    || { grep -v "^$" build/gls/iverilog_sdf.log | head -15; exit 1; }
else
  echo "4  build (functional, unit delay)"
  OUT=build/gls/tb_gls_${VARIANT}_func
  iverilog -g2012 -o "$OUT" \
    -DFUNCTIONAL -DUNIT_DELAY="#1" \
    -s tb_gls tb/timescale.v "$SRAM_V" \
    "$SC/verilog/primitives.v" "$SC/verilog/sky130_fd_sc_hd.v" \
    build/gls/${VARIANT}_dedot.v tb/tb_gls.sv 2> build/gls/iverilog_func.log \
    || { grep -v "^$" build/gls/iverilog_func.log | head -15; exit 1; }
fi

echo "5  run"
vvp -n "$OUT" +hex=build/gls/gls_smoke.hex 2>&1 | grep -vE "^WARNING|Reading|Writing" | tail -8
