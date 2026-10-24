`timescale 1ns/1ps
module tb;
  reg clk=0, reset=1;
  cpu dut(.clk(clk), .reset(reset));
  always #5 clk=~clk;
  integer cyc=0;
  wire [31:0] x31 = dut.id_s.RF.regs[31];
  wire [31:0] x30 = dut.id_s.RF.regs[30];
  initial begin
    #22 reset=0;
    repeat(3000) @(posedge clk);
    $display("TIMEOUT pc=%h x30=%0d x31=%h", dut.pc_if, x30, x31); $finish;
  end
  always @(posedge clk) if(!reset) begin
    cyc<=cyc+1;
    if (x31==32'hC0DE) begin $display("PASS  (%0d cycles)", cyc); $finish; end
    if (x31==32'hBAD)  begin $display("FAIL  test #%0d", x30); $finish; end
  end
endmodule