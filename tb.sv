`timescale 1ns/1ps
// `default_nettype none
`ifndef ADDR_WIDTH
`define ADDR_WIDTH 32
`endif

module tb;
  //--------------------------------------------------------------------------
  // Clock @ 100 MHz
  //--------------------------------------------------------------------------
  parameter CLK_PHASE=5;

  logic clk;
  logic reset_n;
  initial 
  begin
    clk                     = 1'b1;
    forever # CLK_PHASE clk = ~clk;
  end

  //string input_dir = "/home/jasteve4/TA/ECE-564-fall2025/project-dev/inputs";
  //string output_dir = "/home/jasteve4/TA/ECE-564-fall2025/project-dev/outputs";
  string input_dir =  "";
  string output_dir =  "";
  string sim_dir = "";
  integer file_handle;

  int n =0;
  time startTime;
  time endTime;
  int totalNumOfPasses;
  int totalNumOfCases;
  int numOfTest = 2;
  int test_case = -1;
  string log_file;
  string class_type = "ECE546";
  int debug_run = 0;

  //--------------------------------------------------------------------------
  // Runtime-config knobs (read from +plusargs)
  //   +tb_dqwidth=<N>      (fallback: +mc_dqwidth)
  //   +tb_burstlen=<N>     (fallback: +mc_burstlen, default 8)
  //   +tb_rdlat=<N>        (fallback: +mc_rdlat,   default -1 => wait for non-Z)
  //--------------------------------------------------------------------------
  localparam DRAM_DQ_WIDTH      = 8;   // default 16-bit "column width"
  localparam TB_BURST    = 8;    // default model burst length
  localparam TB_RDLAT    = 5;   // sample_wait; -1 => wait for non-Z
  localparam DRAM_ADDRESS_WIDTH = 32;

  localparam SRAM_ADDRESS_WIDTH = 10;
  localparam SRAM_DATA_WIDTH = 32;

  localparam ADDRESS_OFFSET_WIDTH = 3;
  localparam ADJUST_ADDRESS_WIDTH = DRAM_ADDRESS_WIDTH - (DRAM_DQ_WIDTH>>ADDRESS_OFFSET_WIDTH);
  localparam DATA_MASK = 1<<DRAM_DQ_WIDTH-1;
  localparam MEM_WORD_WIDTH = DRAM_DQ_WIDTH<<ADDRESS_OFFSET_WIDTH;
  localparam DRAM0 = 0;
  localparam DRAM1 = 1;

  logic [MEM_WORD_WIDTH-1:0] ref_mem [longint];

  // Pull from plusargs once at time 0
  initial begin
    $display("[TB] cfg: dqwidth=%0d, burstlen=%0d, rdlat=%0d", DRAM_DQ_WIDTH, TB_BURST, TB_RDLAT);
  end

  //--------------------------------------------------------------------------
  // Bus + TB-side IO
  //--------------------------------------------------------------------------
  logic [1:0]  		          CMD[2];
  logic [DRAM_ADDRESS_WIDTH-1:0]  addr[2];
  wire  [DRAM_DQ_WIDTH-1:0] 	  DQ[2];           // actual bidirectional bus to mem_ctrl
  logic                           start;
  wire                            ready;

  logic [DRAM_DQ_WIDTH-1:0] 	  din[2];   // TB drive data (we mask to DRAM_DQ_WIDTH)
  logic [DRAM_DQ_WIDTH-1:0] 	  dout[2];    // TB sampled bus
  logic        	     	          oe[2];    // TB tri-state enable (broadcast to all bits)


  // Port A: Read Port 
  reg  [SRAM_ADDRESS_WIDTH-1 :0]  read_address;
  wire [SRAM_DATA_WIDTH-1 :0]     read_data;
  reg                             read_enable; 
  
  //---------------------------------------------------------------
  // Port B: Write Port 
  reg  [SRAM_ADDRESS_WIDTH-1 :0]  write_address;
  reg  [SRAM_DATA_WIDTH-1 :0]     write_data;
  reg                             write_enable;
  event                           ev_start_test;

  sram1r1w
    #(
      .ADDR_WIDTH(SRAM_ADDRESS_WIDTH),
      .DATA_WIDTH(SRAM_DATA_WIDTH) 
    )
    sram
    (
      // General
      .clk        (clk),    

      //---------------------------------------------------------------
      // Port A: Read Port 
      .read_address       (read_address       ),
      .read_data   (read_data   ),
      .read_enable         (read_enable         ), 
      
      //---------------------------------------------------------------
      // Port B: Write Port 
      .write_address       (write_address       ),
      .write_data  (write_data  ),
      .write_enable         (write_enable         ) 
    );

  //--------------------------------------------------------------------------
  // Memory controller (DPI model behind it)
  //--------------------------------------------------------------------------
  for(genvar i=0;i<2;i++) begin : mem_block
    dram #(
      .ADDRESS_WIDTH(DRAM_ADDRESS_WIDTH),
      .DQ_WIDTH(DRAM_DQ_WIDTH)
    ) mem_inst (
      .clk    (clk),
      .CMD    (CMD[i]),
      .Address(addr[i]),
      .DQ     (DQ[i])
    );

    tri_state_driver dut_dram[DRAM_DQ_WIDTH-1:0] (
      .din 	(din[i]),
      .oe	(oe[i]),
      .pad    	(DQ[i]),
      .dout 	(dout[i])
    );
  end

  dut #(
    .DRAM_ADDRESS_WIDTH (DRAM_ADDRESS_WIDTH),
    .SRAM_ADDRESS_WIDTH (SRAM_ADDRESS_WIDTH),
    .DRAM_DQ_WIDTH      (DRAM_DQ_WIDTH),
    .SRAM_DATA_WIDTH    (SRAM_DATA_WIDTH)
  ) dut_inst(
    // Interface
    .clk         (clk),
    .reset_n     (reset_n), 
    .start       (start),
    .ready       (ready),
    // Input DRAM
    .input_CMD   (CMD[DRAM0]),  // 2'b00=IDLE, 2'b01=READ, 2'b10=WRITE
    .input_addr  (addr[DRAM0]),
    .input_dout  (dout[DRAM0]),
    .input_din   (din[DRAM0]),
    .input_oe    (oe[DRAM0]),
    // OUTPUT DRAM
    .output_CMD  (CMD[DRAM1]),  // 2'b00=IDLE, 2'b01=READ, 2'b10=WRITE
    .output_addr (addr[DRAM1]),
    .output_dout (dout[DRAM1]),
    .output_din  (din[DRAM1]),
    .output_oe   (oe[DRAM1]),
    // Port A: Read Port 
    .read_address       (read_address       ),
    .read_data   (read_data   ),
    .read_enable         (read_enable         ), 
    
    //---------------------------------------------------------------
    // Port B: Write Port 
    .write_address       (write_address       ),
    .write_data  (write_data  ),
    .write_enable         (write_enable         ) 
  );

  function automatic bit compare_mem();
    if(tb.mem_block[DRAM1].mem_inst.mem.size() != ref_mem.size()) return 0;
    foreach (ref_mem[k]) begin
      if (!tb.mem_block[DRAM1].mem_inst.mem.exists(k))  return 0;
      if (tb.mem_block[DRAM1].mem_inst.mem[k] !== ref_mem[k]) return 0;
    end
    return 1;
  endfunction

  task automatic test(input int testNum);

    int n = 0;
    totalNumOfCases++;
    $display("INFO[TB]: ######## Running Test: %0d ########",testNum);
    $display("INFO[TB]: ######## CLASS: %0s ########",class_type);
    $fdisplay(file_handle, "INFO[TB]: ######## Running Test: %0d #######",testNum);
    $fdisplay(file_handle, "INFO[TB]: ######## CLASS: %0s ########",class_type);
    tb.mem_block[DRAM1].mem_inst.mem.delete();
    tb.mem_block[DRAM0].mem_inst.mem.delete();
    if(class_type == "ECE564")
      if(debug_run == 0)
        $readmemh($sformatf("%s/output%0d.564.dat",output_dir,testNum),ref_mem);
      else
        $readmemh($sformatf("%s/debug%0d.564.dat",output_dir,testNum),ref_mem);
    else if(class_type == "ECE464")
      if(debug_run == 0) begin
        $readmemh($sformatf("%s/output%0d.464.dat",output_dir,testNum),ref_mem);
      end else begin
        $readmemh($sformatf("%s/debug%0d.464.dat",output_dir,testNum),ref_mem);
        $display("INFO[TB]: Reading ref memory file: %s",$sformatf("%s/debug%0d.464.dat",output_dir,testNum));
      end
    else
      $fatal(1,"Error: Must be -DCLASS=ECE[564,464]");

    if(debug_run == 0)
      tb.mem_block[DRAM0].mem_inst.loadMem($sformatf("%s/input%0d.dat",input_dir,testNum));
    else
      tb.mem_block[DRAM0].mem_inst.loadMem($sformatf("%s/debug%0d.dat",input_dir,testNum));


    ->ev_start_test;
    reset_n = 1'b1;
    repeat(10) @(posedge clk);
    reset_n = 1'b0;
    repeat(5) @(posedge clk);
    reset_n = 1'b1;
    repeat(5) @(posedge clk);

    start = 1'b0;
    repeat(5) @(posedge clk);
    start = 1'b1;
    @(posedge clk iff !ready)
    start = 1'b0;
    @(posedge clk);
    @(posedge clk iff ready)
    @(posedge clk);

    $writememh($sformatf("%s/output%0d.dat",sim_dir,testNum), tb.mem_block[DRAM1].mem_inst.mem);
    if (compare_mem()) begin
      $display("INFO:LVL0: Test: Passed");
      $fdisplay(file_handle, "INFO:LVL0: Test: Passed");
      totalNumOfPasses++;
    end else begin
      $display("INFO:LVL0: Test: Faild");
      $fdisplay(file_handle, "INFO:LVL0: Test: Faild");
    end
  endtask

  localparam int TIMEOUT_LIMIT      = 1024*1024*10;   // cycles before timeout

  int timeout_cnt;

  initial begin
    timeout_cnt    = TIMEOUT_LIMIT;

    forever begin
      @(posedge clk);
      if (ev_start_test.triggered) begin
        timeout_cnt = TIMEOUT_LIMIT;
      end
      


      timeout_cnt--;
      // timeout check
      if (timeout_cnt == 0) begin
        $display("###################################");
        $display("             TIMEOUT               ");
        $display("###################################");
        $fdisplay(file_handle,"###################################");
        $fdisplay(file_handle,"             TIMEOUT               ");
        $fdisplay(file_handle,"###################################");
        $finish;
      end
    end
  end


  initial begin

    $display("[TB] start");
    $dumpfile("waves.vcd"); $dumpvars(0, tb);
    if($value$plusargs("input_dir=%s",input_dir));
    if($value$plusargs("output_dir=%s",output_dir));
    if($value$plusargs("number_of_test=%d",numOfTest));
    if($value$plusargs("log_file=%s",log_file));
    if($value$plusargs("test=%d",test_case));
    if($value$plusargs("class=%s",class_type));
    if($value$plusargs("debug_run=%d",debug_run));
    if($value$plusargs("sim_output_dir=%s",sim_dir));

    startTime=$time;

    repeat(10) @(posedge clk);
    reset_n = 1'b1;
    repeat(10) @(posedge clk);
    reset_n = 1'b0;
    repeat(5) @(posedge clk);
    reset_n = 1'b1;
    repeat(5) @(posedge clk);

    if(test_case == -1) begin
      for(int testNum=0;testNum<numOfTest;testNum++) begin
        test(testNum);
      end
    end else begin
        test(test_case);
        tb.mem_block[DRAM1].mem_inst.dump_mem();
    end
    endTime=$time;
    if(totalNumOfCases != 0)
    begin
      $display("INFO[TB]: Total number of cases  : %0d",totalNumOfCases);
      $display("INFO[TB]: Total number of passes : %0d",totalNumOfPasses);
      $display("INFO[TB]: Finial Results         : %6.2f",(totalNumOfPasses * 100)/totalNumOfCases);
      $display("INFO[TB]: Finial Time Result     : %0t ",endTime-startTime);
      $display("INFO[TB]: Finial Cycle Result    : %0d cycles\n",((endTime-startTime)/CLK_PHASE));
      $fdisplay(file_handle,"INFO[TB]: Total number of cases  : %0d",totalNumOfCases);
      $fdisplay(file_handle,"INFO[TB]: Total number of passes : %0d",totalNumOfPasses);
      $fdisplay(file_handle,"INFO[TB]: Finial Results         : %6.2f",(totalNumOfPasses * 100)/totalNumOfCases);
      $fdisplay(file_handle,"INFO[TB]: Finial Time Result     : %0t ns",endTime-startTime);
      $fdisplay(file_handle,"INFO[TB]: Finial Cycle Result    : %0d cycles\n",((endTime-startTime)/CLK_PHASE));
    end

    $display("[TB] done");
    $finish;
  end


endmodule
