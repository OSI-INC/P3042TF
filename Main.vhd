-- <pre> Telemetry Control Box (TCB) Transmitting Feedthrough Firmware

-- V1.1, 20-MAY-24: Implements a command transmitter backward compatible with 
-- the Command Transmitter (A3029C). This code works in conjunction with TCB 
-- base board firmware P3042BB V5.1. Logic outputs enabled and driven with 
-- reference clock. Serial line back to base board driven LO. Reset of 
-- firmware by 512-us HI on TX.

-- Global constants and types.  
library ieee;  
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity main is 
	port (
		FCK : in std_logic; -- Fast Clock In (10 MHz) 
		RCK_out : out std_logic; -- Reference Clock Out (32.768 kHz)
		
		TX : in std_logic; -- Transmit Logic from Base Board
		RX : out std_logic; -- Receive Logic to Base Board
		
		ONB_neg : out std_logic_vector(16 downto 1); -- Transmit ON Bus, Inverted
		QB : out std_logic_vector(4 downto 1); -- Digital Output Bus
		ENB_neg : out std_logic_vector(4 downto 1); -- Digital Output Enable Bus, Inverted
		DB_in : in std_logic_vector(4 downto 1); -- Digital Input Bus
		
		RST : out std_logic; -- Reset Output
		TP1, TP2, TP3, TP4 : out std_logic -- Test Points
	);	
end;

architecture behavior of main is

-- Attributes to guide the compiler.
	attribute syn_keep : boolean;
	attribute nomerge : string;
		
-- General-Purpose Constants
	constant max_data_byte : std_logic_vector(7 downto 0) := "11111111";
	constant high_z_byte : std_logic_vector(7 downto 0) := "ZZZZZZZZ";
	constant zero_data_byte : std_logic_vector(7 downto 0) := "00000000";
	constant one_data_byte : std_logic_vector(7 downto 0) := "00000001";

-- Functions and Procedures	
	function to_std_logic (v: boolean) return std_ulogic is
	begin if v then return('1'); else return('0'); end if; end function;
	
-- Positive True Signals
	signal ENB : std_logic_vector(4 downto 1) := (others => '0');
	
-- Synchronized Inputs
	signal DB : std_logic_vector(4 downto 1); -- Synchronized Digital Input Bus
	
-- Base Board Interface
	signal BBXWR : std_logic; -- Base Board Transmit Write
	signal BBXRD : std_logic; -- Base Board Transmit Read
	signal BBXEMPTY : std_logic; -- Base Board Transmit Buffer Empty
	signal BBXFULL : std_logic; -- Base Board Transmit Buffer Full
	signal BBRWR : std_logic; -- Base Board Receiver Write
	signal BBRRD : std_logic; -- Base Board Receiver Read
	signal BBREMPTY : std_logic; -- Base Board Receiver Buffer Empty
	signal BBRFULL : std_logic; -- Base Board Receiver Buffer Full
	signal bb_in, bb_in_buff : std_logic_vector(15 downto 0); 
	signal bb_out: std_logic_vector(7 downto 0);
	
-- Instruction Processing
	signal CTXI : boolean; -- Command Transmit Initiate
	signal CTXD : boolean; -- Command Transmit Done
	signal SPI : boolean; -- Start Pulse Initiate
	signal SPD : boolean; -- Start Pulse Done
	signal RFTX : boolean; -- Radio Frequency Transmit Bit
	signal RFSP : boolean; -- Radio Frequency Start Pulse
	
-- Management Signals
	signal RESET : std_logic; -- RESET
	signal RCK : std_logic; -- Real-Time Clock (32.768 kHz)
	signal SCK :std_logic; -- Serial Interface Clock (2 MHz)

begin

	-- The Clock Generator produces 32.794 kHz for RCK and 2.000 MHz for SCK. It uses one
	-- of the integrated phase locked loops provided by the logic chip.
	Clock_Generator : entity PLL port map (
		CLKI => FCK,
		CLKOS2 => SCK,
		CLKOS3 => RCK
	);
	
	-- The Input Processor provides synchronized versions of incoming 
	-- signals and positive-polarity versions too.
	Input_Processor : process (FCK) is
	begin
		if rising_edge(FCK) then
			DB <= DB_in;
		end if;
	end process;
	
	-- The Reset Arbitrator generates the reset signal when TX remains HI for
	-- more than reset_len SCK periods. So long as TX remains high thereafter, 
	-- so does RESET remain asserted. As soon as TX is LO on a rising edge of 
	-- RCK, RESET will be unasserted for at least reset_len RCK periods. With
	-- reset_len = 1024, the reset detection period is 512 us.
	Reset_Arbitrator : process (SCK) is
	constant reset_len : integer := 1024;
	variable count, next_count : integer range 0 to reset_len-1;
	begin
		if rising_edge(SCK) then
			next_count := count;
			if (TX = '0') then 
				next_count := 0;
				RESET <= '0';
			else
				if (count < reset_len - 1) then
					next_count := count + 1;
					RESET <= '0';
				else 
					next_count := count;
					RESET <= '1';
				end if;
			end if;
			count := next_count;
		end if;
		
		RST <= RESET;
	end process;
	
-- The Base Board Input Buffer (BBI Buffer) is where the Base Board  
-- Receiver writes sixteen-bit commands as it receives them from the-- Base Board. We check BBREMPTY to see if a byte is waiting.
	BBI_Buffer : entity FIFO16
		port map (
			Data => bb_in,
			WrClock => not SCK,
			RDClock => not SCK,
			WrEn => BBRWR,
			RdEn => BBRRD,
			Reset => RESET,
			RPReset => RESET,
			Q => bb_in_buff,
			Empty => BBREMPTY,
			Full => BBRFULL
		);
	
	-- The Base Board Receiver receives sixteen-bit messages from the 
	-- Base Board and writes them into the BBI buffer.
	BB_Receiver : process (SCK,RESET) is
	variable state : integer range 0 to 255;
	variable FTX, RTX : std_logic;
	begin
		if falling_edge(SCK) then
			FTX := TX;
		end if;
		if rising_edge(SCK) then
			RTX := TX;
		end if;
		
		if (RESET = '1') then
			state := 0;
			bb_in <= (others => '0');
		elsif rising_edge(SCK) then
		
			case state is
				when 1 =>
					bb_in <= (others => '0');
				when 4 | 6 | 8 | 10 | 12 | 14 | 16 | 18 
						| 20 | 22 | 24 | 26 | 28 | 30 | 32 | 34 => 
					bb_in(15 downto 1) <= bb_in(14 downto 0);
					bb_in(0) <= FTX; 
				when others => bb_in <= bb_in;
			end case;
			
			BBRWR <= '0';
			case state is 
				when 0 => 
					if (RTX = '0') then
						state := 1;
					else 
						state := 0;
					end if;
				when 1 =>
					if (RTX = '0') then
						state := 2;
					else 
						state := 0;
					end if;
				when 2 =>
					if (RTX = '1') then 
						state := 3; 
					else
						state := 2;
					end if;
				when 36 =>
					BBRWR <= '1';
					state := 0;
				when others =>
					state := state + 1;
			end case;
		end if;
	end process;
	
	-- The Instruction Processor reads a sixteen-bit word out of the
	-- base board receive buffer, decodes the opcode in its lower eight
	-- bits and executes the opcode.
	Instruction_Processor : process (SCK,RESET) is 
	variable state : integer range 0 to 15;
	begin
		if (RESET = '1') then
			state := 0;
			CTXI <= false;
			SPI <= false;
			BBRRD <= '0';
		elsif rising_edge(SCK) then
			case state is
				when 0 => 
					CTXI <= false;
					SPI <= false;
					if (BBREMPTY = '0') then
						BBRRD <= '1';
						state := 1;
					else 
						BBRRD <= '0';
						state := 0;
					end if;
				when 1 =>
					BBRRD <= '0';
					case bb_in_buff(1 downto 0) is
						when "00" =>
							CTXI <= false;
							SPI <= false;
							state := 0;
						when "01" =>
							CTXI <= false;
							SPI <= true;
							state := 2;
						when "10" =>
							CTXI <= true;
							SPI <= false;
							state := 4;
					end case;
				when 2 =>
					CTXI <= false;
					SPI <= true;
					if SPD then
						state :=3;
					else
						state := 2;
					end if;
				when 3 =>
					CTXI <= false;
					SPI <= false;
					if not SPD then
						state := 0;
					else
						state := 3;
					end if;
				when 4 =>
					CTXI <= true;
					SPI <= false;
					if CTXD then 
						state := 5;
					else
						state := 4;
					end if;
				when 5 =>
					CTXI <= false;
					SPI <= false;
					if not CTXD then
						state := 0;
					else 
						state := 5;
					end if;
				when others =>
					CTXI <= false;
					SPI <= false;
					state := 0;
			end case;		
		end if;
	end process;
	
	-- The Command Transmitter transmit eight bits of command content
	-- by means of a start bit, eight data bits, and two stop bits.
	Command_Transmitter : process (RCK,RESET) is
	variable state, next_state : integer range 0 to 63;
	variable count : integer range 0 to 255;
	begin
		if (RESET = '1') then
			state := 0;
			count := 0;
			RFTX <= false;
			RFSP <= false;
			CTXD <= false;
			SPD <= false;
		elsif rising_edge(RCK) then
			next_state := state + 1;
			CTXD <= false;
			SPD <= false;
			case state is 
				when 0 => 
					RFTX <= false;
					if not CTXI then next_state := 0; end if;
				when 1 to 4 =>
					RFTX <= true;
				when 5 to 8 => RFTX <= bb_in_buff(15) = '1';
				when 9 to 12 => RFTX <= bb_in_buff(14) = '1';
				when 13 to 16 => RFTX <= bb_in_buff(13) = '1';
				when 17 to 20 => RFTX <= bb_in_buff(12) = '1';
				when 21 to 24 => RFTX <= bb_in_buff(11) = '1';
				when 25 to 28 => RFTX <= bb_in_buff(10) = '1';
				when 29 to 32 => RFTX <= bb_in_buff(9) = '1';
				when 33 to 36 => RFTX <= bb_in_buff(8) = '1';
				when 37 to 52 => RFTX <= false;
				when others =>
					RFTX <= false;
					CTXD <= true;
					if not CTXI then 
						next_state := 0; 
					else
						next_state := state;
					end if;
			end case;
			state := next_state;
			
			if (count > 0) and (count < 164) then
				RFSP <= true;
			else
				RFSP <= false;
			end if;
			
			if (count = 0) then
				if SPI then
					count := 1;
				else 
					count := 0;
				end if;
			elsif (count = 180) then
				SPD <= true;
				if not SPI then
					count := 0;
				else
					count := count;
				end if;
			else
				count := count + 1;
			end if;
		end if;
		
		for i in 1 to 16 loop ONB_neg(i) <= 
			to_std_logic((not RFTX) and (not RFSP)); end loop;
	end process;

	-- Temporary assignments for digital input-output.
	QB <= (others => RCK);
	ENB <= (others => '1');
	
	-- Temporary assignments for serial bus.
	RX <= '0';
	
	-- Outputs with and without inversion.
	ENB_neg <= not ENB;
	RCK_out <= RCK;
	
	-- Test points, including keepers for unused inputs. 
	TP1 <= to_std_logic(CTXD); 
	TP2 <= to_std_logic(CTXI);
	TP3 <= BBRRD; 
	TP4 <= DB(1) xor DB(2) xor DB(3) xor DB(4) xor TX; 
end behavior;