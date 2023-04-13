module BranchPredictor
#(
    parameter NUM_IN=2
)
(
    input wire clk,
    input wire rst,
    
    input wire IN_clearICache,
    
    input wire IN_mispredFlush,
    input wire IN_mispr,
    input BHist_t IN_misprHist,
    
    // IF interface
    input wire IN_pcValid,
    input wire[31:0] IN_pc,
    output wire OUT_branchTaken,
    output BHist_t OUT_branchHistory,
    output BranchPredInfo OUT_branchInfo,
    output wire OUT_multipleBranches,
    
    output PredBranch OUT_predBr,
    //output wire OUT_isJump,
    //output FetchOff_t OUT_branchSrcOffs,
    //output wire[31:0] OUT_branchDst,
    //output wire OUT_branchFound,
    //output wire OUT_branchCompr,
    

    input ReturnDecUpd IN_retDecUpd,
    
    // Branch XU interface
    input BTUpdate IN_btUpdates[NUM_IN-1:0],
    
    
    // Branch ROB Interface
    input BPUpdate IN_bpUpdate
);

integer i;

BHist_t gHistory;
BHist_t gHistoryCom;

// Try to find valid branch target update
BTUpdate btUpdate;
always_comb begin
    btUpdate = 'x;
    btUpdate.valid = 0;
    for (i = 0; i < NUM_IN; i=i+1) begin
        if (IN_btUpdates[i].valid)
            btUpdate = IN_btUpdates[i];
    end
end

wire[30:0] branchAddr = IN_pc[31:1];

assign OUT_branchHistory = gHistory;

always_comb begin
    if (BTB_br.valid && (!RET_br.valid || RET_br.offs > BTB_br.offs)) begin
        OUT_predBr = BTB_br;
        OUT_branchTaken = BTB_br.valid && (BTB_br.isJump || TAGE_taken);
        OUT_multipleBranches = !OUT_branchTaken && (BTB_multipleBranches || RET_br.valid);

        OUT_branchInfo.predicted = 1;
        OUT_branchInfo.taken = OUT_branchTaken;
        OUT_branchInfo.isJump = OUT_predBr.isJump;
    end
    else begin
        OUT_predBr = RET_br;
        OUT_branchTaken = RET_br.valid;
        OUT_multipleBranches = 0;

        OUT_branchInfo.predicted = RET_br.valid;
        OUT_branchInfo.taken = RET_br.valid;
        OUT_branchInfo.isJump = 1;
    end
end

PredBranch BTB_br;
wire BTB_branchTaken = BTB_br.valid && (BTB_br.isJump || TAGE_taken);

wire BTB_multipleBranches;
BranchTargetBuffer btb
(
    .clk(clk),
    .rst(rst || IN_clearICache),
    .IN_pcValid(IN_pcValid),
    .IN_pc(IN_pc[31:1]),
    .OUT_branchFound(BTB_br.valid),
    .OUT_branchDst(BTB_br.dst),
    .OUT_branchSrcOffs(BTB_br.offs),
    .OUT_branchIsJump(BTB_br.isJump),
    .OUT_branchCompr(BTB_br.compr),

    .OUT_multipleBranches(BTB_multipleBranches),
    .IN_BPT_branchTaken(BTB_branchTaken),
    .IN_btUpdate(btUpdate)
);

wire TAGE_taken;
TagePredictor tagePredictor
(
    .clk(clk),
    .rst(rst),
    
    .IN_predAddr(branchAddr),
    .IN_predHistory(gHistory),
    .OUT_predTageID(OUT_branchInfo.tageID),
    .OUT_predUseful(OUT_branchInfo.tageUseful),
    .OUT_predTaken(TAGE_taken),
    
    .IN_writeValid(IN_bpUpdate.valid && IN_bpUpdate.bpi.predicted && !IN_mispredFlush && !IN_bpUpdate.bpi.isJump),
    .IN_writeAddr(IN_bpUpdate.pc[30:0]),
    .IN_writeHistory(IN_bpUpdate.history),
    .IN_writeTageID(IN_bpUpdate.bpi.tageID),
    .IN_writeTaken(IN_bpUpdate.branchTaken),
    .IN_writeUseful(IN_bpUpdate.bpi.tageUseful),
    .IN_writePred(IN_bpUpdate.bpi.taken)
);

PredBranch RET_br;
assign RET_br.isJump = 1;
ReturnStack retStack
(
    .clk(clk),
    .rst(rst),

    .IN_valid(IN_pcValid),
    .IN_pc(IN_pc[31:1]),
    .IN_brValid(BTB_br.valid),
    .IN_brOffs(BTB_br.offs),
    .IN_isCall(1'b0),
    
    .OUT_curIdx(OUT_branchInfo.idx),
    .OUT_predBr(RET_br),

    .IN_returnUpd(IN_retDecUpd)
);


always_ff@(posedge clk) begin

    if (rst) begin
        gHistory <= 0;
        gHistoryCom <= 0;
    end
    else begin
        if (OUT_predBr.valid && !OUT_predBr.isJump)
            gHistory <= {gHistory[$bits(BHist_t)-2:0], OUT_branchTaken};
        
        if (IN_bpUpdate.valid && !IN_mispredFlush) begin
            gHistoryCom <= {gHistoryCom[$bits(BHist_t)-2:0], IN_bpUpdate.branchTaken};
        end
    end
    
    if (!rst && IN_mispr) begin
        gHistory <= IN_misprHist;
    end
end

endmodule
