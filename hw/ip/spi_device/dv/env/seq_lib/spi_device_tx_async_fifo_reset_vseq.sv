// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// TX ASYNC FIFO test with driving data, resetting async tx fifo and driving new data
class spi_device_tx_async_fifo_reset_vseq extends spi_device_base_vseq;
  `uvm_object_utils(spi_device_tx_async_fifo_reset_vseq)
  `uvm_object_new

  virtual task body();
    bit [31:0] host_data;
    bit [31:0] device_data;
    bit [31:0] device_data_exp;
    bit [7:0] tx_level;
    uint       avail_bytes;
    uint       avail_data;
    bit [31:0] host_data_exp_q[$];

    spi_device_init();
    ral.cfg.timer_v.set(8'hFF);
    csr_update(.csr(ral.cfg));
    `DV_CHECK_RANDOMIZE_FATAL(this)
    `DV_CHECK_STD_RANDOMIZE_FATAL(host_data)
    `DV_CHECK_STD_RANDOMIZE_FATAL(device_data)
    // Fill TX SRAM FIFO with some data, which will be transfered to TX async FIFO
    wait_for_tx_avail_bytes(SRAM_WORD_SIZE, SramSpaceAvail, avail_bytes);
    write_device_words_to_send({device_data});
    cfg.clk_rst_vif.wait_clks(16);
    // Write 0 into read and write point of TX SRAM FIFO
    ral.txf_ptr.wptr.set(16'h0);
    ral.txf_ptr.rptr.set(16'h0);
    csr_update(.csr(ral.txf_ptr));
    // Program `rst_txfifo` to reset the async FIFO
    ral.control.rst_txfifo.set(1'b1);
    csr_update(.csr(ral.control));
    cfg.clk_rst_vif.wait_clks(100);
    ral.control.rst_txfifo.set(1'b0);
    csr_update(.csr(ral.control));
    // Check `async_fifo_level.txlvl` is 0
    csr_rd(.ptr(ral.async_fifo_level.txlvl), .value(tx_level));
    `DV_CHECK_CASE_EQ(tx_level, 0)
    //Fill TX SRAM FIFO with some other data and enable SPI transfer
    write_device_words_to_send({32'h12345678});
    cfg.clk_rst_vif.wait_clks(100);
    spi_host_xfer_word(host_data, device_data_exp);
    `DV_CHECK_CASE_EQ(32'h12345678, device_data_exp)

  endtask : body

endclass : spi_device_tx_async_fifo_reset_vseq
