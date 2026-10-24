// =====================================================================
// == RV32I 5-Stage Pipelined CPU  (IF / ID / EX / MEM / WB)
// ==
// == Features
// ==   - Full RV32I: all ALU, shifts, LUI/AUIPC, JAL/JALR, 6 branches,
// ==     LB/LH/LW/LBU/LHU, SB/SH/SW
// ==   - EX/MEM + MEM/WB forwarding, load-use stall, register-file bypass
// ==   - Branches/jumps resolved in EX (2-cycle taken penalty, flushed)
// ==   - FENCE/ECALL/EBREAK decode as NOPs
// =====================================================================
`timescale 1ns/1ps

// ==========================================================
// == PC
// ==========================================================
module pc(
    input clk, reset, pc_write,
    input [31:0] pc_in,
    output reg [31:0] pc_out
);
always @(posedge clk or posedge reset) begin
    if (reset)         pc_out <= 32'b0;
    else if (pc_write) pc_out <= pc_in;
end
endmodule

// ==========================================================
// == Instruction Memory (word addressed, NOP-filled)
// ==========================================================
module instr_mem #(
    parameter HEX_FILE = "instr_mem.hex",
    parameter DEPTH    = 1024                  // words
)(
    input  [31:0] addr,
    output [31:0] instr
);
reg [31:0] mem [0:DEPTH-1];
integer i;
initial begin
    for (i = 0; i < DEPTH; i = i + 1) mem[i] = 32'h00000013; // NOP (addi x0,x0,0)
    $readmemh(HEX_FILE, mem);
end
assign instr = mem[addr[$clog2(DEPTH)+1:2]];
endmodule

// ==========================================================
// == Immediate Generator
// ==========================================================
module imm_gen (
    input  [31:0] instr,
    output reg [31:0] imm
);
always @(*) begin
    case (instr[6:0])
        7'b0000011, 7'b0010011, 7'b1100111: imm = {{20{instr[31]}}, instr[31:20]};                                   // I
        7'b0100011:                         imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};                      // S
        7'b1100011:                         imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}; // B
        7'b0110111, 7'b0010111:             imm = {instr[31:12], 12'b0};                                             // U
        7'b1101111:                         imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}; // J
        default:                            imm = 32'b0;
    endcase
end
endmodule

// ==========================================================
// == Register File  (write-before-read bypass for WB->ID)
// ==========================================================
module reg_file (
    input clk, reset, reg_write,
    input [4:0]  rs1, rs2, rd,
    input [31:0] write_data,
    output [31:0] rs1_data, rs2_data
);
reg [31:0] regs [0:31];
wire wr_en = reg_write && (rd != 5'd0);

// Same-cycle bypass: a WB write is visible to the instruction reading in ID
assign rs1_data = (rs1 == 5'd0)            ? 32'b0 :
                  (wr_en && rd == rs1)     ? write_data : regs[rs1];
assign rs2_data = (rs2 == 5'd0)            ? 32'b0 :
                  (wr_en && rd == rs2)     ? write_data : regs[rs2];

integer i;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        for (i = 0; i < 32; i = i + 1) regs[i] <= 32'b0;
    end else if (wr_en) begin
        regs[rd] <= write_data;
    end
end
endmodule

// ==========================================================
// == ALU
// ==========================================================
module alu (
    input  [31:0] a, b,
    input  [3:0]  alu_control,
    output reg [31:0] result
);
always @(*) begin
    case (alu_control)
        4'b0000: result = a + b;
        4'b0001: result = a - b;
        4'b0010: result = a & b;
        4'b0011: result = a | b;
        4'b0100: result = a ^ b;
        4'b0101: result = a << b[4:0];
        4'b0110: result = a >> b[4:0];
        4'b0111: result = $signed(a) >>> b[4:0];
        4'b1000: result = ($signed(a) < $signed(b)) ? 32'b1 : 32'b0;
        4'b1001: result = (a < b) ? 32'b1 : 32'b0;
        default: result = 32'b0;
    endcase
end
endmodule

// ==========================================================
// == ALU Control
// ==   alu_op: 00 = ADD (load/store/LUI/AUIPC)
// ==           01 = SUB
// ==           10 = R-type  (funct7[5] selects SUB / SRA)
// ==           11 = I-type  (funct7[5] only matters for SRAI)
// ==========================================================
module alu_control (
    input  [1:0] alu_op,
    input  [2:0] funct3,
    input  [6:0] funct7,
    output reg [3:0] alu_ctrl
);
always @(*) begin
    case (alu_op)
        2'b00: alu_ctrl = 4'b0000;
        2'b01: alu_ctrl = 4'b0001;
        default: begin
            case (funct3)
                // FIX: ADDI with a negative immediate has instr[30]=1; only R-type may become SUB
                3'b000: alu_ctrl = (alu_op == 2'b10 && funct7[5]) ? 4'b0001 : 4'b0000;
                3'b001: alu_ctrl = 4'b0101;                              // SLL
                3'b010: alu_ctrl = 4'b1000;                              // SLT
                3'b011: alu_ctrl = 4'b1001;                              // SLTU
                3'b100: alu_ctrl = 4'b0100;                              // XOR
                3'b101: alu_ctrl = funct7[5] ? 4'b0111 : 4'b0110;        // SRA / SRL
                3'b110: alu_ctrl = 4'b0011;                              // OR
                3'b111: alu_ctrl = 4'b0010;                              // AND
            endcase
        end
    endcase
end
endmodule

// ==========================================================
// == Pipeline Registers
// ==========================================================
module if_id_reg(
    input clk, reset, flush, if_id_write,
    input  [31:0] pc_in, instr_in,
    output reg [31:0] pc_out, instr_out
);
always @(posedge clk or posedge reset) begin
    if (reset || flush) begin
        pc_out    <= 32'b0;
        instr_out <= 32'h00000013;      // bubble = NOP
    end else if (if_id_write) begin
        pc_out    <= pc_in;
        instr_out <= instr_in;
    end
end
endmodule

module id_ex_reg(
    input clk, reset, bubble,
    input [31:0] pc_in, rs1_data_in, rs2_data_in, imm_in,
    input [4:0]  rs1_in, rs2_in, rd_in,
    input [2:0]  funct3_in,
    input [6:0]  funct7_in,
    input reg_write_in, alu_src_in, mem_read_in, mem_write_in, mem_to_reg_in,
    input branch_in, jump_in, jalr_in,
    input [1:0]  alu_op_in, a_sel_in,
    output reg [31:0] pc_out, rs1_data_out, rs2_data_out, imm_out,
    output reg [4:0]  rs1_out, rs2_out, rd_out,
    output reg [2:0]  funct3_out,
    output reg [6:0]  funct7_out,
    output reg reg_write_out, alu_src_out, mem_read_out, mem_write_out, mem_to_reg_out,
    output reg branch_out, jump_out, jalr_out,
    output reg [1:0]  alu_op_out, a_sel_out
);
always @(posedge clk or posedge reset) begin
    if (reset || bubble) begin
        pc_out <= 0; rs1_data_out <= 0; rs2_data_out <= 0; imm_out <= 0;
        rs1_out <= 0; rs2_out <= 0; rd_out <= 0; funct3_out <= 0; funct7_out <= 0;
        reg_write_out <= 0; alu_src_out <= 0; mem_read_out <= 0; mem_write_out <= 0;
        mem_to_reg_out <= 0; branch_out <= 0; jump_out <= 0; jalr_out <= 0;
        alu_op_out <= 0; a_sel_out <= 0;
    end else begin
        pc_out <= pc_in; rs1_data_out <= rs1_data_in; rs2_data_out <= rs2_data_in; imm_out <= imm_in;
        rs1_out <= rs1_in; rs2_out <= rs2_in; rd_out <= rd_in; funct3_out <= funct3_in; funct7_out <= funct7_in;
        reg_write_out <= reg_write_in; alu_src_out <= alu_src_in; mem_read_out <= mem_read_in;
        mem_write_out <= mem_write_in; mem_to_reg_out <= mem_to_reg_in; branch_out <= branch_in;
        jump_out <= jump_in; jalr_out <= jalr_in; alu_op_out <= alu_op_in; a_sel_out <= a_sel_in;
    end
end
endmodule

module ex_mem_reg(
    input clk, reset,
    input mem_read_in, mem_write_in, mem_to_reg_in, reg_write_in,
    input [31:0] alu_result_in, rs2_data_in,
    input [4:0]  rd_in,
    input [2:0]  funct3_in,
    output reg mem_read_out, mem_write_out, mem_to_reg_out, reg_write_out,
    output reg [31:0] alu_result_out, rs2_data_out,
    output reg [4:0]  rd_out,
    output reg [2:0]  funct3_out
);
always @(posedge clk or posedge reset) begin
    if (reset) begin
        mem_read_out <= 0; mem_write_out <= 0; mem_to_reg_out <= 0; reg_write_out <= 0;
        alu_result_out <= 0; rs2_data_out <= 0; rd_out <= 0; funct3_out <= 0;
    end else begin
        mem_read_out <= mem_read_in; mem_write_out <= mem_write_in; mem_to_reg_out <= mem_to_reg_in;
        reg_write_out <= reg_write_in; alu_result_out <= alu_result_in; rs2_data_out <= rs2_data_in;
        rd_out <= rd_in; funct3_out <= funct3_in;
    end
end
endmodule

module mem_wb_reg(
    input clk, reset,
    input [31:0] mem_data_in, alu_result_in,
    input [4:0]  rd_in,
    input reg_write_in, mem_to_reg_in,
    output reg [31:0] mem_data_out, alu_result_out,
    output reg [4:0]  rd_out,
    output reg reg_write_out, mem_to_reg_out
);
always @(posedge clk or posedge reset) begin
    if (reset) begin
        mem_data_out <= 0; alu_result_out <= 0; rd_out <= 0; reg_write_out <= 0; mem_to_reg_out <= 0;
    end else begin
        mem_data_out <= mem_data_in; alu_result_out <= alu_result_in; rd_out <= rd_in;
        reg_write_out <= reg_write_in; mem_to_reg_out <= mem_to_reg_in;
    end
end
endmodule

// ==========================================================
// == Stages
// ==========================================================
module if_stage(
    input clk, reset, pc_write, branch_taken,
    input  [31:0] branch_addr,
    output [31:0] instr, pc_out
);
    parameter HEX_FILE = "instr_mem.hex";
    wire [31:0] pc_next, pc_curr;
    assign pc_next = branch_taken ? branch_addr : (pc_curr + 32'd4);
    // A taken branch always overrides a stall
    pc PC(.clk(clk), .reset(reset), .pc_write(pc_write | branch_taken), .pc_in(pc_next), .pc_out(pc_curr));
    instr_mem #(.HEX_FILE(HEX_FILE)) IMEM(.addr(pc_curr), .instr(instr));
    assign pc_out = pc_curr;
endmodule

module id_stage(
    input clk, reset, reg_write,
    input [31:0] instr, write_data,
    input [4:0]  rd,
    output [31:0] rs1_data, rs2_data, imm
);
    reg_file RF(.clk(clk), .reset(reset), .reg_write(reg_write),
                .rs1(instr[19:15]), .rs2(instr[24:20]), .rd(rd), .write_data(write_data),
                .rs1_data(rs1_data), .rs2_data(rs2_data));
    imm_gen IMM(.instr(instr), .imm(imm));
endmodule

// EX: forwarding, ALU, branch compare, jump/branch target, link value
module ex_stage(
    input [31:0] pc, rs1_data, rs2_data, imm, ex_mem_alu_result, wb_data,
    input alu_src, branch, jump, jalr,
    input [1:0] alu_op, a_sel, forwardA, forwardB,
    input [2:0] funct3,
    input [6:0] funct7,
    output [31:0] ex_result,        // ALU result, or PC+4 for JAL/JALR
    output [31:0] store_data,
    output        branch_taken,
    output [31:0] branch_target
);
    wire [3:0]  alu_ctrl;
    wire [31:0] alu_result;

    wire [31:0] rs1_fwd = (forwardA == 2'b10) ? ex_mem_alu_result : (forwardA == 2'b01) ? wb_data : rs1_data;
    wire [31:0] rs2_fwd = (forwardB == 2'b10) ? ex_mem_alu_result : (forwardB == 2'b01) ? wb_data : rs2_data;
    assign store_data = rs2_fwd;

    // a_sel: 00 = rs1, 01 = PC (AUIPC), 10 = zero (LUI)
    wire [31:0] alu_in1 = (a_sel == 2'b01) ? pc : (a_sel == 2'b10) ? 32'b0 : rs1_fwd;
    wire [31:0] alu_in2 = alu_src ? imm : rs2_fwd;

    alu_control AC(.alu_op(alu_op), .funct3(funct3), .funct7(funct7), .alu_ctrl(alu_ctrl));
    alu         ALU(.a(alu_in1), .b(alu_in2), .alu_control(alu_ctrl), .result(alu_result));

    // Dedicated branch comparator (all six RV32I branches)
    reg cond;
    always @(*) begin
        case (funct3)
            3'b000:  cond = (rs1_fwd == rs2_fwd);                        // BEQ
            3'b001:  cond = (rs1_fwd != rs2_fwd);                        // BNE
            3'b100:  cond = ($signed(rs1_fwd) <  $signed(rs2_fwd));      // BLT
            3'b101:  cond = ($signed(rs1_fwd) >= $signed(rs2_fwd));      // BGE
            3'b110:  cond = (rs1_fwd <  rs2_fwd);                        // BLTU
            3'b111:  cond = (rs1_fwd >= rs2_fwd);                        // BGEU
            default: cond = 1'b0;
        endcase
    end

    assign branch_taken  = jump | (branch & cond);
    // JALR: (rs1 + imm) & ~1 ; JAL/Bxx: pc + imm
    assign branch_target = jalr ? ((rs1_fwd + imm) & 32'hFFFF_FFFE) : (pc + imm);
    assign ex_result     = jump ? (pc + 32'd4) : alu_result;   // link value rides the normal result path
endmodule

// MEM: byte-addressable-style data memory with sub-word load/store
module mem_stage #(parameter DEPTH = 1024)(
    input clk, mem_read, mem_write,
    input [2:0]  funct3,
    input [31:0] addr, write_data,
    output reg [31:0] read_data
);
    reg [31:0] data_mem [0:DEPTH-1];
    integer i;
    initial for (i = 0; i < DEPTH; i = i + 1) data_mem[i] = 32'b0;

    wire [$clog2(DEPTH)-1:0] idx = addr[$clog2(DEPTH)+1:2];
    wire [1:0] boff = addr[1:0];

    // ---- Store (read-modify-write the word) ----
    reg [31:0] w;
    always @(posedge clk) begin
        if (mem_write) begin
            w = data_mem[idx];
            case (funct3[1:0])
                2'b00: case (boff)                                   // SB
                    2'd0: w[7:0]   = write_data[7:0];
                    2'd1: w[15:8]  = write_data[7:0];
                    2'd2: w[23:16] = write_data[7:0];
                    2'd3: w[31:24] = write_data[7:0];
                endcase
                2'b01: if (boff[1]) w[31:16] = write_data[15:0];     // SH
                       else         w[15:0]  = write_data[15:0];
                default: w = write_data;                             // SW
            endcase
            data_mem[idx] <= w;
        end
    end

    // ---- Load (align + sign/zero extend) ----
    wire [31:0] word    = data_mem[idx];
    wire [31:0] shifted = word >> {boff, 3'b000};
    always @(*) begin
        case (funct3)
            3'b000:  read_data = {{24{shifted[7]}},  shifted[7:0]};   // LB
            3'b001:  read_data = {{16{shifted[15]}}, shifted[15:0]};  // LH
            3'b100:  read_data = {24'b0, shifted[7:0]};               // LBU
            3'b101:  read_data = {16'b0, shifted[15:0]};              // LHU
            default: read_data = word;                                // LW
        endcase
    end
endmodule

module wb_stage(
    input [31:0] alu_result, mem_data,
    input mem_to_reg,
    output [31:0] write_back_data
);
    assign write_back_data = mem_to_reg ? mem_data : alu_result;
endmodule

// ==========================================================
// == Control, Hazard, Forwarding
// ==========================================================
module control_unit(
    input [6:0] opcode,
    output reg reg_write, alu_src, mem_read, mem_write, mem_to_reg, branch, jump, jalr,
    output reg [1:0] alu_op, a_sel
);
always @(*) begin
    {reg_write, alu_src, mem_read, mem_write, mem_to_reg, branch, jump, jalr} = 8'b0;
    alu_op = 2'b00;
    a_sel  = 2'b00;
    case (opcode)
        7'b0110011: begin reg_write = 1; alu_op = 2'b10; end                           // R-type
        7'b0010011: begin reg_write = 1; alu_src = 1; alu_op = 2'b11; end              // I-type ALU
        7'b0000011: begin reg_write = 1; alu_src = 1; mem_read = 1; mem_to_reg = 1; end // Load
        7'b0100011: begin alu_src = 1; mem_write = 1; end                              // Store
        7'b1100011: begin branch = 1; end                                              // Branch
        7'b1101111: begin reg_write = 1; jump = 1; end                                 // JAL
        7'b1100111: begin reg_write = 1; alu_src = 1; jump = 1; jalr = 1; end          // JALR
        7'b0110111: begin reg_write = 1; alu_src = 1; a_sel = 2'b10; end               // LUI   (0 + imm)
        7'b0010111: begin reg_write = 1; alu_src = 1; a_sel = 2'b01; end               // AUIPC (pc + imm)
        default: ;                                                                     // FENCE/ECALL/EBREAK/illegal -> NOP
    endcase
end
endmodule

module hazard_unit(
    input id_ex_mem_read,
    input [4:0] id_ex_rd, if_id_rs1, if_id_rs2,
    output reg pc_write, if_id_write, stall
);
always @(*) begin
    {pc_write, if_id_write, stall} = 3'b110;
    // FIX: ignore rd == x0 (no real dependency)
    if (id_ex_mem_read && id_ex_rd != 5'd0 && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2))
        {pc_write, if_id_write, stall} = 3'b001;
end
endmodule

module forwarding_unit(
    input [4:0] ex_mem_rd, mem_wb_rd, id_ex_rs1, id_ex_rs2,
    input ex_mem_reg_write, mem_wb_reg_write,
    output reg [1:0] forwardA, forwardB
);
wire ex_hit1 = ex_mem_reg_write && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs1;
wire ex_hit2 = ex_mem_reg_write && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs2;
wire wb_hit1 = mem_wb_reg_write && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs1;
wire wb_hit2 = mem_wb_reg_write && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs2;
always @(*) begin
    forwardA = ex_hit1 ? 2'b10 : wb_hit1 ? 2'b01 : 2'b00;   // newest producer wins
    forwardB = ex_hit2 ? 2'b10 : wb_hit2 ? 2'b01 : 2'b00;
end
endmodule

// ==========================================================
// == CPU Top
// ==========================================================
module cpu #(parameter HEX_FILE = "instr_mem.hex")(input clk, reset);
    // IF/ID
    wire [31:0] pc_if, instr_if, pc_id, instr_id;
    // ID
    wire [31:0] rs1_data, rs2_data, imm;
    wire id_reg_write, id_alu_src, id_mem_read, id_mem_write, id_mem_to_reg, id_branch, id_jump, id_jalr;
    wire [1:0] id_alu_op, id_a_sel;
    // ID/EX
    wire [31:0] id_ex_pc, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
    wire [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    wire [2:0]  id_ex_funct3;
    wire [6:0]  id_ex_funct7;
    wire id_ex_reg_write, id_ex_alu_src, id_ex_mem_read, id_ex_mem_write, id_ex_mem_to_reg;
    wire id_ex_branch, id_ex_jump, id_ex_jalr;
    wire [1:0] id_ex_alu_op, id_ex_a_sel;
    // EX
    wire [31:0] ex_result, store_data_ex, branch_target;
    wire branch_taken;
    wire [1:0] forwardA, forwardB;
    // EX/MEM
    wire [31:0] ex_mem_alu_result, ex_mem_rs2_data;
    wire [4:0]  ex_mem_rd;
    wire [2:0]  ex_mem_funct3;
    wire ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write, ex_mem_mem_to_reg;
    // MEM/WB
    wire [31:0] mem_read_data, mem_wb_alu_result, mem_wb_mem_data, write_data;
    wire [4:0]  mem_wb_rd;
    wire mem_wb_reg_write, mem_wb_mem_to_reg;
    // Hazard
    wire if_pc_write, if_id_write, stall;

    control_unit cu(.opcode(instr_id[6:0]), .reg_write(id_reg_write), .alu_src(id_alu_src), .alu_op(id_alu_op),
                    .mem_read(id_mem_read), .mem_write(id_mem_write), .mem_to_reg(id_mem_to_reg),
                    .branch(id_branch), .jump(id_jump), .jalr(id_jalr), .a_sel(id_a_sel));

    hazard_unit hu(.id_ex_mem_read(id_ex_mem_read), .id_ex_rd(id_ex_rd),
                   .if_id_rs1(instr_id[19:15]), .if_id_rs2(instr_id[24:20]),
                   .pc_write(if_pc_write), .if_id_write(if_id_write), .stall(stall));

    forwarding_unit fu(.ex_mem_rd(ex_mem_rd), .mem_wb_rd(mem_wb_rd),
                       .ex_mem_reg_write(ex_mem_reg_write), .mem_wb_reg_write(mem_wb_reg_write),
                       .id_ex_rs1(id_ex_rs1), .id_ex_rs2(id_ex_rs2), .forwardA(forwardA), .forwardB(forwardB));

    // ---------------- IF ----------------
    if_stage #(.HEX_FILE(HEX_FILE)) if_s(.clk(clk), .reset(reset), .pc_write(if_pc_write),
                    .branch_taken(branch_taken), .branch_addr(branch_target), .instr(instr_if), .pc_out(pc_if));

    if_id_reg if_id_r(.clk(clk), .reset(reset), .flush(branch_taken), .if_id_write(if_id_write),
                      .pc_in(pc_if), .instr_in(instr_if), .pc_out(pc_id), .instr_out(instr_id));

    // ---------------- ID ----------------
    id_stage id_s(.clk(clk), .reset(reset), .instr(instr_id), .reg_write(mem_wb_reg_write), .rd(mem_wb_rd),
                  .write_data(write_data), .rs1_data(rs1_data), .rs2_data(rs2_data), .imm(imm));

    // Bubble on load-use stall OR taken branch (wrong-path instruction sitting in ID)
    id_ex_reg id_ex_r(.clk(clk), .reset(reset), .bubble(stall | branch_taken),
        .pc_in(pc_id), .rs1_data_in(rs1_data), .rs2_data_in(rs2_data), .imm_in(imm),
        .rs1_in(instr_id[19:15]), .rs2_in(instr_id[24:20]), .rd_in(instr_id[11:7]),
        .funct3_in(instr_id[14:12]), .funct7_in(instr_id[31:25]),
        .reg_write_in(id_reg_write), .alu_src_in(id_alu_src), .alu_op_in(id_alu_op),
        .mem_read_in(id_mem_read), .mem_write_in(id_mem_write), .mem_to_reg_in(id_mem_to_reg),
        .branch_in(id_branch), .jump_in(id_jump), .jalr_in(id_jalr), .a_sel_in(id_a_sel),
        .pc_out(id_ex_pc), .rs1_data_out(id_ex_rs1_data), .rs2_data_out(id_ex_rs2_data), .imm_out(id_ex_imm),
        .rs1_out(id_ex_rs1), .rs2_out(id_ex_rs2), .rd_out(id_ex_rd),
        .funct3_out(id_ex_funct3), .funct7_out(id_ex_funct7),
        .reg_write_out(id_ex_reg_write), .alu_src_out(id_ex_alu_src), .alu_op_out(id_ex_alu_op),
        .mem_read_out(id_ex_mem_read), .mem_write_out(id_ex_mem_write), .mem_to_reg_out(id_ex_mem_to_reg),
        .branch_out(id_ex_branch), .jump_out(id_ex_jump), .jalr_out(id_ex_jalr), .a_sel_out(id_ex_a_sel));

    // ---------------- EX ----------------
    ex_stage ex_s(.pc(id_ex_pc), .rs1_data(id_ex_rs1_data), .rs2_data(id_ex_rs2_data), .imm(id_ex_imm),
                  .ex_mem_alu_result(ex_mem_alu_result), .wb_data(write_data),
                  .alu_src(id_ex_alu_src), .branch(id_ex_branch), .jump(id_ex_jump), .jalr(id_ex_jalr),
                  .alu_op(id_ex_alu_op), .a_sel(id_ex_a_sel), .forwardA(forwardA), .forwardB(forwardB),
                  .funct3(id_ex_funct3), .funct7(id_ex_funct7),
                  .ex_result(ex_result), .store_data(store_data_ex),
                  .branch_taken(branch_taken), .branch_target(branch_target));

    ex_mem_reg ex_mem_r(.clk(clk), .reset(reset),
        .mem_read_in(id_ex_mem_read), .mem_write_in(id_ex_mem_write), .mem_to_reg_in(id_ex_mem_to_reg),
        .reg_write_in(id_ex_reg_write), .alu_result_in(ex_result), .rs2_data_in(store_data_ex),
        .rd_in(id_ex_rd), .funct3_in(id_ex_funct3),
        .mem_read_out(ex_mem_mem_read), .mem_write_out(ex_mem_mem_write), .mem_to_reg_out(ex_mem_mem_to_reg),
        .reg_write_out(ex_mem_reg_write), .alu_result_out(ex_mem_alu_result), .rs2_data_out(ex_mem_rs2_data),
        .rd_out(ex_mem_rd), .funct3_out(ex_mem_funct3));

    // ---------------- MEM ----------------
    mem_stage mem_s(.clk(clk), .mem_read(ex_mem_mem_read), .mem_write(ex_mem_mem_write),
                    .funct3(ex_mem_funct3), .addr(ex_mem_alu_result), .write_data(ex_mem_rs2_data),
                    .read_data(mem_read_data));

    mem_wb_reg mem_wb_r(.clk(clk), .reset(reset),
        .mem_data_in(mem_read_data), .alu_result_in(ex_mem_alu_result), .rd_in(ex_mem_rd),
        .reg_write_in(ex_mem_reg_write), .mem_to_reg_in(ex_mem_mem_to_reg),
        .mem_data_out(mem_wb_mem_data), .alu_result_out(mem_wb_alu_result), .rd_out(mem_wb_rd),
        .reg_write_out(mem_wb_reg_write), .mem_to_reg_out(mem_wb_mem_to_reg));

    // ---------------- WB ----------------
    wb_stage wb_s(.alu_result(mem_wb_alu_result), .mem_data(mem_wb_mem_data),
                  .mem_to_reg(mem_wb_mem_to_reg), .write_back_data(write_data));
endmodule