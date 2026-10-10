#!/usr/bin/env bash
# run_periph_tests.sh — build and run every APB peripheral testbench.
#   bash scripts/run_periph_tests.sh [accel] [uart] [timer] [gpio]
# Prints each testbench's PASS/FAIL line; exits non-zero if any fails.
set -u
cd "$(dirname "$0")/.."
mkdir -p build
tbs=("$@"); [[ ${#tbs[@]} -eq 0 ]] && tbs=(accel uart timer gpio)
fail=0
for t in "${tbs[@]}"; do
  case $t in
    accel) src="rtl/accel/mm_pe.sv rtl/accel/mm_accel.sv rtl/bus/apb_fabric.sv rtl/periph/apb_mm_accel.sv"; top=tb_apb_accel;;
    *)     src="rtl/periph/apb_$t.sv"; top=tb_apb_$t;;
  esac
  if ! iverilog -g2012 -I tb -s $top -o build/$top $src tb/$top.sv > build/$top.iv.log 2>&1; then
    grep -v "constant selects" build/$top.iv.log | head -5; echo "FAIL: $top did not build"; fail=1; continue
  fi
  r=$(vvp -n build/$top | grep -E "^(PASS|FAIL)|^  FAIL")
  echo "$r"
  [[ $r == PASS* ]] || fail=1
done
exit $fail
