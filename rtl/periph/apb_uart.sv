// apb_uart.sv — 8N1 UART as an APB slave, clocked from the system clock.
//
// Register map (byte offsets):
//   0x000  TXDATA  W  [7:0] byte to send. Accepted only when STATUS.tx_ready = 1,
//                     otherwise dropped (poll or use the TX interrupt).
//   0x004  RXDATA  R  [7:0] received byte; the read pops it (clears rx_valid).
//   0x008  STATUS  R  bit0 tx_ready   holding register empty, a write will be accepted
//                     bit1 tx_idle    nothing in the holding register or the shifter
//                     bit2 rx_valid   a byte is waiting in RXDATA
//                     bit3 rx_overrun a byte arrived while rx_valid was set and was
//                                     dropped; the earlier byte is kept (sticky)
//                     bit4 rx_frame   stop bit was 0 (sticky)
//                  W  bit3/bit4 = 1 clears the sticky flags
//   0x00C  CTRL    RW bit0 rx_ie  irq while rx_valid
//                     bit1 tx_ie  irq while tx_ready
//   0x010  DIV     RW [15:0] bit period in clock cycles: baud = clk / DIV. Minimum 4
//                     (RX samples mid-bit). Takes effect at the next start bit.
//
// Any other offset returns PSLVERR. All accesses complete in one cycle.
//
// TX is double-buffered: a byte can be written while the previous one is still
// shifting out, so back-to-back bytes have no gap. RX: rx_i is asynchronous and
// goes through a 2-flop synchronizer (the only clock-domain crossing in the SoC);
// a falling edge starts a bit counter, the start bit is re-checked at mid-bit to
// reject glitches, then each data bit and the stop bit are sampled at mid-bit.
module apb_uart #(
  parameter int SLAVE_AW  = 12,
  parameter int DIV_RESET = 868         // 100 MHz / 115200
)(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                psel,
  input  logic                penable,
  input  logic                pwrite,
  input  logic [SLAVE_AW-1:0] paddr,
  input  logic [31:0]         pwdata,
  output logic [31:0]         prdata,
  output logic                pready,
  output logic                pslverr,
  output logic                tx_o,
  input  logic                rx_i,
  output logic                irq
);
  localparam logic [11:0] R_TXDATA = 12'h000;
  localparam logic [11:0] R_RXDATA = 12'h004;
  localparam logic [11:0] R_STATUS = 12'h008;
  localparam logic [11:0] R_CTRL   = 12'h00C;
  localparam logic [11:0] R_DIV    = 12'h010;

  logic acc, wr, rd;
  assign acc = psel && penable;
  assign wr  = acc &&  pwrite;
  assign rd  = acc && !pwrite;

  logic [11:0] off;
  assign off = paddr[11:0];

  logic known;
  assign known = (off == R_TXDATA) || (off == R_RXDATA) || (off == R_STATUS) ||
                 (off == R_CTRL)   || (off == R_DIV);

  // ------------------------------------------------------------------ config
  logic [15:0] div_q;
  logic        rx_ie, tx_ie;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_q <= 16'(DIV_RESET);
      rx_ie <= 1'b0;
      tx_ie <= 1'b0;
    end else if (wr) begin
      if (off == R_DIV)  div_q          <= pwdata[15:0];
      if (off == R_CTRL) {tx_ie, rx_ie} <= pwdata[1:0];
    end
  end

  // ------------------------------------------------------------------ TX
  logic [7:0]  tx_hold;
  logic        tx_hold_v, tx_busy;
  logic [9:0]  tx_shift;              // {stop, data[7:0], start}
  logic [3:0]  tx_bits;
  logic [15:0] tx_cnt;
  logic        tx_ready, tx_idle, tx_load;

  assign tx_load  = tx_hold_v && !tx_busy;
  assign tx_ready = !tx_hold_v;
  assign tx_idle  = !tx_hold_v && !tx_busy;
  assign tx_o     = tx_busy ? tx_shift[0] : 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_hold_v <= 1'b0;
      tx_busy   <= 1'b0;
      tx_bits   <= '0;
      tx_cnt    <= '0;
    end else begin
      if (tx_load) begin
        tx_hold_v <= 1'b0;
        tx_busy   <= 1'b1;
        tx_bits   <= '0;
        tx_cnt    <= '0;
      end else if (tx_busy) begin
        if (tx_cnt == div_q - 16'd1) begin
          tx_cnt <= '0;
          if (tx_bits == 4'd9) tx_busy <= 1'b0;
          else                 tx_bits <= tx_bits + 4'd1;
        end else begin
          tx_cnt <= tx_cnt + 16'd1;
        end
      end
      if (wr && off == R_TXDATA && tx_ready) tx_hold_v <= 1'b1;
    end
  end
  // datapath registers, no reset needed
  always_ff @(posedge clk) begin
    if (wr && off == R_TXDATA && tx_ready) tx_hold <= pwdata[7:0];
    if (tx_load)                           tx_shift <= {1'b1, tx_hold, 1'b0};
    else if (tx_busy && tx_cnt == div_q - 16'd1) tx_shift <= {1'b1, tx_shift[9:1]};
  end

  // ------------------------------------------------------------------ RX
  logic [1:0] rx_sync;
  logic       rx_s;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rx_sync <= 2'b11;
    else        rx_sync <= {rx_sync[0], rx_i};
  end
  assign rx_s = rx_sync[1];

  typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_t;
  rx_state_t   rx_state;
  logic [15:0] rx_cnt;
  logic [2:0]  rx_bit;
  logic [7:0]  rx_shift, rx_data;
  logic        rx_valid, rx_overrun, rx_frame;
  logic        rx_pop, rx_done_ok, rx_done_bad;
  logic        rx_mid, rx_end;

  assign rx_mid = (rx_cnt == {1'b0, div_q[15:1]} - 16'd1);   // DIV/2 - 1
  assign rx_end = (rx_cnt == div_q - 16'd1);
  assign rx_pop = rd && off == R_RXDATA;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state <= RX_IDLE;
      rx_cnt   <= '0;
      rx_bit   <= '0;
    end else begin
      case (rx_state)
        RX_IDLE: if (!rx_s) begin rx_state <= RX_START; rx_cnt <= '0; end
        RX_START: begin
          rx_cnt <= rx_cnt + 16'd1;
          if (rx_mid) begin
            rx_cnt <= '0;
            rx_bit <= '0;
            rx_state <= rx_s ? RX_IDLE : RX_DATA;   // glitch: back to idle
          end
        end
        RX_DATA: begin
          rx_cnt <= rx_cnt + 16'd1;
          if (rx_end) begin
            rx_cnt <= '0;
            rx_bit <= rx_bit + 3'd1;
            if (rx_bit == 3'd7) rx_state <= RX_STOP;
          end
        end
        default: begin                              // RX_STOP
          rx_cnt <= rx_cnt + 16'd1;
          if (rx_end) rx_state <= RX_IDLE;
        end
      endcase
    end
  end
  always_ff @(posedge clk)
    if (rx_state == RX_DATA && rx_end) rx_shift <= {rx_s, rx_shift[7:1]};

  assign rx_done_ok  = (rx_state == RX_STOP) && rx_end &&  rx_s;
  assign rx_done_bad = (rx_state == RX_STOP) && rx_end && !rx_s;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_valid   <= 1'b0;
      rx_overrun <= 1'b0;
      rx_frame   <= 1'b0;
    end else begin
      // a completing byte wins over a pop in the same cycle
      if (rx_done_ok) begin
        rx_valid <= 1'b1;
        if (rx_valid && !rx_pop) rx_overrun <= 1'b1;
      end else if (rx_pop) begin
        rx_valid <= 1'b0;
      end
      if (rx_done_bad) rx_frame <= 1'b1;
      if (wr && off == R_STATUS) begin
        if (pwdata[3]) rx_overrun <= 1'b0;
        if (pwdata[4]) rx_frame   <= 1'b0;
      end
    end
  end
  // on overrun the byte already waiting is kept and the new one is dropped
  always_ff @(posedge clk)
    if (rx_done_ok && !(rx_valid && !rx_pop)) rx_data <= rx_shift;

  // ------------------------------------------------------------------ bus
  always_comb begin
    prdata = 32'h0;
    if (rd) begin
      case (off)
        R_RXDATA: prdata = {24'h0, rx_data};
        R_STATUS: prdata = {27'h0, rx_frame, rx_overrun, rx_valid, tx_idle, tx_ready};
        R_CTRL:   prdata = {30'h0, tx_ie, rx_ie};
        R_DIV:    prdata = {16'h0, div_q};
        default:  prdata = 32'h0;
      endcase
    end
  end
  assign pready  = 1'b1;
  assign pslverr = acc && !known;
  assign irq     = (rx_valid && rx_ie) || (tx_ready && tx_ie);

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, pwdata[31:16]};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
