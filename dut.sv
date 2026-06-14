module dut #(
    parameter int DRAM_ADDRESS_WIDTH = 32,
    parameter int SRAM_ADDRESS_WIDTH = 10,
    parameter int DRAM_DQ_WIDTH = 8,
    parameter int SRAM_DATA_WIDTH = 32,
    parameter int FIFO_DEPTH_OF_THE_OUTPUT = 2048
)(
    // System Signals
    input  wire                             clk,
    input  wire                             reset_n,
    
    // Control signals
    input  wire                             start,
    output wire                             ready,

    // DRAM Input memory interface
    output wire [1:0]                       input_CMD, // 2'b00=IDLE, 2'b01=READ, 2'b10=WRITE
    output wire [DRAM_ADDRESS_WIDTH-1:0]    input_addr,
    input  wire [DRAM_DQ_WIDTH-1:0]         input_dout,
    output wire [DRAM_DQ_WIDTH-1:0]         input_din,
    output wire                             input_oe,

    // DRAM Output memory interface
    output wire [1:0]                       output_CMD, // 2'b00=IDLE, 2'b01=READ, 2'b10=WRITE
    output wire [DRAM_ADDRESS_WIDTH-1:0]    output_addr,
    input  wire [DRAM_DQ_WIDTH-1:0]         output_dout,
    output wire [DRAM_DQ_WIDTH-1:0]         output_din,
    output wire                             output_oe,

    // Port A: Read Port
    output reg [SRAM_ADDRESS_WIDTH-1:0]     read_address,
    input  wire [SRAM_DATA_WIDTH-1:0]       read_data,
    output reg                              read_enable,
    
    // Port B: Write Port
    output reg [SRAM_ADDRESS_WIDTH-1:0]     write_address,
    output reg [SRAM_DATA_WIDTH-1:0]        write_data,
    output reg                              write_enable
);

    // DRAM and SRAM signals
    localparam [1:0] COMMAND_IDLE  = 2'b00;
    localparam [1:0] COMMAND_READ  = 2'b01;
    localparam [1:0] COMMAND_WRITE = 2'b10;
    localparam int WRITE_LATENCY = 4;

    // Logical FSM for convolution, leaky relu and avergae pooling
    typedef enum logic [3:0] { 
        IDLE_STATE, 
        DATA_READING_STATE, 
        COMPUTE_CONVOLUTION_STATE, 
        COMPUTE_AVERAGE_POOLING_STATE 
    } state_t;
    state_t state;
    
    // Write FSM logic
    typedef enum logic [2:0] { 
	    WRITE_IDLE, 
	    WRITE_COMMAND, 
	    W_LATENCY, 
	    WRITE_DATA, 
	    WRITE_INC 
    } write_state_t;
    write_state_t write_state;

    reg ready_reg;
    assign ready = ready_reg;

    // assigning the values of the module paramenters to inter module defined
    // registers
    reg [1:0] input_CMD_reg;
    reg [DRAM_ADDRESS_WIDTH-1:0] input_addr_reg;
    reg [DRAM_DQ_WIDTH-1:0] input_din_reg;
    reg input_oe_reg;
    assign input_CMD  = input_CMD_reg;
    assign input_addr = input_addr_reg;
    assign input_din  = input_din_reg;
    assign input_oe   = input_oe_reg;

    reg [1:0] output_CMD_reg;
    reg [DRAM_ADDRESS_WIDTH-1:0] output_addr_reg;
    reg [DRAM_DQ_WIDTH-1:0] output_din_reg;
    reg output_oe_reg;
    assign output_CMD  = output_CMD_reg;
    assign output_addr = output_addr_reg;
    assign output_din  = output_din_reg;
    assign output_oe   = output_oe_reg;

    // Dimensions used in the program
    localparam int image_rows = 1024;
    localparam int image_columns = 1024;
    localparam int num_of_kernel_matrix_bytes = 16;

    localparam logic [31:0] read_address_of_kernel_matrix = 32'h00000000;
    localparam logic [31:0] read_address_of_input  = 32'h00000010;
    localparam logic [31:0] base_address_of_output = 32'h00000000;

    logic signed [7:0] kernel_matrix [0:3][0:3]; 
    logic signed [7:0] buffer_matrix [0:4][0:image_columns-1]; 

    logic [2:0] index_of_burst_byte;
    logic [7:0] num_of_burst_bytes [0:7];

    logic kernel_matrix_done;
    logic matrix_done;
    reg additional_processing_completed; 

    int row, col; 
    reg [3:0] command_counter;
    reg [3:0] latency_counter;
    reg [31:0] address_of_the_next_instance;
    reg [20:0] counting_data_bytes;

    reg printing_flag_of_kernel_matrix;
    int circular_row_ptr;
    int num_of_valid_rows;
    reg [31:0] physical_row_index [0:4]; 

    logic signed [31:0] leaky_relu_out [0:1][0:image_columns-3]; 
    
    localparam int OUTPUT_FIFO_POINTER_WIDTH = $clog2(FIFO_DEPTH_OF_THE_OUTPUT);
    localparam int OUTPUT_FIFO_MASK = FIFO_DEPTH_OF_THE_OUTPUT - 1;

    logic [7:0] output_fifo_memory [0:FIFO_DEPTH_OF_THE_OUTPUT-1];
    logic [OUTPUT_FIFO_POINTER_WIDTH-1:0] output_write_ptr; 
    logic [OUTPUT_FIFO_POINTER_WIDTH-1:0] output_read_ptr; 
    
    reg [31:0] current_write_base_address; 
    reg [31:0] dynamic_write_address; 
    reg [3:0] write_latency_counter;
    reg [3:0] write_burst_counter;

    int compute_value;
    int avg_pooling_j;
    int current_conv_row; 
    int buffer_index;
    
    
    reg [2:0] current_physical_start_ptr; // Tracks current_conv_row % 5
    logic [3:0] physical_index_calculate;

    function automatic logic [OUTPUT_FIFO_POINTER_WIDTH-1:0] index_of_fifo(input logic [OUTPUT_FIFO_POINTER_WIDTH+31:0] index_no);
        index_of_fifo = index_no[OUTPUT_FIFO_POINTER_WIDTH-1:0] & OUTPUT_FIFO_MASK[OUTPUT_FIFO_POINTER_WIDTH-1:0];
    endfunction

    // FSM logic
    always_ff @(posedge clk or negedge reset_n) 
    begin
        integer i, index_no, r, c, kr, kc, physical_index_number, required_row, write_row;
        integer absolute_index_number, absolute_row, absolute_column, cc, j;
        logic signed [31:0] convolution_value;
        logic signed [31:0] leaky_relu_value;
        integer c0, c1;
        logic signed [31:0] raw_average_pool_value;      
        logic signed [7:0]  final_average_pool_value; 
        integer loop_var;

        logic [OUTPUT_FIFO_POINTER_WIDTH-1:0] pointer_diff;
        logic [OUTPUT_FIFO_POINTER_WIDTH:0] counter_for_fifo; 
        logic [OUTPUT_FIFO_POINTER_WIDTH-1:0] write_index_number_of_fifo;

        if (!reset_n) 
	begin
            state <= IDLE_STATE;
            ready_reg <= 1;
            input_CMD_reg <= COMMAND_IDLE;
            input_addr_reg <= 0;
            input_oe_reg <= 0;
            output_CMD_reg <= COMMAND_IDLE;
            output_addr_reg <= 0;
            output_din_reg <= 0;
            output_oe_reg <= 0;
            index_of_burst_byte <= 0;
            command_counter <= 0;
            latency_counter <= 0;
            kernel_matrix_done <= 0;
            matrix_done <= 0;
            additional_processing_completed <= 0;
            address_of_the_next_instance <= read_address_of_kernel_matrix;
            counting_data_bytes <= 0;
            row <= 0;
            col <= 0;
            printing_flag_of_kernel_matrix <= 0;
            circular_row_ptr <= 0;
            num_of_valid_rows <= 0;
            for (i = 0; i < 5; i = i + 1) physical_row_index[i] <= 32'hFFFF_FFFF;
            output_write_ptr <= '0;
            output_read_ptr <= '0;
            current_write_base_address <= base_address_of_output;
            write_state <= WRITE_IDLE;
            write_latency_counter <= 0;
            write_burst_counter <= 0;
            dynamic_write_address <= 0;
            compute_value <= 0;
            avg_pooling_j <= 0;
            current_conv_row <= 0;
            buffer_index <= 0;
            current_physical_start_ptr <= 0;
        end 
	else 
	begin
            pointer_diff = output_write_ptr - output_read_ptr;
            counter_for_fifo = pointer_diff;

            // Write FSM (Parallel)
            case (write_state)
                WRITE_IDLE: 
		begin
                    output_CMD_reg <= COMMAND_IDLE;
                    output_oe_reg <= 0;
                    if (counter_for_fifo >= 8 || (additional_processing_completed && counter_for_fifo > 0)) 
		    begin
                        write_state <= WRITE_COMMAND;
                    end
                end
                WRITE_COMMAND: 
		begin
                    output_CMD_reg <= COMMAND_WRITE;
                    output_addr_reg <= current_write_base_address; 
                    dynamic_write_address <= current_write_base_address;
                    write_latency_counter <= 0;
                    write_state <= W_LATENCY;
                end
                W_LATENCY: 
		begin
                    output_CMD_reg <= COMMAND_IDLE;
                    if (write_latency_counter < WRITE_LATENCY - 1) 
			    write_latency_counter <= write_latency_counter + 1;
                    else 
		    begin 
		    	    write_burst_counter <= 0; 
			    write_state <= WRITE_DATA; 
		    end
                end
                WRITE_DATA: 
		begin
                    output_oe_reg <= 1;
                    output_addr_reg <= dynamic_write_address;
                    if (counter_for_fifo > (7 - write_burst_counter)) 
		    begin
                        output_din_reg <= output_fifo_memory[index_of_fifo(output_read_ptr + (7 - write_burst_counter))];
                    end 
		    else 
		    begin
                        output_din_reg <= 8'h00; 
                    end
                    dynamic_write_address <= dynamic_write_address + 1;
                    write_burst_counter <= write_burst_counter + 1;
                    if (write_burst_counter == 7) 
			    write_state <= WRITE_INC; 
                end
                WRITE_INC: 
		begin
                    output_oe_reg <= 0;
                    current_write_base_address <= current_write_base_address + 8;
                    if (counter_for_fifo >= 8) 
			    output_read_ptr <= output_read_ptr + 8; 
                    else 
			    output_read_ptr <= output_read_ptr + counter_for_fifo; 
                    write_state <= WRITE_IDLE;
                end
            endcase

            // Main Processing FSM
            case(state)
                IDLE_STATE: 
		begin
                    if (start && ready_reg) 
		    begin
                        state <= DATA_READING_STATE;
                        ready_reg <= 0;
                        input_CMD_reg <= COMMAND_READ;
                        input_addr_reg <= read_address_of_kernel_matrix;
                        address_of_the_next_instance <= read_address_of_kernel_matrix + 8;
                        command_counter <= 0;
                        latency_counter <= 0;
                        index_of_burst_byte <= 0;
                        counting_data_bytes <= 0;
                        kernel_matrix_done <= 0;
                        matrix_done <= 0;
                        additional_processing_completed <= 0;
                        row <= 0;
                        col <= 0;
                        circular_row_ptr <= 0;
                        num_of_valid_rows <= 0;
                        for (i = 0; i < 5; i = i + 1) physical_row_index[i] <= 32'hFFFF_FFFF;
                        output_write_ptr <= '0;
                        output_read_ptr <= '0;
                        current_write_base_address <= base_address_of_output;
                        current_physical_start_ptr <= 0;
                    end
                end

                DATA_READING_STATE: 
		begin
                    if (additional_processing_completed && write_state == WRITE_IDLE && output_write_ptr == output_read_ptr) 
		    begin
                         ready_reg <= 1;
                         output_oe_reg <= 0;
                         output_CMD_reg <= COMMAND_IDLE;
                         state <= IDLE_STATE;
                    end

                    if (matrix_done && !additional_processing_completed) 
		    begin
                        current_conv_row <= row - 4;
                        buffer_index <= (row - 4) % 2;
                        
                        if (circular_row_ptr == 4) 
				current_physical_start_ptr <= 0;
                        else 
				current_physical_start_ptr <= circular_row_ptr + 1;

                        compute_value <= 0;
                        avg_pooling_j <= 0;
                        input_CMD_reg <= COMMAND_IDLE; 
                        state <= COMPUTE_CONVOLUTION_STATE;
                    end
                    else if (!matrix_done || !kernel_matrix_done) 
		    begin
                        if (command_counter == 7) 
			begin
                            input_CMD_reg <= COMMAND_READ;
                            input_addr_reg <= address_of_the_next_instance;
                            address_of_the_next_instance <= address_of_the_next_instance + 8;
                            command_counter <= 0;
                        end 
			else 
			begin
                            input_CMD_reg <= COMMAND_IDLE;
                            command_counter <= command_counter + 1;
                        end
                    end 
		    else 
		    begin
                        input_CMD_reg <= COMMAND_IDLE;
                    end

                    if (latency_counter < 5) 
			    latency_counter <= latency_counter + 1;
                    else if (latency_counter == 5) 
		    begin
                        input_oe_reg <= 1'b0;
                        latency_counter <= latency_counter + 1;
                    end 
		    else 
		    begin
                        num_of_burst_bytes[index_of_burst_byte] <= input_dout;
                        index_of_burst_byte <= index_of_burst_byte + 1;

                        if (index_of_burst_byte == 7) 
			begin
                            if (!kernel_matrix_done) 
			    begin
                                for (i = 0; i < 8; i = i + 1) 
				begin
                                    index_no = counting_data_bytes + i;
                                    r = index_no / 4; c = index_no % 4;
                                    if (i == 0) 
					    kernel_matrix[r][c] <= input_dout;
                                    else    
					    kernel_matrix[r][c] <= num_of_burst_bytes[7-i];
                                end
                                counting_data_bytes <= counting_data_bytes + 8;
                                if (counting_data_bytes + 8 >= num_of_kernel_matrix_bytes) 
				begin
                                    kernel_matrix_done <= 1;
                                    printing_flag_of_kernel_matrix <= 1;
                                    input_addr_reg <= read_address_of_input;
                                    address_of_the_next_instance <= read_address_of_input + 8;
                                    row <= 0; col <= 0;
                                end
                            end
                            else if (!matrix_done) 
			    begin
                                write_row = circular_row_ptr;
                                for (i = 0; i < 8; i = i + 1) 
				begin
                                    absolute_index_number = row * image_columns + col + i;
                                    absolute_row = absolute_index_number / image_columns; absolute_column = absolute_index_number % image_columns;
                                    if (absolute_row < image_rows) 
				    begin
                                        if (i == 0) 
						buffer_matrix[write_row][absolute_column] <= input_dout;
                                        else    
						buffer_matrix[write_row][absolute_column] <= num_of_burst_bytes[7-i];
                                    end
                                end

                                if (col + 8 >= image_columns) 
				begin
                                    physical_row_index[write_row] <= row;
                                    
                                    if (circular_row_ptr == 4) 
					    circular_row_ptr <= 0;
                                    else 
					    circular_row_ptr <= circular_row_ptr + 1;

                                    row <= row + 1; col <= 0;
                                    if (num_of_valid_rows < 5) 
					    num_of_valid_rows <= num_of_valid_rows + 1;

                                    if (num_of_valid_rows >= 4) 
				    begin
                                        current_conv_row <= row - 4;
                                        buffer_index <= (row - 4) % 2;
                                        
                                        if (circular_row_ptr == 4) 
						current_physical_start_ptr <= 0;
                                        else 
						current_physical_start_ptr <= circular_row_ptr + 1;

                                        if ((row - 4) >= 0) 
					begin
                                            compute_value <= 0;
                                            avg_pooling_j <= 0;
                                            state <= COMPUTE_CONVOLUTION_STATE;
                                            input_CMD_reg <= COMMAND_IDLE; 
                                        end
                                    end
                                end 
				else 
				begin
                                    col <= col + 8;
                                end
                                index_of_burst_byte <= 0;
                                if (row >= image_rows) 
					matrix_done <= 1;
                            end
                        end
                    end
                end

                COMPUTE_CONVOLUTION_STATE: 
		begin
                    input_CMD_reg <= COMMAND_IDLE; 

                    if (compute_value < image_columns-3) 
		    begin
                        convolution_value = 0;
                        for (kr = 0; kr < 4; kr = kr + 1) 
			begin
                            required_row = current_conv_row + kr;
                            
                            physical_index_calculate = current_physical_start_ptr + kr;
                            if (physical_index_calculate >= 5) 
				    physical_index_number = physical_index_calculate - 5;
                            else 
				    physical_index_number = physical_index_calculate;
                            
                            for (kc = 0; kc < 4; kc = kc + 1)
                                convolution_value += buffer_matrix[physical_index_number][compute_value + kc] * kernel_matrix[kr][kc];
                        end
                        if (convolution_value > 0) 
				leaky_relu_value = convolution_value;
                        else if (convolution_value <= -4) 
				leaky_relu_value = (convolution_value + 3) >>> 2; 
                        else 
				leaky_relu_value = 0;
                        
                        leaky_relu_out[buffer_index][compute_value] = leaky_relu_value;
                        if (compute_value == image_columns-4) 
				leaky_relu_out[buffer_index][image_columns-3] = 0;
                        
                        compute_value <= compute_value + 1;
                    end 
		    else 
		    begin
                        if ((current_conv_row % 2 == 1) && (current_conv_row != image_rows-4)) 
			begin
                            state <= COMPUTE_AVERAGE_POOLING_STATE;
                            avg_pooling_j <= 0;
                        end 
                        else if (matrix_done && current_conv_row == image_rows - 4) 
			begin
                            if (current_conv_row % 2 == 0) 
			    begin
                                for (loop_var = 0; loop_var <= image_columns-3; loop_var = loop_var + 1) leaky_relu_out[1][loop_var] = 0;
                                state <= COMPUTE_AVERAGE_POOLING_STATE;
                                avg_pooling_j <= 0;
                            end 
			    else 
			    begin
                                additional_processing_completed <= 1;
                                
                                state <= DATA_READING_STATE;
                                latency_counter <= 0;
                                command_counter <=0;
                                input_CMD_reg <= COMMAND_READ;
                                input_addr_reg <= read_address_of_input + (row << 10); 
                                address_of_the_next_instance <= read_address_of_input + (row << 10) + 8;
                            end
                        end
                        else 
			begin
                            state <= DATA_READING_STATE;
                            latency_counter <= 0;
                            command_counter <= 0;
                            input_CMD_reg <= COMMAND_READ;
                            input_addr_reg <= read_address_of_input + (row << 10); 
                            address_of_the_next_instance <= read_address_of_input + (row << 10) + 8;
                        end
                    end
                end

                COMPUTE_AVERAGE_POOLING_STATE: 
		begin
                     input_CMD_reg <= COMMAND_IDLE;

                     if (avg_pooling_j <= image_columns-4) 
		     begin
                        c0 = avg_pooling_j; 
                        c1 = (avg_pooling_j+1 <= image_columns-4) ? (avg_pooling_j+1) : (image_columns-3);
                        raw_average_pool_value = (leaky_relu_out[0][c0] + leaky_relu_out[0][c1] + leaky_relu_out[1][c0] + leaky_relu_out[1][c1]);
                        
                        if (raw_average_pool_value > 0)       
				raw_average_pool_value = raw_average_pool_value >>> 2;
                        else if (raw_average_pool_value <= -4) 
				raw_average_pool_value = (raw_average_pool_value + 3) >>> 2;
                        else    
	    			raw_average_pool_value = 0;

                        if (raw_average_pool_value > 32'sd127) 
				final_average_pool_value = 8'sd127;
                        else if (raw_average_pool_value < -32'sd128) 
				final_average_pool_value = -8'sd128;
                        else 
				final_average_pool_value = raw_average_pool_value[7:0];
                        
                        write_index_number_of_fifo = index_of_fifo(output_write_ptr + (avg_pooling_j >> 1));
                        output_fifo_memory[write_index_number_of_fifo] <= final_average_pool_value;
                        
                        avg_pooling_j <= avg_pooling_j + 2;
                     end 
		     else 
		     begin
                        output_fifo_memory[index_of_fifo(output_write_ptr + ((image_columns-2) >> 1))] <= 8'h00;
                        output_write_ptr <= output_write_ptr + ((image_columns-2) >> 1) + 1; 

                        if (current_conv_row == image_rows - 4) 
				additional_processing_completed <= 1;
                        
                        
                        state <= DATA_READING_STATE;
                        latency_counter <= 0;
                        command_counter <= 0;
                        input_CMD_reg <= COMMAND_READ;
                        input_addr_reg <= read_address_of_input + (row << 10); 
                        address_of_the_next_instance <= read_address_of_input + (row << 10) + 8;
                     end
                end
            endcase
        end
    end
endmodule
