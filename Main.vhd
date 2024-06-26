-- <pre> Telemetry Control Box (TCB) Transmitting Feedthrough Firmware

-- V1.1, 29-JUN-24: Implements a command transmitter backward compatible with 
-- the Command Transmitter (A3029C). This code works in conjunction with TCB 
-- base board firmware P3042BB V5.1. Reset of firmware by 512-us HI on TX. 
-- Receive sixteen-bit command on TX from base board. The rf_on command causes
-- an initializing pulse, but does not leave the RF turned on. The rf_off forces
-- off. The rf_xmit transmits eight bits. All command transmitters running
-- at the same time off the same negative true ON signals, no individual control.
-- Can set the digital input-outputs with separate commands. Transmit eight bits 
-- continuously on RX back to base board, carrying DB and ENB buses. Can turn on
-- one and only one transmitter module continuously for testing. When any other
-- instruction is received, this module will turn off.

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
		QB : inout std_logic_vector(4 downto 1); -- Digital Output Bus
		ENB_neg : out std_logic_vector(4 downto 1); -- Digital Output Enable Bus, Inverted
		DB_in : in std_logic_vector(4 downto 1); -- Digital Input Bus
		
		RST : out std_logic; -- Reset Output
		TP1, TP2, TP3, TP4 : out std_logic -- Test Points
	);	
	
	-- Instruction Op-Codes
	constant rf_off_op  : integer := 0; -- Turn off the RF transmitter.
	constant rf_on_op   : integer := 1; -- Turn on the RF transmitter.
	constant rf_xmit_op : integer := 2; -- Transmit a command byte.
	constant tm_test_op : integer := 3; -- Transmitter Module test.
	constant dio_en_op  : integer := 8; -- Enable or disable digital outputs.
	constant dio_set_op : integer := 9; -- Set or clear digital outputs.
end;

architecture behavior of main is

-- Functions and Procedures	
	function to_std_logic (v: boolean) return std_ulogic is
	begin if v then return('1'); else return('0'); end if; end function;
	
-- Positive True Signals
	signal ENB : std_logic_vector(4 downto 1) := (others => '0');
	signal ONB : std_logic_vector(16 downto 1) := (others => '0');
	
-- Synchronized Inputs
	signal DB : std_logic_vector(4 downto 1); -- Synchronized Digital Input Bus
	
-- Base Board Interface
	signal BBIWR : std_logic; -- Base Board Incoming Write
	signal BBIRD : std_logic; -- Base Board Incoming Read
	signal BBIEMPTY : std_logic; -- Base Board Incoming Buffer Empty
	signal BBIFULL : std_logic; -- Base Board Incoming Buffer Full
	signal bbi_in, bbi_out : std_logic_vector(15 downto 0); 
	
-- Instruction Processing
	signal CTXI : boolean; -- Command Transmit Initiate
	signal CTXD : boolean; -- Command Transmit Done
	signal SPI : boolean; -- Start Pulse Initiate
	signal SPD : boolean; -- Start Pulse Done
	signal RFTX : boolean; -- Radio Frequency Transmit Bit
	signal RFSP : boolean; -- Radio Frequency Start Pulse
	signal tm_sel : integer range 0 to 255; -- Transmitter Module Select
	
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
	
-- The Base Board Incoming is the buffer where the Base Board Receiver
-- writes sixteen-bit commands it receives from the Base Board. The
-- Instruction Processor checks BBIEMPTY to see if a byte is waiting.
	BB_Incoming : entity FIFO16
		port map (
			Data => bbi_in,
			WrClock => not SCK,
			RdClock => not SCK,
			WrEn => BBIWR,
			RdEn => BBIRD,
			Reset => RESET,
			RPReset => RESET,
			Q => bbi_out,
			Empty => BBIEMPTY,
			Full => BBIFULL
		);
	
	-- The Base Board Receiver receives sixteen-bit messages from the 
	-- Base Board and writes them into the Base Board Incoming buffer.
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
			bbi_in <= (others => '0');
		elsif rising_edge(SCK) then
		
			case state is
				when 1 =>
					bbi_in <= (others => '0');
				when 4 | 6 | 8 | 10 | 12 | 14 | 16 | 18 
						| 20 | 22 | 24 | 26 | 28 | 30 | 32 | 34 => 
					bbi_in(15 downto 1) <= bbi_in(14 downto 0);
					bbi_in(0) <= FTX; 
				when others => bbi_in <= bbi_in;
			end case;
			
			BBIWR <= '0';
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
					BBIWR <= '1';
					state := 0;
				when others =>
					state := state + 1;
			end case;
		end if;
	end process;
	
	-- The Base Board Transmitter transmits the state of the digital
	-- inputs to the base board using an eight-bit serial word. It 
	-- uses RX and SCK to generate the signal. Transmission takes place 
	-- at 1 MBPS. The RX signal is usually LO, so we begin with 2 us of 
	-- guaranteed LO for set-up, then a 1-us HI for a start bit, and the 
	-- eight data bits, 1 us each. The transmitter repeats every 256 us,
	-- taking 11 us per transmission.
	BB_Transmitter : process (SCK,RESET) is 
	variable state : integer range 0 to 255;
	begin
		if (RESET = '1') then
			state := 0;
		elsif rising_edge(SCK) then
			case state is
				when 4 => RX <= '1';
				when 5 => RX <= '1';
				when 6 => RX <= ENB(4);
				when 7 => RX <= ENB(4);
				when 8 => RX <= ENB(3);
				when 9 => RX <= ENB(3);
				when 10 => RX <= ENB(2);
				when 11 => RX <= ENB(2);
				when 12 => RX <= ENB(1);
				when 13 => RX <= ENB(1);
				when 14 => RX <= DB(4);
				when 15 => RX <= DB(4);
				when 16 => RX <= DB(3);
				when 17 => RX <= DB(3);
				when 18 => RX <= DB(2);
				when 19 => RX <= DB(2);
				when 20 => RX <= DB(1);
				when 21 => RX <= DB(1);
				when others => RX <= '0';
			end case;
			
			state := state + 1;
		end if;
	end process;	
	
	-- The Instruction Processor reads sixteen-bit words out of the
	-- Base Board Incoming buffer, decodes the opcode in the lower seven
	-- bits, uses the upper eight bits as the operand, and executes
	-- each instruction. Bit seven, the eighth bit, is always one for
	-- a valid opcode.
	Instruction_Processor : process (SCK,RESET) is 
	variable state : integer range 0 to 15;
	begin
		if (RESET = '1') then
			state := 0;
			CTXI <= false;
			SPI <= false;
			BBIRD <= '0';
			ENB <= (others => '0');
			QB <= (others => '0');
			tm_sel <= 0;
		elsif rising_edge(SCK) then
			case state is
				-- Detect instruction waiting, read instruction.
				when 0 => 
					CTXI <= false;
					SPI <= false;
					if (BBIEMPTY = '0') then
						BBIRD <= '1';
						state := 1;
					else 
						BBIRD <= '0';
						state := 0;
					end if;
				-- Examine the opcode in the lower eight bits of the
				-- instruction. Start execution or abort.
				when 1 =>
					tm_sel <= 0;
					BBIRD <= '0';
					case to_integer(unsigned(bbi_out(6 downto 0))) is
						when rf_off_op =>
							state := 0;
						when rf_on_op =>
							SPI <= true;
							state := 2;
						when rf_xmit_op =>
							CTXI <= true;
							state := 4;
						when tm_test_op =>
							tm_sel <= to_integer(unsigned(bbi_out(15 downto 8)));
							state := 0;
						when dio_en_op =>
							ENB <= bbi_out(11 downto 8);
							state := 0;
						when dio_set_op =>
							QB <= bbi_out(11 downto 8);
							state := 0;
						when others =>
							state := 0;
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
				when 5 to 8 => RFTX <= bbi_out(15) = '1';
				when 9 to 12 => RFTX <= bbi_out(14) = '1';
				when 13 to 16 => RFTX <= bbi_out(13) = '1';
				when 17 to 20 => RFTX <= bbi_out(12) = '1';
				when 21 to 24 => RFTX <= bbi_out(11) = '1';
				when 25 to 28 => RFTX <= bbi_out(10) = '1';
				when 29 to 32 => RFTX <= bbi_out(9) = '1';
				when 33 to 36 => RFTX <= bbi_out(8) = '1';
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
		
		for i in 1 to 16 loop 
			ONB(i) <= to_std_logic(RFTX or RFSP or (i = tm_sel)); 
		end loop;
	end process;

	-- Outputs with and without inversion.
	ENB_neg <= not ENB;
	ONB_neg <= not ONB;
	RCK_out <= RCK;
	
	-- Test points, including keepers for unused inputs. 
	TP1 <= to_std_logic(tm_sel /= 0); 
	TP2 <= to_std_logic(CTXI);
	TP3 <= BBIRD; 
	TP4 <= DB(1) xor DB(2) xor DB(3) xor DB(4); 
end behavior;