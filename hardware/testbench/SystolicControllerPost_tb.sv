`timescale 1ns/1ps
module SystolicControllerPost_tb;
    logic clk=0,rst=1,start=0,out_ready=0;
    logic [13:0] k_words=1;
    logic [3:0] active_rows=1,active_cols=1;
    logic post_bank_available=0,tile_bank=0;
    logic [7:0] post_out_valid=0;
    logic post_out_last=0,post_out_bank=0;
    wire start_ready,busy,config_error,feed_valid,capture_en,out_valid;
    wire buffer_rd_en,array_rst,array_en;
    wire [13:0] buffer_addr;
    wire [7:0] post_in_valid;
    wire [2:0] post_in_row[0:7];
    wire post_in_bank,post_in_last;
    wire signed [7:0] a[0:7],b[0:7];
    wire signed [31:0] acc[0:7][0:7];
    int seen[0:7][0:7];
    int groups=0, count=0, finals=0, enabled=0;
    SystolicController dut(.*);
    SystolicArray array_dut(.clk(clk),.rst(array_rst),.en(array_en),.clear(1'b0),
                            .inputA(a),.inputB(b),.arrayAcc(acc));
    for(genvar c=0;c<8;c++) begin
        assign a[c]=(feed_valid && c<active_rows) ? 8'sd1 : 8'sd0;
        assign b[c]=(feed_valid && c<active_cols) ? 8'sd1 : 8'sd0;
    end
    always #5 clk=~clk;
    // Observe at the same edge a postprocessor would capture these MACs.
    always @(posedge clk) if(!rst) begin
        if(capture_en) $fatal(1,"Legacy capture asserted in post mode");
        if(|post_in_valid) begin
            for(int c=0;c<8;c++) if(post_in_valid[c]) begin
                if(c>=active_cols || post_in_row[c]>=active_rows)
                    $fatal(1,"Invalid lane tag");
                if(post_in_row[c]+c != groups) $fatal(1,"Wrong diagonal");
                if(enabled != k_words+groups) $fatal(1,"Early/late diagonal issue");
                if(acc[post_in_row[c]][c] !== $signed({18'd0,k_words}))
                    $fatal(1,"Captured incomplete MAC sum");
                if(post_in_bank !== tile_bank) $fatal(1,"Wrong bank");
                seen[post_in_row[c]][c]++;
                count++;
            end
            groups++;
        end
        if(post_in_last) finals++;
        if(array_en) enabled++;
    end
    task automatic run_case(input int k,r,c,delay_cycles);
        @(negedge clk);
        for(int y=0;y<8;y++) for(int x=0;x<8;x++) seen[y][x]=0;
        groups=0; count=0; finals=0; enabled=0;
        k_words=k; active_rows=r; active_cols=c; tile_bank=~tile_bank;
        post_bank_available=1; start=1;
        @(negedge clk); start=0; post_bank_available=0;
        // Reservation belongs to this tile even when no other bank is free.
        while(finals==0) @(negedge clk);
        if(groups!=r+c-1 || count!=r*c || finals!=1)
            $fatal(1,"Missing/duplicate diagonals");
        for(int y=0;y<8;y++) for(int x=0;x<8;x++)
            if(seen[y][x] != ((y<r && x<c)?1:0)) $fatal(1,"Coverage failure");
        repeat(delay_cycles) begin
            @(negedge clk);
            if(out_valid || array_en || (|post_in_valid)) $fatal(1,"Did not wait");
        end
        post_out_valid=8'h01; post_out_last=1; post_out_bank=~tile_bank;
        @(negedge clk);
        if(out_valid) $fatal(1,"Accepted wrong bank");
        post_out_bank=tile_bank;
        @(negedge clk);
        post_out_valid=0; post_out_last=0;
        if(!out_valid) $fatal(1,"Completion not recognized");
        repeat(2) begin @(negedge clk); if(!out_valid) $fatal(1,"Did not hold output"); end
        out_ready=1;
        @(negedge clk); out_ready=0;
        if(busy || start_ready) $fatal(1,"Bank availability not enforced");
        $display("PASS K=%0d R=%0d C=%0d delay=%0d: completed MACs, tags, bank, completion",k,r,c,delay_cycles);
    endtask
    initial begin
        repeat(2) @(negedge clk); rst=0;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        if(busy || start_ready) $fatal(1,"Started without reserved bank");
        run_case(1,1,1,1);
        run_case(1,1,8,5);
        run_case(1,8,1,9);
        run_case(2,2,2,5);
        run_case(27,8,3,5);
        run_case(27,1,3,1);
        run_case(16,8,8,9);
        $display("PASS: diagonal controller tests");
        $finish;
    end
    initial begin #100000; $fatal(1,"Timeout"); end
endmodule
