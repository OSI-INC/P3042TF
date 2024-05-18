-- <pre> Telemetry Control Box (TCB) Transmitting Feedthrough Firmware

-- V1.1, 27-MAR-24: 

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
	constant reset_len : integer := 256;

-- Functions and Procedures	
	function to_std_logic (v: boolean) return std_ulogic is
	begin if v then return('1'); else return('0'); end if; end function;
	
-- Positive True Signals
	signal RFTX : std_logic := '0';
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
	signal bb_in, bb_in_waiting : std_logic_vector(15 downto 0); 
	signal bb_out: std_logic_vector(7 downto 0);
	
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
	-- more than reset_len RCK periods. So long as TX remains high thereafter, 
	-- so does RESET remain asserted. As soon as TX is LO on a rising edge of 
	-- RCK, RESET will be unasserted for at least reset_len RCK periods. With
	-- reset_len = 256, the reset detection period is 39 ms.
	Reset_Arbitrator : process (RCK) is
	variable count, next_count : integer range 0 to reset_len-1;
	begin
		if rising_edge(RCK) then
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
			Q => bb_in_waiting,
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

	-- Temporary assignments for transmitter module control.
	Mod_CK : process (RCK) is
	variable count : integer range 0 to 15;
	begin
		if rising_edge(RCK) then
			if (count < 8) then
				RFTX <= '0';
			else
				RFTX <= '0';
			end if;
			count := count + 1;
		end if;
		for i in 1 to 16 loop ONB_neg(i) <= not RFTX; end loop;
	end process;
	
	-- Temporary assignments for digital input-output.
	QB <= (others => RCK);
	ENB <= (others => '1');
	
	-- Temporary assignments for serial bus.
	RX <= TX;
	BBRRD <= '1';
	
	-- Outputs with and without inversion.
	ENB_neg <= not ENB;
	RCK_out <= RCK;
	
	-- Test points, including keepers for unused inputs. 
	TP1 <= SCK; 
	TP2 <= RCK;
	TP3 <= bb_in_waiting(0); 
	TP4 <= DB(1) xor DB(2) xor DB(3) xor DB(4) xor TX; 
end behavior;