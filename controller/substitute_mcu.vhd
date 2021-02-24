library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity substitute_mcu is
	generic (
		debug : boolean := false;
		sysclk_frequency : integer := 1000 -- Sysclk frequency * 10
	);
	port (
		clk 			: in std_logic;
		reset_in 	: in std_logic;
		reset_out   : out std_logic;

		-- SPI signals
		spi_miso		: in std_logic := '1'; -- Allow the SPI interface not to be plumbed in.
		spi_clk		: out std_logic;
		spi_cs 		: out std_logic;
		spi_mosi    : out std_logic;
		spi_toguest : out std_logic;
		spi_fromguest : in std_logic;
		spi_ss2 : out std_logic;
		spi_ss3 : out std_logic;
		spi_ss4 : out std_logic;
		conf_data0 : out std_logic;
		spi_ack : in std_logic := '1';
		
		-- PS/2 signals
		ps2k_clk_in : in std_logic := '1';
		ps2k_dat_in : in std_logic := '1';
		ps2k_clk_out : out std_logic;
		ps2k_dat_out : out std_logic;
		ps2m_clk_in : in std_logic := '1';
		ps2m_dat_in : in std_logic := '1';
		ps2m_clk_out : out std_logic;
		ps2m_dat_out : out std_logic;

		-- Joysticks and other inputs
		
		joy1 : in std_logic_vector(7 downto 0) := "11111111";
		joy2 : in std_logic_vector(7 downto 0) := "11111111";
		joy3 : in std_logic_vector(7 downto 0) := "11111111";
		joy4 : in std_logic_vector(7 downto 0) := "11111111";
		
		menu_button : in std_logic :='1';
		
		-- UART
		rxd	: in std_logic;
		txd	: out std_logic
);
end entity;

architecture rtl of substitute_mcu is

constant sysclk_hz : integer := sysclk_frequency*1000;
constant uart_divisor : integer := sysclk_hz/1152;
constant maxAddrBit : integer := 31;

signal reset_n : std_logic := '0';
signal reset_counter : unsigned(15 downto 0) := X"FFFF";

-- Millisecond counter
signal millisecond_counter : unsigned(31 downto 0) := X"00000000";
signal millisecond_tick : unsigned(19 downto 0);


-- SPI Clock counter
signal spi_tick : unsigned(8 downto 0);
signal spiclk_in : std_logic;
signal spi_fast : std_logic;
signal spi_cs_int : std_logic;

-- SPI signals
signal host_to_spi : std_logic_vector(7 downto 0);
signal spi_to_host : std_logic_vector(7 downto 0);
signal spi_trigger : std_logic;
signal spi_busy : std_logic;
signal spi_active : std_logic;

signal spi_fromguest_sd : std_logic;
signal spi_mosi_int : std_logic;

-- UART signals

signal ser_txdata : std_logic_vector(7 downto 0);
signal ser_txready : std_logic;
signal ser_rxdata : std_logic_vector(7 downto 0);
signal ser_rxrecv : std_logic;
signal ser_txgo : std_logic;
signal ser_rxint : std_logic;


-- Interrupt signals

constant int_max : integer := 2;
signal int_triggers : std_logic_vector(int_max downto 0);
signal int_status : std_logic_vector(int_max downto 0);
signal int_ack : std_logic;
signal int_req : std_logic;
signal int_enabled : std_logic :='0'; -- Disabled by default
signal int_trigger : std_logic;


-- Timer register block signals

signal timer_reg_req : std_logic;
signal timer_tick : std_logic;


-- PS2 signals
signal ps2_int : std_logic;

signal kbdidle : std_logic;
signal kbdrecv : std_logic;
signal kbdrecvreg : std_logic;
signal kbdsendbusy : std_logic;
signal kbdsendtrigger : std_logic;
signal kbdsenddone : std_logic;
signal kbdsendbyte : std_logic_vector(7 downto 0);
signal kbdrecvbyte : std_logic_vector(10 downto 0);

signal mouseidle : std_logic;
signal mouserecv : std_logic;
signal mouserecvreg : std_logic;
signal mousesendbusy : std_logic;
signal mousesenddone : std_logic;
signal mousesendtrigger : std_logic;
signal mousesendbyte : std_logic_vector(7 downto 0);
signal mouserecvbyte : std_logic_vector(10 downto 0);


-- CPU signals

signal soft_reset_n : std_logic;
signal mem_busy : std_logic;
signal mem_rom : std_logic;
signal rom_ack : std_logic;
signal from_mem : std_logic_vector(31 downto 0);
signal cpu_addr : std_logic_vector(31 downto 0);
signal to_cpu : std_logic_vector(31 downto 0);
signal from_cpu : std_logic_vector(31 downto 0);
signal from_rom : std_logic_vector(31 downto 0);
signal cpu_req : std_logic; 
signal cpu_ack : std_logic; 
signal cpu_wr : std_logic; 
signal cpu_bytesel : std_logic_vector(3 downto 0);
signal mem_rd : std_logic; 
signal mem_wr : std_logic; 
signal rom_wr : std_logic;
signal mem_rd_d : std_logic; 
signal mem_wr_d : std_logic; 
signal cache_valid : std_logic;
signal flushcaches : std_logic;

-- ROM upload signals
signal uploading : std_logic;
signal upload_addr : unsigned(24 downto 0);
signal upload_data : std_logic_vector(7 downto 0);
signal upload_req : std_logic;
signal upload_ack : std_logic;

-- CPU Debug signals
signal debug_req : std_logic;
signal debug_ack : std_logic;
signal debug_fromcpu : std_logic_vector(31 downto 0);
signal debug_tocpu : std_logic_vector(31 downto 0);
signal debug_wr : std_logic;

-- Remapped joystick data
signal joy1_r : std_logic_vector(7 downto 0);
signal joy2_r : std_logic_vector(7 downto 0);
signal joy3_r : std_logic_vector(7 downto 0);
signal joy4_r : std_logic_vector(7 downto 0);

begin

-- Remap joystick data;
joy1_r(7 downto 4) <= not joy1(7 downto 4);
joy2_r(7 downto 4) <= not joy2(7 downto 4);
joy3_r(7 downto 4) <= not joy3(7 downto 4);
joy4_r(7 downto 4) <= not joy4(7 downto 4);
joy1_r(3 downto 0) <= not (joy1(0)&joy1(1)&joy1(2)&joy1(3));
joy2_r(3 downto 0) <= not (joy2(0)&joy2(1)&joy1(2)&joy1(3));
joy3_r(3 downto 0) <= not (joy3(0)&joy3(1)&joy1(2)&joy1(3));
joy4_r(3 downto 0) <= not (joy4(0)&joy4(1)&joy1(2)&joy1(3));

-- Reset counter.

process(clk)
begin
	if reset_in='0' then -- or sdr_ready='0' then
		reset_counter<=X"FFFF";
		reset_n<='0';
	elsif rising_edge(clk) then
		reset_counter<=reset_counter-1;
		if reset_counter=X"0000" then
			reset_n<='1';
		end if;
	end if;
end process;

reset_out<=reset_n;

-- Timer
process(clk)
begin
	if rising_edge(clk) then
		millisecond_tick<=millisecond_tick+1;
		if millisecond_tick=sysclk_frequency*100 then
			millisecond_counter<=millisecond_counter+1;
			millisecond_tick<=X"00000";
		end if;
	end if;
end process;


-- UART

myuart : entity work.simple_uart
	generic map(
		enable_tx=>true,
		enable_rx=>true
	)
	port map(
		clk => clk,
		reset => reset_n, -- active low
		txdata => ser_txdata,
		txready => ser_txready,
		txgo => ser_txgo,
		rxdata => ser_rxdata,
		rxint => ser_rxint,
		txint => open,
		clock_divisor => X"016c", -- 42MHz / 115,200 bps
		rxd => rxd,
		txd => txd
	);


-- PS2 devices

	mykeyboard : entity work.io_ps2_com
		generic map (
			clockFilter => 15,
			ticksPerUsec => sysclk_frequency/10
		)
		port map (
			clk => clk,
			reset => not reset_n, -- active high!
			ps2_clk_in => ps2k_clk_in,
			ps2_dat_in => ps2k_dat_in,
			ps2_clk_out => ps2k_clk_out,
			ps2_dat_out => ps2k_dat_out,
			
			inIdle => open,	-- Probably don't need this
			sendTrigger => kbdsendtrigger,
			sendByte => kbdsendbyte,
			sendBusy => kbdsendbusy,
			sendDone => kbdsenddone,
			recvTrigger => kbdrecv,
			recvByte => kbdrecvbyte
		);


	mymouse : entity work.io_ps2_com
		generic map (
			clockFilter => 15,
			ticksPerUsec => sysclk_frequency/10
		)
		port map (
			clk => clk,
			reset => not reset_n, -- active high!
			ps2_clk_in => ps2m_clk_in,
			ps2_dat_in => ps2m_dat_in,
			ps2_clk_out => ps2m_clk_out,
			ps2_dat_out => ps2m_dat_out,
			
			inIdle => open,	-- Probably don't need this
			sendTrigger => mousesendtrigger,
			sendByte => mousesendbyte,
			sendBusy => mousesendbusy,
			sendDone => mousesenddone,
			recvTrigger => mouserecv,
			recvByte => mouserecvbyte
		);


-- SPI Timer
process(clk)
begin
	if rising_edge(clk) then
		spiclk_in<='0';
		spi_tick<=spi_tick+1;
		if (spi_fast='1' and spi_tick(3)='1') or spi_tick(6)='1' then
			spiclk_in<='1'; -- Momentary pulse for SPI host.
			spi_tick<='0'&X"00";
		end if;
	end if;
end process;


-- SPI host
spi : entity work.spi_controller
	port map(
		sysclk => clk,
		reset => reset_n,

		-- Host interface
		spiclk_in => spiclk_in,
		host_to_spi => host_to_spi,
		spi_to_host => spi_to_host,
		trigger => spi_trigger,
		busy => spi_busy,

		-- Hardware interface
		miso => spi_fromguest_sd,
		mosi => spi_mosi_int,
		ack => spi_ack,
		spiclk_out => spi_clk
	);

-- SPI input will be SD card MISO when SPI_CD is low, otherwise the MISO signal from the guest
spi_cs <= spi_cs_int;
spi_mosi <= spi_mosi_int;
spi_fromguest_sd <= spi_miso when spi_cs_int='0' else spi_fromguest;
spi_toguest <= spi_mosi_int;
	
mytimer : entity work.timer_controller
  generic map(
		prescale => sysclk_frequency, -- Prescale incoming clock
		timers => 0
  )
  port map (
		clk => clk,
		reset => reset_n,

		reg_addr_in => cpu_addr(7 downto 0),
		reg_data_in => from_cpu,
		reg_rw => '0', -- we never read from the timers
		reg_req => timer_reg_req,

		ticks(0) => timer_tick -- Tick signal is used to trigger an interrupt
	);


-- Interrupt controller

intcontroller: entity work.interrupt_controller
generic map (
	max_int => int_max
)
port map (
	clk => clk,
	reset_n => reset_n and soft_reset_n,
	trigger => int_triggers,
	ack => int_ack,
	int => int_req,
	status => int_status
);

int_triggers<=(0=>timer_tick, 1=>ps2_int, others => '0');


-- ROM

	rom : entity work.controller_rom
	generic map(
		ADDR_WIDTH => 12
	)
	port map(
		clk => clk,
		addr => cpu_addr(13 downto 2),
		d => from_cpu,
		q => from_rom,
		we => rom_wr,
		bytesel => cpu_bytesel
	);


-- Main CPU

	mem_rom <='1' when cpu_addr(31 downto 26)=X"0"&"00" else '0';
	mem_rd<='1' when cpu_req='1' and cpu_wr='0' and mem_rom='0' else '0';
	mem_wr<='1' when cpu_req='1' and cpu_wr='1' and mem_rom='0' else '0';
		
	process(clk)
	begin
		if rising_edge(clk) then
			rom_ack<=cpu_req and mem_rom;

			if mem_rom='1' and cpu_req='1' then
				to_cpu<=from_rom;
			else
				to_cpu<=from_mem;
			end if;

			if (mem_busy='0' or rom_ack='1') and cpu_ack='0' then
				cpu_ack<='1';
			else
				cpu_ack<='0';
			end if;

			if mem_rom='1' then
				rom_wr<=(cpu_wr and cpu_req);
			else
				rom_wr<='0';
			end if;
	
		end if;	
	end process;
	
	cpu : entity work.eightthirtytwo_cpu
	generic map
	(
		littleendian => true,
		dualthread => false,
		prefetch => true,
		interrupts => true,
		debug => debug
	)
	port map
	(
		clk => clk,
		reset_n => reset_n and soft_reset_n,
		interrupt => int_req and int_enabled,

		-- cpu fetch interface

		addr => cpu_addr(31 downto 2),
		d => to_cpu,
		q => from_cpu,
		bytesel => cpu_bytesel,
		wr => cpu_wr,
		req => cpu_req,
		ack => cpu_ack,
		-- Debug signals
		debug_d=>debug_tocpu,
		debug_q=>debug_fromcpu,
		debug_req=>debug_req,
		debug_wr=>debug_wr,
		debug_ack=>debug_ack		
	);

gendebugbridge:
if debug=true generate
	debugbridge : entity work.debug_bridge_jtag
	port map
	(
		clk => clk,
		reset_n => reset_n,
		d => debug_fromcpu,
		q => debug_tocpu,
		req => debug_req,
		ack => debug_ack,
		wr => debug_wr
	);
end generate;

gennodebug:
if debug=false generate
	debug_req<='0';
end generate;

process(clk)
begin
	if reset_n='0' then
		spi_active<='0';
		int_enabled<='0';
		kbdrecvreg <='0';
		mouserecvreg <='0';
		spi_cs_int <= '1';
		spi_ss2 <= '1';
		spi_ss3 <= '1';
		spi_ss4 <= '1';
		conf_data0 <= '1';
		uploading<='0';
		upload_req<='0';
	elsif rising_edge(clk) then
		mem_busy<='1';
		ser_txgo<='0';
		int_ack<='0';
		timer_reg_req<='0';
		spi_trigger<='0';
		kbdsendtrigger<='0';
		mousesendtrigger<='0';
		flushcaches<='0';
		soft_reset_n<='1';
		
		mem_rd_d<=mem_rd;
		mem_wr_d<=mem_wr;

		-- Write from CPU?
		if mem_wr='1' and mem_wr_d='0' and mem_busy='1' then
			case cpu_addr(31)&cpu_addr(10 downto 8) is

				when X"C" =>	-- Timer controller at 0xFFFFFC00
					timer_reg_req<='1';
					mem_busy<='0';	-- Audio controller never blocks the CPU

				when X"F" =>	-- Peripherals
					case cpu_addr(7 downto 0) is

						when X"B0" => -- Interrupts
							int_enabled<=from_cpu(0);
							mem_busy<='0';
							
						when X"B4" => -- Cache control
							flushcaches<=from_cpu(0);
							mem_busy<='0';

						when X"C0" => -- UART
							ser_txdata<=from_cpu(7 downto 0);
							ser_txgo<='1';
							mem_busy<='0';

						when X"D0" => -- SPI CS
							if from_cpu(1)='1' then
								spi_cs_int <= not from_cpu(0);
							end if;
							if from_cpu(2)='1' then
								spi_ss2 <= not from_cpu(0);
							end if;
							if from_cpu(3)='1' then
								spi_ss3 <= not from_cpu(0);
							end if;
							if from_cpu(4)='1' then
								spi_ss4 <= not from_cpu(0);
							end if;
							if from_cpu(5)='1' then
								conf_data0 <= not from_cpu(0);
							end if;
							spi_fast<=from_cpu(8);
							mem_busy<='0';

						when X"D4" => -- SPI Data
							spi_trigger<='1';
							host_to_spi<=from_cpu(7 downto 0);
							spi_active<='1';
						
						when X"D8" => -- SPI Pump
							spi_trigger<='1';
							host_to_spi<=from_cpu(7 downto 0);
							spi_active<='1';

						-- Write to PS/2 registers
						when X"e0" =>
							kbdsendbyte<=from_cpu(7 downto 0);
							kbdsendtrigger<='1';
							mem_busy<='0';

						when X"e4" =>
							mousesendbyte<=from_cpu(7 downto 0);
							mousesendtrigger<='1';
							mem_busy<='0';

						when X"f8" =>
							uploading <= from_cpu(0);
							upload_addr<=(others=>'0');
							mem_busy<='0';
							
						when X"fc" =>
							upload_data<=from_cpu(7 downto 0);
							upload_req<='1';
							
						when others =>
							mem_busy<='0';
							null;
					end case;
				when others =>
					mem_busy<='0';
			end case;

		elsif mem_rd='1' and mem_rd_d='0' and mem_busy='1' then -- Read from CPU?
			case cpu_addr(31 downto 28) is

				when X"F" =>	-- Peripherals
					case cpu_addr(7 downto 0) is
					
						when X"B0" => -- Interrupt
							from_mem<=(others=>'X');
							from_mem(int_max downto 0)<=int_status;
							int_ack<='1';
							mem_busy<='0';

						when X"C0" => -- UART
							from_mem<=(others=>'X');
							from_mem(9 downto 0)<=ser_rxrecv&ser_txready&ser_rxdata;
							ser_rxrecv<='0';	-- Clear rx flag.
							mem_busy<='0';
							
						when X"C8" => -- Millisecond counter
							from_mem<=std_logic_vector(millisecond_counter);
							mem_busy<='0';

						when X"D0" => -- SPI Status
							from_mem<=(others=>'X');
							from_mem(15)<=spi_busy;
							mem_busy<='0';

						when X"D4" => -- SPI read (blocking)
							spi_active<='1';

						when X"D8" => -- SPI pump (blocking)
							spi_trigger<='1';
							host_to_spi<=X"FF";
							spi_active<='1';

						-- Read from PS/2 regs
						when X"E0" =>
							from_mem<=(others =>'0');
							from_mem(11 downto 0)<=kbdrecvreg & not kbdsendbusy & kbdrecvbyte(10 downto 1);
							kbdrecvreg<='0';
							mem_busy<='0';
							
						when X"E4" =>
							from_mem<=(others =>'0');
							from_mem(11 downto 0)<=mouserecvreg & not mousesendbusy & mouserecvbyte(10 downto 1);
							mouserecvreg<='0';
							mem_busy<='0';

						when X"E8" => -- joysticks;
							from_mem <= joy4_r & joy3_r & joy2_r & joy1_r;
							mem_busy<='0';

						when X"EC" => -- Misc inputs;
							from_mem<=(others => '0');
							from_mem(0)<=not menu_button;
							mem_busy<='0';

						when others =>
							mem_busy<='0';
					end case;

				when others =>
					mem_busy<='0';
			end case;
		end if;

	
		-- SPI cycles

		if spi_active='1' and spi_busy='0' then
			from_mem<=X"000000"&spi_to_host;
			spi_active<='0';
			mem_busy<='0';
		end if;


		-- Set this after the read operation has potentially cleared it.
		if ser_rxint='1' then
			ser_rxrecv<='1';
			if ser_rxdata=X"04" then
				soft_reset_n<='0';
				ser_rxrecv<='0';
				int_enabled<='0';
			end if;
		end if;

		-- PS2 interrupt
		ps2_int <= kbdrecv or kbdsenddone
			or mouserecv or mousesenddone;
			-- mouserecv or kbdsenddone or mousesenddone ; -- Momentary high pulses to indicate retrieved data.
		if kbdrecv='1' then
			kbdrecvreg <= '1'; -- remains high until cleared by a read
		end if;
		if mouserecv='1' then
			mouserecvreg <= '1'; -- remains high until cleared by a read
		end if;	

	end if; -- rising-edge(clk)

end process;

end architecture;

