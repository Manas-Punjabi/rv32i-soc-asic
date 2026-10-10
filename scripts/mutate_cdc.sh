#!/usr/bin/env bash
# mutate_cdc.sh — control logic for scripts/cdc_check.py.
#
# A structural checker that passes is worth nothing until it is shown to fail on
# a broken synchronizer. Each mutant below is a real CDC bug; every one must be
# caught. Runs on the individual peripherals (seconds) rather than the whole SoC.
set -u
cd "$(dirname "$0")/.."
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0

run_check() { # file top async-in -> 0 if the checker passes
  yosys -p "read_verilog -sv $1; synth -top $2 -flatten; write_json $W/n.json" \
    > "$W/synth.log" 2>&1 || { echo "    (synthesis failed)"; return 2; }
  python3 scripts/cdc_check.py "$W/n.json" --top "$2" --async-in "$3" > "$W/cdc.log" 2>&1
}

mut() { # name file top async-in sed-expr
  local name=$1 file=$2 top=$3 ain=$4 expr=$5
  local base; base=$(basename "$file")
  cp "$file" "$W/$base"
  sed -i "$expr" "$W/$base"
  if cmp -s "$file" "$W/$base"; then echo "  $name: MUTATION NOT APPLIED"; fail=$((fail+1)); return; fi
  if run_check "$W/$base" "$top" "$ain"; then
    echo "  SURVIVED $name  (checker still says PASS)"; fail=$((fail+1))
  else
    echo "  killed   $name  -- $(grep -m1 FAIL "$W/cdc.log" | sed 's/^ *//')"; pass=$((pass+1))
  fi
}

# 1. second stage removed: a single flop cannot resolve metastability
mut C1_gpio_one_flop     rtl/periph/apb_gpio.sv apb_gpio gpio_in 's/in_sync1 <= in_sync0;/in_sync1 <= gpio_in;/'
# 2. logic in front of the first flop: a glitch can be captured
mut C2_gpio_comb_before  rtl/periph/apb_gpio.sv apb_gpio gpio_in 's/in_sync0 <= gpio_in;/in_sync0 <= gpio_in \& ~out_q;/'
# 3. stage 1 read directly as well: two consumers can diverge on a metastable value
mut C3_gpio_stage1_fanout rtl/periph/apb_gpio.sv apb_gpio gpio_in 's/R_IN:    prdata = {{(32-W){1'"'"'b0}}, in_sync1};/R_IN:    prdata = {{(32-W){1'"'"'b0}}, in_sync1 | in_sync0};/'
# 4. same three on the UART receive pin
mut C4_uart_one_flop     rtl/periph/apb_uart.sv apb_uart rx_i "s/rx_sync <= {rx_sync\[0\], rx_i};/rx_sync <= {rx_i, rx_i};/"
mut C5_uart_comb_before  rtl/periph/apb_uart.sv apb_uart rx_i "s/rx_sync <= {rx_sync\[0\], rx_i};/rx_sync <= {rx_sync[0], rx_i \& ~tx_busy};/"
mut C6_uart_raw_rx_used  rtl/periph/apb_uart.sv apb_uart rx_i 's/assign rx_s = rx_sync\[1\];/assign rx_s = rx_sync[1] \& rx_i;/'

echo "killed $pass / $((pass+fail))"
[[ $fail -eq 0 ]]
