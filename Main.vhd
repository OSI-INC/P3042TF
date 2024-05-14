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
	constant reset_len : integer := 256;

-- Functions and Procedures	
	function to_std_logic (v: boolean) return std_ulogic is
	begin if v then return('1'); else return('0'); end if; end function;
	
-- Positive True Signals
	signal RFTX : std_logic := '0';
	signal ENB : std_logic_vector(4 downto 1) := (others => '0');
	
-- Synchronized Inputs
	signal TX : std_logic; -- Synchronized Transmit Logic
	signal DB : std_logic_vector(4 downto 1); -- Synchronized Digital Input Bus
	
-- Management Signals
	signal RESET : boolean; -- RESET
	signal RCK : std_logic; -- Slow Clock (32.768 kHz)

begin

	-- The PLL produces 32.794 kHz for RCK. The perfect value is 32.768 kHz. This RCK 
	-- is synchronous with FCK.
	Clock : entity PLL port map (
		CLKI => FCK,
		CLKOS3 => RCK
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
	
	-- Outputs with and without inversion.
	ENB_neg <= not ENB;
	RCK_out <= RCK;
	
	-- Test points, including keepers for unused inputs. 
	TP1 <= FCK; 
	TP2 <= RCK;
	TP3 <= TX; 
	TP4 <= DB(1) xor DB(2) xor DB(3) xor DB(4) xor TX; 
end behavior;