#!/usr/bin/env bash
# mutate_periph.sh — inject known bugs into copies of the peripheral RTL and confirm
# each testbench catches its own. Expected: every mutant killed.
set -u
cd "$(dirname "$0")/.."
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0

mut() { # name tb file sed-expr
  local name=$1 tb=$2 file=$3 expr=$4
  cp "rtl/periph/$file" "$W/$file"
  sed -i "$expr" "$W/$file"
  if cmp -s "rtl/periph/$file" "$W/$file"; then echo "  $name: MUTATION NOT APPLIED"; fail=$((fail+1)); return; fi
  iverilog -g2012 -I tb -s tb_apb_$tb -o "$W/sim" "$W/$file" tb/tb_apb_$tb.sv 2>/dev/null
  local r; r=$(vvp -n "$W/sim" | grep -E '^(PASS|FAIL)' | head -1)
  if [[ $r == FAIL* ]]; then echo "  killed   $name"; pass=$((pass+1));
  else echo "  SURVIVED $name  ($r)"; fail=$((fail+1)); fi
}

mut P1_uart_no_start_recheck uart  apb_uart.sv  's/rx_state <= rx_s ? RX_IDLE : RX_DATA;/rx_state <= RX_DATA;/'
mut P2_uart_overrun_keeps_new uart apb_uart.sv  's/if (rx_done_ok \&\& !(rx_valid \&\& !rx_pop)) rx_data <= rx_shift;/if (rx_done_ok) rx_data <= rx_shift;/'
mut P3_uart_no_stop_bit      uart  apb_uart.sv  "s/tx_shift <= {1'b1, tx_hold, 1'b0};/tx_shift <= {1'b0, tx_hold, 1'b0};/"
mut P4_uart_sample_at_edge   uart  apb_uart.sv  "s/assign rx_mid = (rx_cnt == {1'b0, div_q\[15:1\]} - 16'd1);/assign rx_mid = (rx_cnt == 16'd0);/"
mut P5_uart_tx_drop_2nd      uart  apb_uart.sv  's/assign tx_ready = !tx_hold_v;/assign tx_ready = !tx_hold_v \&\& !tx_busy;/'
mut P6_uart_irq_ignores_ie   uart  apb_uart.sv  's/assign irq     = (rx_valid \&\& rx_ie) || (tx_ready \&\& tx_ie);/assign irq     = rx_valid || tx_ready;/'
mut P7_timer_gt_not_ge       timer apb_timer.sv 's/assign irq_timer = (mtime >= mtimecmp);/assign irq_timer = (mtime > mtimecmp);/'
mut P8_timer_lo_only         timer apb_timer.sv 's/assign irq_timer = (mtime >= mtimecmp);/assign irq_timer = (mtime[31:0] >= mtimecmp[31:0]);/'
mut P9_timer_cmp_reset_zero  timer apb_timer.sv "s/mtimecmp <= '1;/mtimecmp <= '0;/"
mut P10_gpio_one_flop_sync   gpio  apb_gpio.sv  's/in_sync1 <= in_sync0;/in_sync1 <= gpio_in;/'
mut P11_gpio_clr_is_xor      gpio  apb_gpio.sv  's/R_CLR: out_q <= out_q \& ~pwdata\[W-1:0\];/R_CLR: out_q <= out_q ^ pwdata[W-1:0];/'
mut P12_gpio_no_pslverr      gpio  apb_gpio.sv  "s/assign pslverr = acc \&\& !known;/assign pslverr = 1'b0;/"

echo "killed $pass / $((pass+fail))"
[[ $fail -eq 0 ]]
