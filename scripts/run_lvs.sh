#!/usr/bin/env bash
# run_lvs.sh — layout vs schematic with Magic (extract) and Netgen (compare).
#
#   bash scripts/run_lvs.sh [FLOW_VARIANT]      default: base
#
# Three things have to be right or the compare fails for reasons unrelated to
# the design (all three learned on matmul-accel-asic):
#
#  1. Netlist side: 6_final.v has no power pins and omits fill, tap and antenna
#     diodes. Write a powered netlist from the final ODB instead.
#  2. Layout side: `extract do local`, then ext2spice. Transistor-less cells
#     (fill, tap) drop out, which is expected.
#  3. MAGIC_EXT_USE_GDS=1 in the environment, or the PDK's netgen setup will not
#     ignore the fill/tap classes that exist on one side and not the other.
#
# MACRO BUILDS
#
# This runs on the real sign-off variant, macros included. The macro is held as
# the PDK's own abstract, libs.ref/sky130_sram_macros/maglef/<macro>.mag: 131
# `port` declarations with directions, pin metal on metal3/metal4 plus
# obstruction layers, and no device layers whatsoever. Loading it before the GDS
# read and then reading with `gds noduplicates true` keeps Magic from replacing
# it with the 7,357-instance full view, so extraction emits the macro as a
# pin-accurate subcircuit containing no devices, and never descends into ~200k
# bitcell transistors.
#
# Both sides are then black boxes: the layout has an empty subcircuit with 131
# pins, and the powered Verilog instantiates the macro without defining it.
# Netgen compares the instance and its connectivity, which is the part this
# project is responsible for. The macro's *interior* is not compared -- that is
# vendor IP, and it is covered instead by tb_soc_mem (6,195 checks of the macro
# build against the flop build) and by the flow connecting it physically.
#
# Earlier attempts to strip the macro after loading the full view (`select top
# cell; delete`, `property LEFview true`) do not empty the cell; holding a
# genuine abstract from the start is what works. See scripts/run_drc.sh.
#
# Each stage is skipped when its output already exists, so a failure in the
# Netgen compare can be retried without redoing a ~20 minute extraction.
# --force redoes everything.
set -u
cd "$(dirname "$0")/.."
REPO_DIR=$(pwd)
VARIANT=base
FORCE=0
for a in "$@"; do
  case $a in --force) FORCE=1;; *) VARIANT=$a;; esac
done
export PDK_ROOT=${PDK_ROOT:-$HOME/.volare}
export MAGIC_EXT_USE_GDS=1
WORK=${ORFS_WORK:-$HOME/ASIC/rv32i-soc-asic-work}
R=$WORK/results/sky130hd/soc_top/$VARIANT
GDS=$R/6_final.gds
MAGIC=${MAGIC:-$HOME/opt/magic/bin/magic}
NETGEN=${NETGEN:-$HOME/opt/netgen/bin/netgen}
RC=$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc
SETUP=$PDK_ROOT/sky130A/libs.tech/netgen/sky130A_setup.tcl
MACRO=sky130_sram_2kbyte_1rw1r_32x512_8
MAGLEF=$PDK_ROOT/sky130A/libs.ref/sky130_sram_macros/maglef/$MACRO
SPICE=build/soc_top_layout_$VARIANT.spice
mkdir -p build docs/reports

[[ -f $GDS ]] || { echo "no GDS at $GDS"; exit 1; }

if [[ $FORCE -eq 1 || ! -s $R/6_final_pg.v ]]; then
  echo "1/4  powered netlist from the final ODB (needs Docker)"
  bash scripts/orfs.sh "openroad -no_init -exit <<'ORD'
read_db /orfs_work/results/sky130hd/soc_top/$VARIANT/6_final.odb
write_verilog -include_pwr_gnd /orfs_work/results/sky130hd/soc_top/$VARIANT/6_final_pg.v
ORD" > build/lvs_netlist_$VARIANT.log 2>&1 || { tail -5 build/lvs_netlist_$VARIANT.log; exit 1; }
else
  echo "1/4  powered netlist already present, reusing"
fi
echo "     $(grep -c . "$R/6_final_pg.v" 2>/dev/null) lines"

# Hold the macro abstract only when this variant actually instantiates it, so
# the macro-free variants still run unchanged.
if grep -q "$MACRO" "$R/6_final.v" 2>/dev/null; then
  PRELUDE="load $MAGLEF
gds noduplicates true"
  HELD="$MACRO held as the maglef abstract"
else
  PRELUDE=""
  HELD="macro-free variant"
fi

if [[ $FORCE -eq 1 || ! -s $SPICE ]]; then
  echo "2/4  extract with Magic ($HELD)"
  # Magic writes a .ext file per cell into the current directory. Run it from a
  # scratch directory under build/ so the repo root does not collect them: a
  # full-chip extraction produced 186 files and 277 MB there once. The output
  # paths therefore have to be absolute.
  EXTDIR=$(pwd)/build/ext_$VARIANT
  SPICE_ABS=$(pwd)/$SPICE
  LOG_ABS=$(pwd)/build/magic_extract_$VARIANT.log
  rm -rf "$EXTDIR"; mkdir -p "$EXTDIR"
  cd "$EXTDIR" || exit 1
  "$MAGIC" -dnull -noconsole -rcfile "$RC" <<EOF > "$LOG_ABS" 2>&1
$PRELUDE
gds read $GDS
load soc_top
select top cell
puts "MACRO_CHILDREN: [llength [cellname list children $MACRO]]"
extract do local
extract no capacitance
extract no coupling
extract no resistance
extract no adjust
extract unique
extract
ext2spice lvs
ext2spice -o $SPICE_ABS
quit -noprompt
EOF
  cd "$REPO_DIR" || exit 1
  [[ -s $SPICE ]] || { echo "extraction produced nothing"; tail -15 build/magic_extract_$VARIANT.log; exit 1; }
  grep -E "^MACRO_CHILDREN:" build/magic_extract_$VARIANT.log | sed 's/^/     /'
  printf "     .ext files kept under build/ext_%s (%s)\n" "$VARIANT" \
    "$(du -sh "$EXTDIR" 2>/dev/null | cut -f1)"
else
  echo "2/4  extraction already present, reusing ($HELD)"
fi
echo "     $(grep -c . "$SPICE") lines"

echo "3/4  what the macro looks like in the extracted netlist"
# A correct abstraction gives a subcircuit with 131 pins and no devices inside.
# If the pin count is 0, the abstract carried no ports; if devices appear, the
# full view leaked in and the compare below would be meaningless.
python3 - "$SPICE" "$MACRO" <<'PY'
import re, sys
path, macro = sys.argv[1], sys.argv[2]
lines = open(path, errors="replace").read().splitlines()
# SPICE wraps long pin lists onto continuation lines starting with '+', so the
# header has to be joined before counting -- reading only the first physical
# line reports 5 pins for a 131-pin macro.
start = next((i for i, l in enumerate(lines)
              if re.match(r"\.subckt\s+" + re.escape(macro) + r"\b", l, re.I)), None)
insts = sum(1 for l in lines
            if re.match(r"X\S*" + re.escape(macro), l, re.I))
if start is None:
    print(f"     no .subckt definition; {insts} instance call(s)"
          f" -> black box on the layout side")
else:
    pins = lines[start].split()[2:]
    i = start + 1
    while i < len(lines) and lines[i].startswith("+"):
        pins += lines[i][1:].split()
        i += 1
    devs = 0
    while i < len(lines) and not re.match(r"\.ends", lines[i], re.I):
        s = lines[i].strip()
        if s and s[0].upper() in "MXDQRCJ":
            devs += 1
        i += 1
    print(f"     .subckt {macro}: {len(pins)} pins, {devs} devices inside")
print(f"     {insts} macro instance(s) placed and wired")
PY

echo "4/4  compare with Netgen"
"$NETGEN" -batch lvs \
  "$SPICE soc_top" \
  "$R/6_final_pg.v soc_top" \
  "$SETUP" \
  build/lvs_$VARIANT.log > build/lvs_run_$VARIANT.log 2>&1

{
  echo "# Netgen LVS, variant=$VARIANT"
  echo "# layout:  $SPICE"
  if grep -q "$MACRO" "$R/6_final.v" 2>/dev/null; then
    echo "# $MACRO held as the PDK maglef abstract (131 ports, no devices):"
    echo "#   compared as a black box -- instance and connectivity, not interior."
  else
    echo "# macro-free variant"
  fi
  echo "# netlist: 6_final_pg.v (write_verilog -include_pwr_gnd, powered, with fill/tap/diodes)"
  echo "# MAGIC_EXT_USE_GDS=1"
  echo
  tail -40 build/lvs_$VARIANT.log
} > docs/reports/netgen_lvs_${VARIANT}.txt

grep -E "Final result|Circuits match|Netlists do not match|black box|blackbox" \
  build/lvs_$VARIANT.log | tail -8
echo "report: docs/reports/netgen_lvs_${VARIANT}.txt"
