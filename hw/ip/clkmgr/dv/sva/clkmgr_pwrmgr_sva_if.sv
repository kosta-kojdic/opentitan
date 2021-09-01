// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// This contains SVA assertions to check that rising or falling edges of ip_clk_en
// are followed by corresponding edges of clk_status. Notice when it falls the response
// could be slower due to devices not being idle. We create two different assertions to
// avoid very large wait times for them to be idle.
interface clkmgr_pwrmgr_sva_if (
  input logic clk_i,
  input logic rst_ni,
  input logic ip_clk_en,
  input logic clk_status,
  input logic [4:0] idle
);

  // The max times are longer to cover the different clock domain synchronizers.
  // Ideally they would use the io_div4 clock, but it gets turned off when ip_clk_en
  // goes inactive.
  localparam int FallCyclesMin = 0;
  localparam int FallCyclesMax = 16;

  localparam int RiseCyclesMin = 0;
  localparam int RiseCyclesMax = 16;

  bit disable_sva;

  // clk_status should fall if all units are idle when enable falls.
  `ASSERT(StatusFallForDisableIdle_A,
          $fell(ip_clk_en) && (idle == '1) |-> ##[FallCyclesMin:FallCyclesMax] $fell(clk_status),
          clk_i, !rst_ni || disable_sva)

  // clk_status should fall if all units become idle while enable is inactive.
  `ASSERT(StatusFallForIdleDisable_A,
          $rose(idle == '1) && !ip_clk_en |-> ##[FallCyclesMin:FallCyclesMax] $fell(clk_status),
          clk_i, !rst_ni || disable_sva)

  // clk_status whould rise is ip_clk_en rises.
  `ASSERT(StatusRiseForEnable_A,
          $rose(ip_clk_en) |-> ##[RiseCyclesMin:RiseCyclesMax] $rose(clk_status), clk_i,
          !rst_ni || disable_sva)

  // clk_status should not fall unless units are idle.
  `ASSERT(NoStatusFallUnlessIdle_A, $fell(clk_status) |-> (idle == '1), clk_i,
          !rst_ni || disable_sva)
endinterface
