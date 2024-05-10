-- <pre> Telemetry Control Box (TCB) Transmitting Feedthrough Firmware

-- V1.1, 27-MAR-24: 

-- Global constants and types.  
library ieee;  
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity main is 
	port (
		FCK : in std_logic; -- Fast (10 MHz) Clock In
		SCK_out : out std_logic; -- Slow (32.768 kHz) Clock Out
		
		TX_in : in std_logic; -- Transmit Logic from Base Board
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
	signal ONB : std_logic_vector(16 downto 1):= (others => '0');
	signal ENB : std_logic_vector(4 downto 1) := (others => '0');
	
-- Synchronized Inputs
	signal TX : std_logic; -- Synchronized Transmit Logic
	signal DB : std_logic_vector(4 downto 1); -- Synchronized Digital Input Bus
	
-- Management Signals
	signal RESET : boolean; -- RESET
	signal SCK : std_logic; -- Slow Clock (32.768 kHz)

begin

	-- The PLL produces 32.794 kHz for SCK. The perfect value is 32.768 kHz. This SCK 
	-- is synchronous with FCK.
	Clock : entity PLL port map (
		CLKI => FCK,
		CLKOS3 => SCK
	);

	-- The Input Processor provides synchronized versions of incoming 
	-- signals and positive-polarity versions too.
	Input_Processor : process (FCK) is
	begin
		if rising_edge(FCK) then
			DB <= DB_in;
			TX <= to_std_logic(TX_in = '1');
		end if;
	end process;
	
	-- The Reset Arbitrator generates the reset signal when TL remains HI for
	-- more than 39 ms.
	Reset_Arbitrator : process (SCK) is
	constant reset_len : integer := 256;
	variable count, next_count : integer range 0 to reset_len-1;
	variable initiate : boolean;
	begin
		if rising_edge(SCK) then
			next_count := count;
			if (TX = '0') then 
				next_count := 0;
				RESET <= false;
			else
				if (count < reset_len - 1) then
					next_count := count + 1;
					RESET <= false;
				else 
					next_count := count;
					RESET <= true;
				end if;
			end if;
			count := next_count;
		end if;
		
		RST <= to_std_logic(RESET);
	end process;
	
	-- Temporary assignments for transmitter module control.
	Mod_CK : process (SCK) is
	variable count : integer range 0 to 15;
	begin
		if rising_edge(SCK) then
			if (count < 8) then
				ONB <= (others => '0');
			else
				ONB <= (others => '1');
			end if;
			count := count + 1;
		end if;
	end process;
	
	-- Temporary assignments for digital input-output.
	QB <= (others => '1');
	ENB <= (others => '0');
	
	-- Temporary assignments for serial bus.
	RX <= '0';
	
	-- Outputs with inversion as needed.
	ENB_neg <= not ENB;
	ONB_neg <= not ONB;
	SCK_out <= SCK;
	
	-- Test points. 
	TP1 <= FCK; 
	TP2 <= SCK;
	TP3 <= TX; 
	TP4 <= DB(1) xor DB(2)xor DB(3) xor DB(4) xor TX; 
end behavior;