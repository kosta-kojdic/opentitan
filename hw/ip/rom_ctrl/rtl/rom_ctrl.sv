// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module rom_ctrl
  import rom_ctrl_reg_pkg::NumAlerts;
  import prim_rom_pkg::rom_cfg_t;
#(
  parameter                       BootRomInitFile = "",
  parameter logic [NumAlerts-1:0] AlertAsyncOn = {NumAlerts{1'b1}},
  parameter bit [63:0]            RndCnstScrNonce = '0,
  parameter bit [127:0]           RndCnstScrKey = '0,
  parameter bit                   SkipCheck = 1'b1
) (
  input  clk_i,
  input  rst_ni,

  // ROM configuration parameters
  input  rom_cfg_t rom_cfg_i,

  input  tlul_pkg::tl_h2d_t rom_tl_i,
  output tlul_pkg::tl_d2h_t rom_tl_o,

  input  tlul_pkg::tl_h2d_t regs_tl_i,
  output tlul_pkg::tl_d2h_t regs_tl_o,

  // Alerts
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,

  // Connections to other blocks
  output rom_ctrl_pkg::pwrmgr_data_t pwrmgr_data_o,
  output rom_ctrl_pkg::keymgr_data_t keymgr_data_o,
  input  kmac_pkg::app_rsp_t         kmac_data_i,
  output kmac_pkg::app_req_t         kmac_data_o
);

  import rom_ctrl_pkg::*;
  import rom_ctrl_reg_pkg::*;
  import prim_util_pkg::vbits;

  // ROM_CTRL_ROM_SIZE is auto-generated by regtool and comes from the bus window size, measured in
  // bytes of content (i.e. 4 times the number of 32 bit words).
  localparam int unsigned RomSizeByte = ROM_CTRL_ROM_SIZE;
  localparam int unsigned RomSizeWords = RomSizeByte >> 2;
  localparam int unsigned RomIndexWidth = vbits(RomSizeWords);

  logic                     rom_select;

  logic [RomIndexWidth-1:0] rom_index;
  logic                     rom_req;
  logic [39:0]              rom_scr_rdata;
  logic [39:0]              rom_clr_rdata;
  logic                     rom_rvalid;

  logic [RomIndexWidth-1:0] bus_rom_index;
  logic                     bus_rom_req;
  logic                     bus_rom_gnt;
  logic [39:0]              bus_rom_rdata;
  logic                     bus_rom_rvalid;

  logic [RomIndexWidth-1:0] checker_rom_index;
  logic                     checker_rom_req;
  logic [39:0]              checker_rom_rdata;

  // Pack / unpack kmac connection data ========================================

  logic [63:0]              kmac_rom_data;
  logic                     kmac_rom_rdy;
  logic                     kmac_rom_vld;
  logic                     kmac_rom_last;
  logic                     kmac_done;
  logic [255:0]             kmac_digest;

  assign kmac_data_o = '{valid: kmac_rom_vld,
                         data: kmac_rom_data,
                         strb: '1,
                         last: kmac_rom_last};

  assign kmac_rom_rdy = kmac_data_i.ready;
  assign kmac_done = kmac_data_i.done;
  assign kmac_digest = kmac_data_i.digest_share0 ^ kmac_data_i.digest_share1;

  logic unused_kmac_error;
  assign unused_kmac_error = &{1'b0, kmac_data_i.error};

  // TL interface ==============================================================

  tlul_pkg::tl_h2d_t tl_rom_h2d [1];
  tlul_pkg::tl_d2h_t tl_rom_d2h [1];

  logic  rom_reg_integrity_error;

  rom_ctrl_rom_reg_top u_rom_top (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .tl_i       (rom_tl_i),
    .tl_o       (rom_tl_o),
    .tl_win_o   (tl_rom_h2d),
    .tl_win_i   (tl_rom_d2h),

    .intg_err_o (rom_reg_integrity_error),

    .devmode_i  (1'b1)
  );

  // Bus -> ROM adapter ========================================================

  logic rom_integrity_error;

  tlul_adapter_sram #(
    .SramAw(RomIndexWidth),
    .SramDw(32),
    .Outstanding(2),
    .ByteAccess(0),
    .ErrOnWrite(1),
    .EnableRspIntgGen(1),
    .EnableDataIntgGen(1) // TODO: Needs to be updated for integrity passthrough
  ) u_tl_adapter_rom (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),

    .tl_i         (tl_rom_h2d[0]),
    .tl_o         (tl_rom_d2h[0]),
    .en_ifetch_i  (tlul_pkg::InstrEn),
    .req_o        (bus_rom_req),
    .req_type_o   (),
    .gnt_i        (bus_rom_gnt),
    .we_o         (),
    .addr_o       (bus_rom_index),
    .wdata_o      (),
    .wmask_o      (),
    .intg_error_o (rom_integrity_error),
    .rdata_i      (bus_rom_rdata[31:0]),
    .rvalid_i     (bus_rom_rvalid),
    // TODO: Send an error on access when locked
    .rerror_i     (2'b00)
  );

  // The mux ===================================================================

  logic mux_alert;

  rom_ctrl_mux #(
    .AW (RomIndexWidth)
  ) u_mux (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .sel_i           (rom_select),
    .bus_addr_i      (bus_rom_index),
    .bus_req_i       (bus_rom_req),
    .bus_gnt_o       (bus_rom_gnt),
    .bus_rdata_o     (bus_rom_rdata),
    .bus_rvalid_o    (bus_rom_rvalid),
    .chk_addr_i      (checker_rom_index),
    .chk_req_i       (checker_rom_req),
    .chk_rdata_o     (checker_rom_rdata),
    .rom_addr_o      (rom_index),
    .rom_req_o       (rom_req),
    .rom_scr_rdata_i (rom_scr_rdata),
    .rom_clr_rdata_i (rom_clr_rdata),
    .rom_rvalid_i    (rom_rvalid),
    .alert_o         (mux_alert)
  );

  // The ROM itself ============================================================

  rom_ctrl_scrambled_rom #(
    .MemInitFile (BootRomInitFile),
    .Width       (40),
    .Depth       (RomSizeWords),
    .ScrNonce    (RndCnstScrNonce),
    .ScrKey      (RndCnstScrKey)
  ) u_rom (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .req_i       (rom_req),
    .addr_i      (rom_index),
    .rvalid_o    (rom_rvalid),
    .scr_rdata_o (rom_scr_rdata),
    .clr_rdata_o (rom_clr_rdata),
    .cfg_i       (rom_cfg_i)
  );

  // TODO: The ROM has been expanded to 40 bits wide to allow us to add 9 ECC check bits. At the
  //       moment, however, we're actually generating the ECC data in u_tl_adapter_rom. That should
  //       go away soonish but, until then, waive the fact that we're not looking at the top bits of
  //       rom_rdata.
  logic unused_bus_rom_rdata_top;
  assign unused_bus_rom_rdata_top = &{1'b0, bus_rom_rdata[39:32]};

  // Zero expand checker rdata to pass to KMAC
  assign kmac_rom_data = {24'd0, checker_rom_rdata};

  // Register block ============================================================

  rom_ctrl_regs_reg2hw_t reg2hw;
  rom_ctrl_regs_hw2reg_t hw2reg;
  logic                  reg_integrity_error;

  rom_ctrl_regs_reg_top u_reg_regs (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .tl_i       (regs_tl_i),
    .tl_o       (regs_tl_o),
    .reg2hw     (reg2hw),
    .hw2reg     (hw2reg),
    .intg_err_o (reg_integrity_error),
    .devmode_i  (1'b1)
   );

  // The checker FSM ===========================================================

  logic [255:0] digest_q, exp_digest_q;
  logic [255:0] digest_d;
  logic         digest_de;
  logic [31:0]  exp_digest_word_d;
  logic         exp_digest_de;
  logic [2:0]   exp_digest_idx;

  logic         checker_alert;

  rom_ctrl_fsm #(
    .RomDepth (RomSizeWords),
    .TopCount (8),
    .SkipCheck (SkipCheck)
  ) u_checker_fsm (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .digest_i             (digest_q),
    .exp_digest_i         (exp_digest_q),
    .digest_o             (digest_d),
    .digest_vld_o         (digest_de),
    .exp_digest_o         (exp_digest_word_d),
    .exp_digest_vld_o     (exp_digest_de),
    .exp_digest_idx_o     (exp_digest_idx),
    .pwrmgr_data_o        (pwrmgr_data_o),
    .keymgr_data_o        (keymgr_data_o),
    .kmac_rom_rdy_i       (kmac_rom_rdy),
    .kmac_rom_vld_o       (kmac_rom_vld),
    .kmac_rom_last_o      (kmac_rom_last),
    .kmac_done_i          (kmac_done),
    .kmac_digest_i        (kmac_digest),
    .rom_select_o         (rom_select),
    .rom_addr_o           (checker_rom_index),
    .rom_req_o            (checker_rom_req),
    .rom_data_i           (checker_rom_rdata[31:0]),
    .alert_o              (checker_alert)
  );

  // Register data =============================================================

  // DIGEST and EXP_DIGEST registers

  // Repack signals to convert between the view expected by rom_ctrl_reg_pkg for CSRs and the view
  // expected by rom_ctrl_fsm. Register 0 of a multi-reg appears as the low bits of the packed data.
  for (genvar i = 0; i < 8; i++) begin: gen_csr_digest
    localparam int unsigned TopBitInt = 32 * i + 31;
    localparam bit [7:0] TopBit = TopBitInt[7:0];

    assign hw2reg.digest[i].d = digest_d[TopBit -: 32];
    assign hw2reg.digest[i].de = digest_de;

    assign hw2reg.exp_digest[i].d = exp_digest_word_d;
    assign hw2reg.exp_digest[i].de = exp_digest_de && (i[2:0] == exp_digest_idx);

    assign digest_q[TopBit -: 32] = reg2hw.digest[i].q;
    assign exp_digest_q[TopBit -: 32] = reg2hw.exp_digest[i].q;
  end

  logic bus_integrity_error;
  assign bus_integrity_error = rom_reg_integrity_error | rom_integrity_error | reg_integrity_error;

  // FATAL_ALERT_CAUSE register
  assign hw2reg.fatal_alert_cause.checker_error.d  = checker_alert | mux_alert;
  assign hw2reg.fatal_alert_cause.checker_error.de = checker_alert | mux_alert;
  assign hw2reg.fatal_alert_cause.integrity_error.d  = bus_integrity_error;
  assign hw2reg.fatal_alert_cause.integrity_error.de = bus_integrity_error;

  // Alert generation ==========================================================

  logic [NumAlerts-1:0] alert_test;
  assign alert_test[AlertFatal] = reg2hw.alert_test.q &
                                  reg2hw.alert_test.qe;

  logic [NumAlerts-1:0] alerts;
  assign alerts[AlertFatal] = reg_integrity_error | checker_alert | mux_alert;

  for (genvar i = 0; i < NumAlerts; i++) begin: gen_alert_tx
    prim_alert_sender #(
      .AsyncOn(AlertAsyncOn[i]),
      .IsFatal(i == AlertFatal)
    ) u_alert_sender (
      .clk_i,
      .rst_ni,
      .alert_test_i  ( alert_test[i] ),
      .alert_req_i   ( alerts[i]     ),
      .alert_ack_o   (               ),
      .alert_state_o (               ),
      .alert_rx_i    ( alert_rx_i[i] ),
      .alert_tx_o    ( alert_tx_o[i] )
    );
  end

  // Asserts ===================================================================

  // All outputs should be known value after reset
  `ASSERT_KNOWN(RomTlODValidKnown_A, rom_tl_o.d_valid)
  `ASSERT_KNOWN(RomTlOAReadyKnown_A, rom_tl_o.a_ready)
  `ASSERT_KNOWN(RegTlODValidKnown_A, regs_tl_o.d_valid)
  `ASSERT_KNOWN(RegTlOAReadyKnown_A, regs_tl_o.a_ready)
  `ASSERT_KNOWN(AlertTxOKnown_A, alert_tx_o)

endmodule
