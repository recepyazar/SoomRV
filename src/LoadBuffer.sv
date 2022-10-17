typedef struct packed
{
    bit valid;
    SqN sqN;
    bit[29:0] addr;
} LBEntry;

module LoadBuffer
#(
    parameter NUM_PORTS=1,
    parameter NUM_ENTRIES=24
)
(
    input wire clk,
    input wire rst,
    
    input SqN commitSqN,
    
    input AGU_UOp IN_uop[NUM_PORTS-1:0],
    
    input BranchProv IN_branch,
    output BranchProv OUT_branch,
    
    output SqN OUT_maxLoadSqN
);

integer i;
integer j;

LBEntry entries[NUM_ENTRIES-1:0];

SqN baseIndex;
SqN indexIn;

reg mispredict[NUM_PORTS-1:0];

always_ff@(posedge clk) begin

    if (rst) begin
        for (i = 0; i < NUM_ENTRIES; i=i+1) begin
            entries[i].valid <= 0;
        end
        baseIndex = 0;
        OUT_branch.taken <= 0;
        OUT_maxLoadSqN <= baseIndex + NUM_ENTRIES[5:0] - 1;
    end
    else begin
        
        if (IN_branch.taken) begin
            for (i = 0; i < NUM_ENTRIES; i=i+1) begin
                if ($signed(entries[i].sqN - IN_branch.sqN) > 0)
                    entries[i].valid <= 0;
            end
            //if ($signed(baseIndex - IN_branch.loadSqN) > 0)
            //    baseIndex = IN_branch.loadSqN;
            
            if (IN_branch.flush)
                baseIndex = IN_branch.loadSqN;
        end
        else begin
            // Delete entries that have been committed
            if (entries[0].valid && $signed(commitSqN - entries[0].sqN) > 0) begin
                for (i = 0; i < NUM_ENTRIES-1; i=i+1)
                    entries[i] <= entries[i+1];
                entries[NUM_ENTRIES - 1].valid <= 0;
                
                baseIndex = baseIndex + 1;
            end
        end
    
        // Insert new entries, check stores
        for (i = 0; i < NUM_PORTS; i=i+1) begin
            if (IN_uop[i].valid && (!IN_branch.taken || $signed(IN_uop[i].sqN - IN_branch.sqN) <= 0)) begin
            
                if (IN_uop[i].isLoad) begin
                    reg[$clog2(NUM_ENTRIES)-1:0] index = IN_uop[i].loadSqN[$clog2(NUM_ENTRIES)-1:0] - baseIndex[$clog2(NUM_ENTRIES)-1:0];
                    assert(IN_uop[i].loadSqN < baseIndex + NUM_ENTRIES);
                    
                    //mispredict[i] <= 0;

                    entries[index].sqN <= IN_uop[i].sqN;
                    entries[index].addr <= IN_uop[i].addr[31:2];
                    entries[index].valid <= 1;
                end
                
                else begin
                    reg temp = 0;
                    for (j = 0; j < NUM_ENTRIES; j=j+1) begin
                        if (entries[j].valid && entries[j].addr == IN_uop[i].addr[31:2] && $signed(IN_uop[i].sqN - entries[j].sqN) <= 0) begin
                            temp = 1;
                        end
                    end
                    
                    if (temp) begin
                        OUT_branch.taken <= 1;
                        OUT_branch.dstPC <= IN_uop[i].pc;
                        OUT_branch.sqN <= IN_uop[i].sqN;
                        OUT_branch.loadSqN <= IN_uop[i].loadSqN;
                        OUT_branch.storeSqN <= IN_uop[i].storeSqN;
                        OUT_branch.fetchID <= IN_uop[i].fetchID;
                        OUT_branch.history <= IN_uop[i].history;
                        OUT_branch.flush <= 0;
                    end
                    else 
                        OUT_branch.taken <= 0;
                end
            end
            else 
                OUT_branch.taken <= 0;
        end
        
        OUT_maxLoadSqN <= baseIndex + NUM_ENTRIES[5:0] - 1;
    end

end

endmodule
