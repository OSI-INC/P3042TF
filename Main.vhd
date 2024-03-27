-- <pre> Telemetry Control Box (TCB) Transmitting Feedthrough Firmware

-- V1.1, 27-MAR-24: 

-- Global constants and types.  
library ieee;  
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity main is 
	port (
		FCK : in std_logic; -- Fast (10 MHz) Clock
		SCK_in : in std_logic; -- Slow (32.768 kHz) Clock
		
		TL_in : in std_logic; -- Transmit Logic from Base Board
		RL : out std_logic; -- Receive Logic to Base Board
		
		ONB : out std_logic_vector(16 downto 1); -- Transmit ON Bus
		QB : out std_logic_vector(4 downto 1); -- Digital Output Bus
		ENB : out std_logic_vector(4 downto 1); -- Digital Output Enable Bus
		DB_in : in std_logic_vector(4 downto 1); -- Digital Input Bus
		
		RST : out std_logic; -- Reset Output
		TP1, TP2, TP3, TP4 : out std_logic -- Test Points
	);	
end;

architecture behavior of main is

-- Attributes to guide the compiler.
	attribute syn_keep : boolean;
	attribute nomerge : string;
		
-- General-Purpose Constant
	constant max_data_byte : std_logic_vector(7 downto 0) := "11111111";
	constant high_z_byte : std_logic_vector(7 downto 0) := "ZZZZZZZZ";
	constant zero_data_byte : std_logic_vector(7 downto 0) := "00000000";
	constant one_data_byte : std_logic_vector(7 downto 0) := "00000001";

-- Functions and Procedures	
	function to_std_logic (v: boolean) return std_ulogic is
	begin if v then return('1'); else return('0'); end if; end function;
	
-- Synchronized Inputs
	signal TL : std_logic; -- Synchronized Transmit Logic
	signal DB : std_logic_vector(4 downto 1); -- Synchronized Digital Input Bus
	signal SCK : std_logic; -- Synchronized Slow Clock
	
-- Management Signals
	signal RESET : boolean; -- RESET

begin

	-- The Input Processor provides synchronized versions of incoming 
	-- signals and positive-polarity versions too.
	Input_Processor : process (FCK) is
	begin
		if rising_edge(FCK) then
			DB <= DB_in;
			TL <= to_std_logic(TL_in = '1');
			SCK <= SCK_in;
		end if;
	end process;
	
	-- The Reset Arbitrator generates the reset signal when TL remains LO for
	-- more than 39 ms.
	Reset_Arbitrator : process (SCK) is
	constant reset_len : integer := 256;
	variable count, next_count : integer range 0 to reset_len-1;
	variable initiate : boolean;
	begin
		if rising_edge(SCK) then
			next_count := count;
			if (TL = '1') then 
				next_count := 0;
			else
				if (count /= reset_len - 1) then
					next_count := count + 1;
					RESET <= false;
				else 
					RESET <= true;
				end if;
			end if;
			count := next_count;
		end if;
		
		RST <= to_std_logic(RESET);
	end process;
	
	ONB <= (others => '0');
	QB <= (others => '0');
	ENB <= (others => '0');
	RL <= '0';
	
	-- Test points. 
	TP1 <= FCK; 
	TP2 <= TL;
	TP3 <= to_std_logic(RESET); 
	TP4 <= DB(1) xor DB(2)xor DB(3) xor DB(4); 
end behavior;