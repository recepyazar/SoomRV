
// [0] -> transfer exists; [1] -> allow pass thru
function automatic logic[1:0] CheckTransfers(MemController_Req memcReq, MemController_Res memcRes, CacheID_t cacheID, logic[31:0] addr);
    logic[1:0] rv = 0;

    for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1) begin
        if (memcRes.transfers[i].valid &&
            memcRes.transfers[i].cacheID == cacheID &&
            memcRes.transfers[i].readAddr[31:`CLSIZE_E] == addr[31:`CLSIZE_E]
        ) begin
            rv[0] = 1;
            rv[1] = (memcRes.transfers[i].progress) > 
                ({1'b0, addr[`CLSIZE_E-1:2]} - {1'b0, memcRes.transfers[i].readAddr[`CLSIZE_E-1:2]});
        end
    end
    
    if ((memcReq.cmd == MEMC_REPLACE || memcReq.cmd == MEMC_CP_EXT_TO_CACHE) && 
        memcReq.readAddr[31:`CLSIZE_E] == addr[31:`CLSIZE_E] &&
        memcReq.cacheID == cacheID
    ) begin
        rv = 2'b01;
    end

    return rv;
endfunction

module LoadStoreUnit
#(
    parameter SIZE=(1<<(`CACHE_SIZE_E - `CLSIZE_E))
)
(
    input wire clk,
    input wire rst,

    input wire IN_flush,
    input wire IN_SQ_empty,
    output wire OUT_busy,

    input BranchProv IN_branch,
    output reg OUT_ldAGUStall[`NUM_AGUS-1:0],
    output reg OUT_ldStall[`NUM_AGUS-1:0],
    output wire OUT_stStall,
    
    // regular loads come through these two
    // structs. uopELd provides the lower 12 addr bits
    // one cycle early.
    input ELD_UOp IN_uopELd[`NUM_AGUS-1:0],
    input LD_UOp IN_aguLd[`NUM_AGUS-1:0],

    input LD_UOp IN_uopLd[`NUM_AGUS-1:0], // special loads (page walk, non-speculative)
    output LD_UOp OUT_uopLdSq[`NUM_AGUS-1:0],
    output LD_Ack OUT_ldAck[`NUM_AGUS-1:0],

    input ST_UOp IN_uopSt,

    IF_Cache.HOST IF_cache,
    IF_MMIO.HOST IF_mmio,
    IF_CTable.HOST IF_ct,
    
    input StFwdResult IN_stFwd[`NUM_AGUS-1:0],
    output ST_Ack OUT_stAck,

    output MemController_Req OUT_memc,
    output MemController_Req OUT_BLSU_memc,
    input MemController_Res IN_memc,

    output RES_UOp OUT_uopLd[`NUM_AGUS-1:0]
);

MemController_Req BLSU_memc;
MemController_Req LSU_memc;
assign OUT_memc = LSU_memc;
assign OUT_BLSU_memc = BLSU_memc;

wire[1:0] isCacheBypassLdUOp = {1'b0, 
    `ENABLE_EXT_MMIO && uopLd_0[0].valid && uopLd_0[0].isMMIO && uopLd_0[0].exception == AGU_NO_EXCEPTION &&
    uopLd_0[0].addr >= `EXT_MMIO_START_ADDR && uopLd_0[0].addr < `EXT_MMIO_END_ADDR};

wire isCacheBypassStUOp = 
    `ENABLE_EXT_MMIO && IN_uopSt.valid && IN_uopSt.isMMIO && 
    IN_uopSt.addr >= `EXT_MMIO_START_ADDR && IN_uopSt.addr < `EXT_MMIO_END_ADDR;

wire ignoreSt = isCacheBypassStUOp;

wire BLSU_stStall;
wire BLSU_ldStall;
LD_UOp BLSU_uopLd;
wire[31:0] BLSU_ldResult;
BypassLSU bypassLSU
(
    .clk(clk),
    .rst(rst),
    
    .IN_branch(IN_branch),
    .IN_uopLdEn(isCacheBypassLdUOp[0]),
    .OUT_ldStall(BLSU_ldStall),
    .IN_uopLd(uopLd_0[0]),

    .IN_uopStEn(isCacheBypassStUOp),
    .OUT_stStall(BLSU_stStall),
    .IN_uopSt(IN_uopSt),

    .IN_ldStall(ldOps[0][1].valid),
    .OUT_uopLd(BLSU_uopLd),
    .OUT_ldData(BLSU_ldResult),

    .OUT_memc(BLSU_memc),
    .IN_memc(IN_memc)
);

// During a cache table write cycle, we cannot issue a store as
// the cache table write port is the same as the store read port.
// Loads work fine but require write forwaring in the cache table.
wire[1:0] stall;
assign stall[0] = flushActive;
assign stall[1] = (OUT_stStall) || cacheTableWrite || flushActive;
assign OUT_stStall = (isCacheBypassStUOp ? BLSU_stStall : (cacheTableWrite || flushActive || (uopLd[1].valid && !uopLd[1].isMMIO && uopLd[1].exception == AGU_NO_EXCEPTION))) && IN_uopSt.valid;

LD_UOp LMQ_ld[`NUM_AGUS-1:0];
LD_UOp uopLd[`NUM_AGUS-1:0];
always_comb
    for (integer i = 0; i < `NUM_AGUS; i=i+1)
        OUT_uopLdSq[i] = uopLd_0[i];

ST_UOp uopSt;
assign uopSt = IN_uopSt;

// Both load and store read from cache table
always_comb begin
    IF_ct.re[0] = uopLd[0].valid && !uopLd[0].isMMIO && uopLd[0].exception == AGU_NO_EXCEPTION;
    IF_ct.raddr[0] = uopLd[0].addr[11:0];
    
    if (uopLd[1].valid && !uopLd[1].isMMIO && uopLd[1].exception == AGU_NO_EXCEPTION) begin
        IF_ct.re[1] = 1;
        IF_ct.raddr[1] = uopLd[1].addr[11:0];
    end
    else begin
        IF_ct.re[1] = uopSt.valid && !uopSt.isMMIO && !stall[1] && !ignoreSt;
        IF_ct.raddr[1] = uopSt.addr[11:0];
    end
    
    // During a flush, we read from the cache table at the flush iterator
    if (state == FLUSH_READ0) begin
        IF_ct.re[0] = 1;
        IF_ct.raddr[0] = {flushIdx, {`CLSIZE_E{1'b0}}};
    end
end

// Select load to execute
// 1. previous miss from load miss queue
// 2. special load (page walk, non-speculative or external)
// 3. regular load
always_comb begin
    for (integer i = 0; i < `NUM_AGUS; i=i+1) begin
        uopLd[i] = 'x;
        uopLd[i].valid = 0;

        OUT_ldStall[i] = IN_uopLd[i].valid;
        OUT_ldAGUStall[i] = IN_uopELd[i].valid;
        LMQ_dequeue[i] = 0;
        
        // Only addr[11:0] is well defined, the rest is 
        // still being calculated (for regular loads at least) and will
        // only be available in the next cycle.

        if (stall[0]) begin
            // do not issue load
        end
        else if (i == 1 && stOps[1].valid) begin
            // port is being used by store during store's write cycle
        end
        else if (LMQ_ld[i].valid && 
            (!IN_branch.taken || LMQ_ld[i].external || $signed(LMQ_ld[i].sqN - IN_branch.sqN) <= 0) &&
            (!IF_cache.busy[i] || IF_cache.rbusyBank[i] != LMQ_ld[i].addr[2 + $clog2(`CWIDTH) +: $clog2(`CBANKS)])
        ) begin
            uopLd[i] = LMQ_ld[i];
            LMQ_dequeue[i] = 1;
        end
        else if (IN_uopLd[i].valid &&
            (!IN_branch.taken || IN_uopLd[i].external || $signed(IN_uopLd[i].sqN - IN_branch.sqN) <= 0) &&
            (!IF_cache.busy[i] || IF_cache.rbusyBank[i] != IN_uopLd[i].addr[2 + $clog2(`CWIDTH) +: $clog2(`CBANKS)])
        ) begin
            uopLd[i] = IN_uopLd[i];
            OUT_ldStall[i] = 0;
        end
        else if (IN_uopELd[i].valid &&
            (!IF_cache.busy[i] || IF_cache.rbusyBank[i] != IN_uopELd[i].addr[2 + $clog2(`CWIDTH) +: $clog2(`CBANKS)])
        ) begin
            uopLd[i].valid = 1;
            uopLd[i].external = 0;
            uopLd[i].addr[11:0] = IN_uopELd[i].addr;

            uopLd[i].isMMIO = 0; // assume that this is not MMIO such that cache is read
            uopLd[i].exception = AGU_NO_EXCEPTION; // assume no exception

            OUT_ldAGUStall[i] = 0;
        end
    end
end

reg regularLd[`NUM_AGUS-1:0];
always_ff@(posedge clk)
    for (integer i = 0; i < `NUM_AGUS; i=i+1) begin
    if (rst) regularLd[i] <= 0;
    else regularLd[i] <= IN_uopELd[i].valid && !OUT_ldAGUStall[i];
end

LD_UOp uopLd_0[`NUM_AGUS-1:0];
always_comb begin
    for (integer i = 0; i < `NUM_AGUS; i=i+1) begin
        uopLd_0[i] = ldOps[i][0];

        // For regular loads, we only get the full address and other
        // info now.
        if (regularLd[i]) begin
            assert(rst || !IN_aguLd[i].valid || IN_aguLd[i].addr[11:0] == uopLd_0[i].addr[11:0]);
            uopLd_0[i] = 'x;
            uopLd_0[i].valid = 0;
            if (IN_aguLd[i].valid)
                uopLd_0[i] = IN_aguLd[i];
        end
    end
end

// Load from internal MMIO
// This is executed one cycle later than loads from cache
// as internal MMIO only has a read delay of one cycle.
always_comb begin
    IF_mmio.re = 1;
    IF_mmio.raddr = 'x;
    IF_mmio.rsize = 'x;

    if (uopLd_0[0].valid && uopLd_0[0].isMMIO && !isCacheBypassLdUOp[0]) begin
        IF_mmio.re = 0;
        IF_mmio.raddr = uopLd_0[0].addr;
        IF_mmio.rsize = uopLd_0[0].size;
    end
end

// Stores to internal MMIO are uncached, they run right away
always_comb begin
    IF_mmio.we = 1;
    IF_mmio.waddr = 'x;
    IF_mmio.wdata = 'x;
    IF_mmio.wmask = 'x;

    if (uopSt.valid && uopSt.isMMIO) begin
        IF_mmio.we = 0;
        IF_mmio.waddr = uopSt.addr;
        IF_mmio.wdata = uopSt.data;
        IF_mmio.wmask = uopSt.wmask;
    end
end

// delay lines, waiting for cache response
LD_UOp ldOps[`NUM_AGUS-1:0][1:0];
ST_UOp stOps[1:0];

reg loadWasExtIOBusy[`NUM_AGUS-1:0];

// Load Pipeline
always_ff@(posedge clk) begin

    for (integer i = 0; i < `NUM_AGUS; i=i+1)
        for (integer j = 0; j < 2; j=j+1) begin
            ldOps[i][j] <= 'x;
            ldOps[i][j].valid <= 0;
        end

    if (rst) ;
    else begin
        for (integer i = 0; i < `NUM_AGUS; i=i+1) begin
            // Progress the delay line
            if (uopLd[i].valid)
                ldOps[i][0] <= uopLd[i];
            
            if (uopLd_0[i].valid && (!IN_branch.taken || uopLd_0[i].external || $signed(uopLd_0[i].sqN - IN_branch.sqN) <= 0) &&
                // if the BLSU is busy, we place the OP in the Load Miss Queue.
                (!isCacheBypassLdUOp[i] || (BLSU_ldStall && i == 0))
            ) begin
                ldOps[i][1] <= uopLd_0[i];
                loadWasExtIOBusy[i] <= isCacheBypassLdUOp[i];
            end
        end
    end
end

reg[$clog2(`CASSOC)-1:0] assocCnt;

typedef enum logic[3:0]
{
    REGULAR, REGULAR_NO_EVICT, TRANS_IN_PROG, MGMT_CLEAN, MGMT_INVAL, MGMT_FLUSH, IO_BUSY, CONFLICT, SQ_CONFLICT
} MissType;

typedef struct packed
{
    logic[31:0] writeAddr;
    logic[31:0] missAddr;
    logic[$clog2(`CASSOC)-1:0] assoc;
    MissType mtype;
    logic valid;
} CacheMiss;

CacheMiss miss[1:0];

reg setDirty;
reg[$clog2(SIZE)-1:0] setDirtyIdx;
// Process Cache Table Read Responses
LD_UOp curLd[1:0];
always_comb begin
    setDirty = 0;
    setDirtyIdx = 'x;

    // Loads speculatively load from all possible locations
    for (integer i = 0; i < `NUM_AGUS; i=i+1) begin
        
        IF_cache.addr[i] = 'x;
        IF_cache.wassoc[i] = 'x;
        IF_cache.wdata[i] = 'x;
        IF_cache.wmask[i] = 'x;
        IF_cache.we[i] = 1;
        IF_cache.re[i] = 1;

        IF_cache.re[i] = !(uopLd[i].valid && !uopLd[i].isMMIO && uopLd[i].exception == AGU_NO_EXCEPTION);
        IF_cache.addr[i] = uopLd[i].addr[11:0];
    end

    for (integer i = 0; i < `NUM_AGUS; i=i+1) 
        OUT_uopLd[i] = RES_UOp'{valid: 0, default: 'x};

    for (integer i = 0; i < `NUM_AGUS; i=i+1) begin
        miss[i] = 'x;
        miss[i].valid = 0;
    end

    for (integer i = 0; i < `NUM_AGUS; i=i+1) begin

        // only one of these is valid
        LD_UOp ld = ldOps[i][1].valid ? ldOps[i][1] : BLSU_uopLd;
        ST_UOp st = (i == 1) ? stOps[1] : ST_UOp'{valid: 0, default: 'x};
        assert(!(ld.valid && st.valid));

        curLd[i] = ld;
        
        if (rst) ; // todo: really needed?
        else if (st.valid) begin
            reg cacheHit = 0;
            reg doCacheLoad = 1;
            reg[$clog2(`CASSOC)-1:0] cacheHitAssoc = 'x;
            reg noEvict = !IF_ct.rdata[i][assocCnt].valid;

            // check for hit in cache table
            for (integer j = 0; j < `CASSOC; j=j+1) begin
                if (IF_ct.rdata[i][j].valid && IF_ct.rdata[i][j].addr == st.addr[31:12]) begin
                    assert(!cacheHit); // multiple hits are invalid
                    doCacheLoad = 0;
                    cacheHit = 1;
                    cacheHitAssoc = j[$clog2(`CASSOC)-1:0];
                end
            end

            // check if address is already being transferred
            begin
                reg transferExists;
                reg allowPassThru;
                {allowPassThru, transferExists} = CheckTransfers(LSU_memc, IN_memc, 0, st.addr);
                if (transferExists) begin
                    doCacheLoad = 0; // this is only needed for one cycle
                    cacheHit &= allowPassThru;
                end
            end

            // check for conflict with currently issued MemC_Cmd
            if (cacheHit && 
                LSU_memc.cmd != MEMC_NONE && 
                LSU_memc.cacheAddr[`CACHE_SIZE_E-3:`CLSIZE_E-2] == {cacheHitAssoc, st.addr[11:`CLSIZE_E]}
            ) begin
                cacheHit = 0;
                doCacheLoad = 0;
                cacheHitAssoc = 'x;
            end
            
            if (stConflictMiss[1]) begin
                miss[1].valid = 1;
                miss[1].writeAddr = 'x;
                miss[1].missAddr = 'x;
                miss[1].assoc = 'x;
                miss[1].mtype = CONFLICT;
            end
            else if (st.isMMIO) begin
                // nothing to do for MMIO
            end
            else if (st.wmask == 0) begin
                // Management Ops
                if (cacheHit) begin
                    miss[1].valid = 1;
                    miss[1].writeAddr = st.addr;
                    miss[1].missAddr = st.addr;
                    miss[1].assoc = cacheHitAssoc;
                    case (st.data[1:0])
                        0: miss[1].mtype = MGMT_CLEAN;
                        1: miss[1].mtype = MGMT_INVAL;
                        2: miss[1].mtype = MGMT_FLUSH;
                        default: assert(0);
                    endcase
                end
            end
            else begin
                // Unlike loads, we can only run stores
                // now that we're sure they hit cache.
                if (cacheHit) begin
                    IF_cache.we[i] = 0;
                    IF_cache.re[i] = 0;
                    IF_cache.addr[i] = st.addr[11:0];
                    IF_cache.wassoc[i] = cacheHitAssoc;
                    IF_cache.wdata[i] = st.data;
                    IF_cache.wmask[i] = st.wmask;
                    setDirty = 1;
                    setDirtyIdx = {cacheHitAssoc, st.addr[11:`CLSIZE_E]};
                end
                else begin
                    miss[1].valid = 1;
                    miss[1].mtype = doCacheLoad ? (noEvict ? REGULAR_NO_EVICT : REGULAR) : TRANS_IN_PROG;
                    miss[1].writeAddr = {IF_ct.rdata[i][assocCnt].addr, st.addr[11:0]};
                    miss[1].missAddr = st.addr;
                    miss[1].assoc = assocCnt;
                end
            end
        end
        else if (ld.valid) begin
            reg isExtMMIO = !ld.valid;
            reg isIntMMIO = ld.valid && ld.isMMIO;
            reg noEvict = !IF_ct.rdata[i][assocCnt].valid;
            reg doCacheLoad = 1;

            reg cacheHit = 0;
            reg[31:0] readData = 'x;

            if (isExtMMIO) begin
                readData = BLSU_ldResult;
            end
            else if (isIntMMIO) begin
                readData = IF_mmio.rdata;
            end
            else begin
                for (integer j = 0; j < `CASSOC; j=j+1) begin
                    if (IF_ct.rdata[i][j].valid && IF_ct.rdata[i][j].addr == ld.addr[31:12]) begin
                        assert(!cacheHit); // multiple hits are invalid
                        cacheHit = 1;
                        doCacheLoad = 0;
                        readData = IF_cache.rdata[i][j];
                    end
                end
                
                // check if address is already being transferred
                begin
                    reg transferExists;
                    reg allowPassThru;
                    {allowPassThru, transferExists} = CheckTransfers(LSU_memc, IN_memc, 0, ld.addr);
                    if (transferExists) begin
                        doCacheLoad = 0;
                        cacheHit &= allowPassThru;
                    end
                end
                
                // don't care if cache is hit if this is a complete forward
                if (!(isExtMMIO || isIntMMIO) && IN_stFwd[i].mask == 4'b1111) begin
                    cacheHit = 1;
                    doCacheLoad = 0;
                end
            end

            if ((cacheHit || ld.exception != AGU_NO_EXCEPTION || isExtMMIO || isIntMMIO) && 
                (!loadWasExtIOBusy[i] || isExtMMIO) &&
                (ld.exception != AGU_NO_EXCEPTION || isExtMMIO || isIntMMIO || !IN_stFwd[i].conflict)
            ) begin
                // Use forwarded store data if available
                if (!(isExtMMIO || isIntMMIO)) begin
                    for (integer j = 0; j < 4; j=j+1) begin
                        if (IN_stFwd[i].mask[j]) readData[j*8+:8] = IN_stFwd[i].data[j*8+:8];
                    end
                end
                
                OUT_uopLd[i].valid = 1;
                OUT_uopLd[i].storeSqN = 'x;
                OUT_uopLd[i].tagDst = ld.tagDst;
                OUT_uopLd[i].sqN = ld.sqN;
                OUT_uopLd[i].doNotCommit = ld.doNotCommit;
                //OUT_uopLd.external = ld.external;
                
                case (ld.exception)
                    AGU_NO_EXCEPTION: OUT_uopLd[i].flags = FLAGS_NONE;
                    AGU_ADDR_MISALIGN: OUT_uopLd[i].flags = FLAGS_LD_MA;
                    AGU_ACCESS_FAULT: OUT_uopLd[i].flags = FLAGS_LD_AF;
                    AGU_PAGE_FAULT: OUT_uopLd[i].flags = FLAGS_LD_PF;
                endcase

                case (ld.size)
                    0: OUT_uopLd[i].result = 
                        {{24{ld.signExtend ? readData[8*(ld.addr[1:0])+7] : 1'b0}},
                        readData[8*(ld.addr[1:0])+:8]};

                    1: OUT_uopLd[i].result = 
                        {{16{ld.signExtend ? readData[16*(ld.addr[1])+15] : 1'b0}},
                        readData[16*(ld.addr[1])+:16]};

                    2: OUT_uopLd[i].result = readData;
                    default: assert(0);
                endcase
            end
            else begin
                miss[i].valid = 1;
                if (IN_stFwd[i].conflict)
                    miss[i].mtype = SQ_CONFLICT;
                else if (loadWasExtIOBusy[i])
                    miss[i].mtype = IO_BUSY;
                else if (doCacheLoad)
                    miss[i].mtype = noEvict ? REGULAR_NO_EVICT : REGULAR;
                else
                    miss[i].mtype = TRANS_IN_PROG;
                miss[i].writeAddr = {IF_ct.rdata[i][assocCnt].addr, ld.addr[11:0]};
                miss[i].missAddr = ld.addr;
                miss[i].assoc = assocCnt;
            end
        end
    end
end

// Store Pipeline
reg[1:0] stConflictMiss;
reg[1:0] stConflictMiss_c;
reg stallStConflict;
always_ff@(posedge clk) begin
    if (rst) begin
        for (integer i = 0; i < 2; i=i+1)
            stOps[i].valid <= 0;
        stallStConflict <= 0;
    end
    else begin
        reg uopStStall = (isCacheBypassStUOp ? BLSU_stStall : stall[1]);

        stOps[0] <= 'x;
        stOps[0].valid <= 0;
        stOps[1] <= 'x;
        stOps[1].valid <= 0;
        
        // While a store is stalled, accumulate occurring conflicts
        if (uopSt.valid && uopStStall)
            stallStConflict <= stallStConflict | stConflictMiss_c[0];
        else stallStConflict <= 0;
        
        // Progress the delay line
        if (uopSt.valid && !uopStStall) begin
            stOps[0] <= uopSt;
            stConflictMiss[0] <= stConflictMiss_c[0] || stallStConflict;
        end
        
        if (stOps[0].valid) begin
            stOps[1] <= stOps[0];
            stConflictMiss[1] <= stConflictMiss_c[1];
        end
    end
end

// Store Conflict Misses
always_comb begin
    stConflictMiss_c[0] = (redoStore &&
        ((stOps[1].addr[31:2] == uopSt.addr[31:2] && |(stOps[1].wmask & uopSt.wmask)) ||
            stOps[1].isMMIO && uopSt.isMMIO));

    stConflictMiss_c[1] = (redoStore &&
        ((stOps[1].addr[31:2] == stOps[0].addr[31:2] && |(stOps[1].wmask & stOps[0].wmask)) ||
            (stOps[1].isMMIO && stOps[0].isMMIO))) || 
        stConflictMiss[0];
end


// Cache Transfer State Machine
enum logic[3:0]
{
    IDLE, FLUSH, FLUSH_READ0, FLUSH_READ1, FLUSH_WAIT
} state;

reg LMQ_dequeue[1:0];

for (genvar i = 0; i < `NUM_AGUS; i=i+1) begin
    wire loadIsRegularMiss = curLd[i].valid && miss[i].valid && (!stOps[1].valid || i != 1) && miss[i].mtype != SQ_CONFLICT && miss[i].mtype != IO_BUSY;
    wire LMQ_full;
    wire LMQ_allowNewMisses = forwardMiss && !newMiss;
    LoadMissQueue#(`LD_MISS_QUEUE_SIZE) loadMissQueue
    (
        .clk(clk),
        .rst(rst),
        
        .IN_ready(LMQ_allowNewMisses),
        .IN_branch(IN_branch),
        
        .OUT_full(LMQ_full),

        .IN_memc(IN_memc),

        .IN_ld(curLd[i]),
        .IN_enqueue(loadIsRegularMiss),

        .OUT_ld(LMQ_ld[i]),
        .IN_dequeue(LMQ_dequeue[i])
    );
    always_comb begin
        OUT_ldAck[i] = 'x;
        OUT_ldAck[i].valid = 0;
        // We have to decide whether to place a missing load into the quick-to-react
        // load miss queue or back in the (slow) load buffer. If the LMQ is full, LB
        // is always chosen as fallback. Otherwise, regular misses are placed
        // in the LMQ.
        if (miss[i].valid && !stOps[1].valid &&
            (miss[i].mtype == SQ_CONFLICT ||
            miss[i].mtype == IO_BUSY ||
            (loadIsRegularMiss && LMQ_full))
        ) begin
            OUT_ldAck[i].valid = 1;
            OUT_ldAck[i].fail = 1;
            OUT_ldAck[i].external = curLd[i].external;
            OUT_ldAck[i].loadSqN = curLd[i].loadSqN;
        end
    end
end

wire redoStore = stOps[1].valid &&
    (miss[1].valid ?
        (miss[1].mtype == REGULAR || miss[1].mtype == REGULAR_NO_EVICT || miss[1].mtype == IO_BUSY || miss[1].mtype == CONFLICT || miss[1].mtype == TRANS_IN_PROG) : 
        (!stOps[1].isMMIO && IF_cache.busy[1]));

assign OUT_stAck.addr = stOps[1].addr;
assign OUT_stAck.data = stOps[1].data;
assign OUT_stAck.wmask = stOps[1].wmask;
assign OUT_stAck.id = stOps[1].id;
assign OUT_stAck.valid = stOps[1].valid;
assign OUT_stAck.fail = redoStore;


// Check for conflicts
logic[1:0] missEvictConflict;
always_comb begin
    for (integer i = 0; i < 2; i=i+1) begin
        missEvictConflict[i] = 0;
        
        // read after write
        for (integer j = 0; j < `AXI_NUM_TRANS; j=j+1) begin
            if (miss[i].valid &&
                IN_memc.transfers[j].valid &&
                IN_memc.transfers[j].writeAddr[31:`CLSIZE_E] == miss[i].missAddr[31:`CLSIZE_E]
            ) begin
                missEvictConflict[i] = 1;
            end
        end
        if ((LSU_memc.cmd == MEMC_REPLACE || LSU_memc.cmd == MEMC_CP_CACHE_TO_EXT) &&
            miss[i].valid && LSU_memc.writeAddr[31:`CLSIZE_E] == miss[i].missAddr[31:`CLSIZE_E])
            missEvictConflict[i] = 1;
        
        // write after read
        for (integer j = 0; j < `AXI_NUM_TRANS; j=j+1) begin
            if (miss[i].valid &&
                IN_memc.transfers[j].valid &&
                IN_memc.transfers[j].readAddr[31:`CLSIZE_E] == miss[i].writeAddr[31:`CLSIZE_E]
            ) begin
                missEvictConflict[i] = 1;
            end
        end
        if ((LSU_memc.cmd == MEMC_REPLACE || LSU_memc.cmd == MEMC_CP_EXT_TO_CACHE) &&
            miss[i].valid && LSU_memc.readAddr[31:`CLSIZE_E] == miss[i].writeAddr[31:`CLSIZE_E])
            missEvictConflict[i] = 1;

    end
end

// Cache Table Writes
reg cacheTableWrite;
reg newMiss;
always_comb begin
    reg temp = 0;
    cacheTableWrite = 0;
    IF_ct.we = 0;
    IF_ct.waddr = 'x;
    IF_ct.wassoc = 'x;
    IF_ct.wdata = 'x;
    newMiss = 0;
    
    if (!rst && state == IDLE) begin
        for (integer i = 0; i < 2; i=i+1) begin
            if (forwardMiss && !missEvictConflict[i] && miss[i].valid && !temp &&
                miss[i].mtype != IO_BUSY && miss[i].mtype != CONFLICT && miss[i].mtype != SQ_CONFLICT && miss[i].mtype != TRANS_IN_PROG) begin
                temp = 1;
                newMiss = 1;
                // Immediately write the new cache table entry (about to be loaded)
                // on a miss. We still need to intercept and pass through or stop
                // loads at the new address until the cache line is entirely loaded.
                case (miss[i].mtype)
                    REGULAR_NO_EVICT,
                    REGULAR: begin
                        IF_ct.we = 1;
                        IF_ct.waddr = miss[i].missAddr[11:0];
                        IF_ct.wassoc = miss[i].assoc;
                        IF_ct.wdata.addr = miss[i].missAddr[31:12];
                        IF_ct.wdata.valid = 1;
                        cacheTableWrite = 1;
                    end
                    
                    MGMT_INVAL,
                    MGMT_FLUSH: begin
                        IF_ct.we = 1;
                        IF_ct.waddr = miss[i].missAddr[11:0];
                        IF_ct.wassoc = miss[i].assoc;
                        IF_ct.wdata.addr = 0;
                        IF_ct.wdata.valid = 0;
                        cacheTableWrite = 1;
                    end
                    // MGMT_CLEAN does not modify cache table
                    default: ;
                endcase
            end
        end
    end
    else if (!rst && state == FLUSH) begin
        if (!flushDone) begin
            IF_ct.we = 1;
            IF_ct.waddr = {flushIdx, {`CLSIZE_E{1'b0}}};
            IF_ct.wassoc = flushAssocIdx;
            IF_ct.wdata.addr = 0;
            IF_ct.wdata.valid = 0;
            cacheTableWrite = 1;
        end
    end
end

// keep track of dirtyness here 
// (otherwise we would need a separate write port to cache table)
reg[SIZE-1:0] dirty;

reg flushQueued;
reg busy;
always_comb begin
    busy = 0;
    for (integer i = 0; i < `NUM_AGUS; i=i+1) begin
        if (uopLd[i].valid || uopSt.valid || uopLd_0[i].valid || curLd[i].valid || stOps[0].valid || stOps[1].valid || !IN_SQ_empty || (OUT_ldAck[i].valid && OUT_ldAck[i].fail) || (OUT_stAck.valid && OUT_stAck.fail)) busy = 1;
    end
end


wire flushReady = !busy;
wire flushActive = (
    state == FLUSH || state == FLUSH_WAIT ||
    state == FLUSH_READ0 || state == FLUSH_READ1);
assign OUT_busy = busy || flushQueued || flushActive;

reg flushDone;
reg[`CACHE_SIZE_E-`CLSIZE_E-$clog2(`CASSOC)-1:0] flushIdx;
reg[$clog2(`CASSOC)-1:0] flushAssocIdx;

// Cache<->Memory Transfer State Machine
CacheMiss curCacheMiss;
reg[$clog2(`CASSOC)-1:0] replaceAssoc;


wire forwardMiss = LSU_memc.cmd == MEMC_NONE || !IN_memc.stall[1];
always_ff@(posedge clk) begin
    
    if (LSU_memc.cmd == MEMC_NONE || !IN_memc.stall[1]) begin
        LSU_memc <= 'x;
        LSU_memc.cmd <= MEMC_NONE;
    end

    if (rst) begin
        state <= IDLE;
        replaceAssoc <= 0;
        flushQueued <= 1;
        LSU_memc <= 'x;
        LSU_memc.cmd <= MEMC_NONE;
    end
    else begin

        if (IN_flush) flushQueued <= 1;
        if (setDirty) dirty[setDirtyIdx] <= 1;

        case (state)
            IDLE: begin
                reg temp = 0;
                for (integer i = 0; i < 2; i=i+1) begin

                    reg[$clog2(SIZE)-1:0] missIdx = {miss[i].assoc, miss[i].missAddr[11:`CLSIZE_E]};
                    MissType missType = miss[i].mtype;

                    if (forwardMiss && !missEvictConflict[i] && miss[i].valid && !temp &&
                        miss[i].mtype != IO_BUSY && miss[i].mtype != CONFLICT && miss[i].mtype != SQ_CONFLICT && miss[i].mtype != TRANS_IN_PROG) begin
                        temp = 1;
                        curCacheMiss <= miss[i];
                        assocCnt <= assocCnt + 1;
                        
                        // if not dirty, do not copy back to main memory
                        if (missType == REGULAR && !dirty[missIdx] && (!setDirty || setDirtyIdx != missIdx))
                            missType = REGULAR_NO_EVICT;
                        
                        // new cache line is not dirty
                        dirty[missIdx] <= 0;
                        
                        case (missType)
                            REGULAR: begin
                                LSU_memc.cmd <= MEMC_REPLACE;
                                LSU_memc.cacheAddr <= {miss[i].assoc, miss[i].missAddr[11:2]};
                                LSU_memc.writeAddr <= {miss[i].writeAddr[31:12], miss[i].missAddr[11:2], 2'b0};
                                LSU_memc.readAddr <= {miss[i].missAddr[31:2], 2'b0};
                                LSU_memc.cacheID <= 0;
                            end

                            REGULAR_NO_EVICT: begin
                                LSU_memc.cmd <= MEMC_CP_EXT_TO_CACHE;
                                LSU_memc.cacheAddr <= {miss[i].assoc, miss[i].missAddr[11:2]};
                                LSU_memc.writeAddr <= 'x;
                                LSU_memc.readAddr <= {miss[i].missAddr[31:2], 2'b0};
                                LSU_memc.cacheID <= 0;
                            end

                            MGMT_CLEAN,
                            MGMT_FLUSH: begin
                                LSU_memc.cmd <= MEMC_CP_CACHE_TO_EXT;
                                LSU_memc.cacheAddr <= {miss[i].assoc, miss[i].missAddr[11:2]};
                                LSU_memc.writeAddr <= {miss[i].writeAddr[31:12], miss[i].missAddr[11:2], 2'b0};
                                LSU_memc.readAddr <= 'x;
                                LSU_memc.cacheID <= 0;
                            end
                            
                            default: ; // MGMT_INVAL does not evict the cache line
                        endcase
                    end
                end

                if (!temp) begin
                    if (flushQueued && flushReady) begin
                        state <= FLUSH_WAIT;
                        flushQueued <= 0;
                        flushIdx <= 0;
                        flushAssocIdx <= 0;
                        flushDone <= 0;
                    end
                end
            end
            
            FLUSH_WAIT: begin
                state <= FLUSH_READ0;
                if (LSU_memc.cmd != MEMC_NONE || BLSU_memc.cmd != MEMC_NONE)
                    state <= FLUSH_WAIT;
                for (integer i = 0; i < `AXI_NUM_TRANS; i=i+1)
                    if (IN_memc.transfers[i].valid) state <= FLUSH_WAIT;
            end
            FLUSH_READ0: begin
                state <= FLUSH_READ1;
            end
            FLUSH_READ1: begin
                state <= FLUSH;
            end
            FLUSH: begin
                if (flushDone) begin
                    state <= IDLE;
                end
                else if (LSU_memc.cmd == MEMC_NONE || !IN_memc.stall[1]) begin
                    CTEntry entry = IF_ct.rdata[0][flushAssocIdx];

                    if (entry.valid && dirty[{flushAssocIdx, flushIdx}]) begin
                        LSU_memc.cmd <= MEMC_CP_CACHE_TO_EXT;
                        LSU_memc.cacheAddr <= {flushAssocIdx, flushIdx, {(`CLSIZE_E-2){1'b0}}};
                        LSU_memc.writeAddr <= {entry.addr, flushIdx, {(`CLSIZE_E){1'b0}}};
                        LSU_memc.readAddr <= 'x;
                        LSU_memc.cacheID <= 0;
                    end
                    
                    {flushDone, flushIdx, flushAssocIdx} <= {flushIdx, flushAssocIdx} + 1;
                    if (&flushAssocIdx) state <= FLUSH_READ0;
                end
            end
            default: state <= IDLE;
        endcase
    end
end

endmodule
