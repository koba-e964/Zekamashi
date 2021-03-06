-------------------------------------------------------------------------------
-- Declaration
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.zkms_instcache_p.all;
use work.zkms_alu_p.all;

package zkms_core_p is

  type zkms_core_in_t is record
    instcache : zkms_instcache_out_t;
    alu       : zkms_alu_out_t;
    mmu       : zkms_mmu_out_t;
  end record zkms_core_in_t;

  type zkms_core_out_t is record
    instcache : zkms_instcache_in_t;
    alu       : zkms_alu_in_t;
    mmu       : zkms_mmu_in_t;
  end record zkms_core_out_t;

  component zkms_core is
    port (
      clk  : in  std_logic;
      din  : in  zkms_core_in_t;
      dout : out zkms_core_out_t);
  end component zekamashi_core;

end package zkms_core_p;

-------------------------------------------------------------------------------
-- Definition
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.zkms_core_p.all;
use work.zkms_instcache_p.all;
use work.zkms_alu_p.all;

entity zkms_core is
  port (
    clk  : in  std_logic;
    din  : in  zkms_core_in_t;
    dout : out zkms_core_out_t);
end entity zkms_core;

architecture behavior of zkms_core is

  subtype word_t is unsigned(31 downto 0);
  subtype reg_index_t is integer range 0 to 31;
  type reg_file_t is array (0 to 30) of unsigned(31 downto 0);

  constant unop : word_t := "010001111111111100000100000011111"

  type opmode_t is (
    OP_NOP,
    OP_LOAD,
    OP_STORE,
    OP_ALU,
    OP_FPU,
    OP_BRA,
    OP_JMP);

  type latch_ifid_t is record
    pc   : word_t;
    inst : word_t
  end record latch_ifid_t;

  type latch_idexe_t is record
    opmode   : opmode_t;
    pc       : word_t;
    inst     : word_t;
    rav      : word_t;
    rbv      : word_t;
    ra       : reg_index_t;
    rb       : reg_index_t;
    wb       : reg_index_t;
    alu_inst : alu_inst_t;
  end record latch_idexe_t;

  type latch_exemem_t is record
    opmode  : opmode_t;
    pc      : word_t;
    wb      : reg_index_t;
    alu_out : word_t;
    data    : word_t;
  end record latch_exemem_t;

  type latch_memwb_t is record
    opmode  : opmode_t;
    wb      : reg_index_t;
    alu_out : word_t;
  end record latch_memwb_t;

  type latch_t is record
    pc : word_t;      -- program counter
    ir : reg_file_t;  -- integer register
    fr : reg_file_t;  -- floating-point register
    -- latches
    d  : latch_ifid_t;
    e  : latch_idexe_t;
    m  : latch_exemem_t;
    w  : latch_memwb_t;
  end record latch_t;

  constant latch_init_value : latch_t := (  -- fixme
    pc => 0,
    ir => (others => 0),
    fr => (others => 0));

  signal r, rin : latch_t := latch_init_value;

begin

  comb : process (din, r) is
    variable v : latch_t;

    procedure flush_pipeline (
      v : out latch_t) is
    begin
      v.d.inst := unop;  -- BIS R31,R31,R31
    end procedure flush_pipeline;

    function fetch_reg (
      r : reg_file_t;
      n : reg_index_t)
      return word_t is
    begin
      if n = 31 then
        return to_unsigned(0, 32);
      else
        return r.rf(n);
      end if;
    end function fetch_reg;

    procedure store_reg (
      r : out reg_file_t;
      n : in reg_index_t;
      v : in word_t) is
    begin
      if n /= 31 then
        r(n) := v;
      end if;
    end procedure store_reg;

    -- variables for instruction decode
    variable opcode : unsigned(5 downto 0);
    variable rc     : reg_index_t;
    variable opfunc : unsigned(6 downot 0);
    variable fpfunc : unsigned(10 downto 0);
    variable bdisp  : unsigned(20 downto 0);
    variable cond   : word_t;

    function decode_alu_inst (
      opcode : unsigned(5 downto 0);
      opfunc : unsigned(6 downto 0))
      return alu_inst_t is
    begin
      case opcode is
        when x"10" =>
          case opfunc is
            when x"00" => return ALU_INST_ADD;
            when x"09" => return ALU_INST_SUB;
            when x"2d" => return ALU_INST_EQ;
            when x"6d" => return ALU_INST_LE;
            when x"4d" => return ALU_INST_LT;
          end case;

        when x"11" =>
          case opfunc is
            when x"00" => return ALU_INST_AND;
            when x"20" => return ALU_INST_OR;
            when x"40" => return ALU_INST_XOR;
            when x"48" => return ALU_INST_EQV;
          end case;

        when x"12" =>
          case opfunc is
            when x"39" => return ALU_INST_SLL;
            when x"34" => return ALU_INST_SRL;
            when x"3c" => return ALU_INST_SRA;
          end case;
      end case;

      assert false report "invalid alu instruction" severity failure;
      return ALU_INST_NOP;
    end function decode_alu_inst;

    function branch_success (
      cond   : word_t;
      opcode : unsgined(5 downto 0))
      return boolean is
    begin
      case opcode is
        when x"39"         => return cond = 0;   -- BEQ
        when x"3d"         => return cond /= 0;  -- BNE
        when others =>
          assert false report "invalid branch instruction" severity error;
          return false;
      end case;
    end function branch_success;

    ---------------------------------------------------------------------------
    -- Hazard Detection
    ---------------------------------------------------------------------------

    type hazard_t is (
      HZ_FINE, -- there is no hazard
      HZ_BRA,
      HZ_EXE, -- there is raw hazard, where op cannot see the result of load
      HZ_WB); -- there is cache miss

    function brc_inst (
      inst : word_t)
      return boolean is
    begin
      return r.d.inst(31 downto 29) = "111";
    end function bra_inst;

    function jmp_inst (
      inst : word_t)
      return boolean is
      variable opcode : unsigned(5 downto 0);
    begin
      opcode := r.d.inst(31 downto 26);
      return opcode = "011010";    -- 1a jmp
    end function jmp_inst;

    function detect_hz_id (
      r : latch_t)
      return boolean is
      variable ri : reg_index_t;
    begin
      if brc_inst(r.d.inst) then
        ri := to_integer(r.d.inst(25 downto 21));
        return ri /= 31 and ((r.e.opmode = OP_LOAD and ri = r.e.wb) or
                             (r.m.opmode = OP_LOAD and ri = r.m.wb));
      elsif jmp_inst(r.d.inst) then
        ri := to_integer(r.d.inst(20 downto 16));
        return ri /= 31 and ((r.e.opmode = OP_LOAD and ri = r.e.wb) or
                             (r.m.opmode = OP_LOAD and ri = r.m.wb));
      else
        return false;
      end if;
    end function detect_hz_exe;

    function detect_hz_exe (
      r : latch_t)
      return boolean is
    begin
      return r.m.opmode = OP_LOAD and
        ((r.e.opmode = OP_ALU or r.e.opmode = OP_STORE) and r.e.ra /= 31 and r.e.ra = r.m.wb) or
        ((r.e.opmode = OP_LDA or r.e.opmode = OP_LDAH or r.e.opmode = OP_LOAD or
          r.e.opmode = OP_STORE or (r.e.opmode = OP_ALU and r.e.inst(12) = '0')) and
         r.e.rb /= 31 and r.e.rb = r.m.wb)
    end function detect_hz_exe;

    function detect_hazard (
      r : latch_t)
      return hazard_t is
    begin

      if din.mmu.miss = '1' then
        assert r.w.opmode = OP_LOAD report "something is wrong with memory operation" severity error;
        return HZ_CACHEMISS;
      elsif detect_hz_exe(r) then
        return HZ_EXE;
      elsif detect_hz_id(r) then
        return HZ_ID;
      else
        return HZ_FINE;
      end if;

    end function detect_hazard;

    ---------------------------------------------------------------------------
    -- Data Forwarding
    ---------------------------------------------------------------------------

    function forward_data_ir_id (
      r : latch_t;
      v : word_t;
      n : reg_idx_t)
      return word_t is
    begin
      if n = 31 then
        return to_unsigned(0, 32);
      elsif n = r.e.wb then
        case r.m.opmode is
          when OP_ALU | OP_LDA | OP_LDAH | OP_JMP =>
            return din.alu.o;
          when others =>
            return (others => '-');
        end case;
      elsif n = r.m.wb then
        case r.m.opmode is
          when OP_ALU | OP_LDA | OP_LDAH | OP_JMP =>
            return r.m.alu_out;
          when others =>
            return (others => '-');
        end case;
      elsif n = r.w.wb then
        case r.m.opmode is
          when OP_ALU | OP_LDA | OP_LDAH | OP_JMP =>
            return r.m.alu_out;
          when OP_LOAD =>
            return din.mmu.data;
          when others =>
            return (others => '-');
        end case;
      else
        return v;
      end if;
    end function forward_data_ir_id;

    function forward_data_ir_exe (
      r : latch_t;
      v : word_t;
      n : reg_idx_t)
      return word_t is
    begin
      if n = 31 then
        return to_unsigned(0, 32);
      elsif n = r.m.wb then
        case r.m.opmode is
          when OP_ALU | OP_LDA | OP_LDAH | OP_JMP =>
            return r.m.alu_out;
          when others =>
            return (others => '-');
        end case;
      elsif n = r.w.wb then
        case r.m.opmode is
          when OP_ALU | OP_LDA | OP_LDAH | OP_JMP =>
            return r.m.alu_out;
          when OP_LOAD =>
            return din.mmu.data;
          when others =>
            return (others => '-');
        end case;
      else
        return v;
      end if;
    end function forward_data_ir_exe;

    variable hazard : hazard_t;

  begin
    v := r;

    hazard = detect_hazard(r);

    -------------------------------------------------------------------------
    -- Instruction Fetch
    -------------------------------------------------------------------------

    v.d.inst := din.instcache.data;
    v.d.pc   := r.pc;
    v.pc     := r.pc + 1;

    case hazard is
      when HZ_ID | HZ_EXE | HZ_CACHEMISS =>
        v.d  := r.d;
        v.pc := r.pc;
      when others => null;
    end case;

    -------------------------------------------------------------------------
    -- Instruction Decode
    -------------------------------------------------------------------------

    v.e.pc   := r.d.pc;
    v.e.ra   := to_integer(r.d.inst(25 downto 21));
    v.e.rb   := to_integer(r.d.inst(20 downto 16));
    v.e.rav  := fetch_reg(v.ir, v.e.ra);
    v.e.rbv  := fetch_reg(v.ir, v.e.rb);
    v.e.inst := r.d.inst;

    rc     := to_integer(r.d.inst(4 downto 0));
    opcode := r.d.inst(31 downto 26);

    case opcode(5 downto 3) is
      when 2 =>                         -- operation format
        case opcode is
          when x"10", x"11", x"12" =>   -- integer arithmetic
            v.e.opmode := OP_ALU;
            v.e.wb     := rc;

            opfunc       := r.d.inst(11 downto 5);
            v.e.alu_inst := decode_alu_inst(opcode, opfunc);

          when x"16" =>               -- floating-point arithmetic
            v.e.opmode := OP_FPU;
            -- fixme!

          when others =>
            assert false report "invalid instruction" severity failure;
        end case;

      when 1, 3, 5 =>                   -- memory format
        v.e.wb := v.e.ra;
        v.e.alu_inst := ALU_INST_ADD;

        case opcode is
          when x"08" => v.e.opmode := OP_LDA;
          when x"09" => v.e.opmode := OP_LDAH;
          when x"28" => v.e.opmode := OP_LOAD;
          when x"2c" => v.e.opmode := OP_STORE;
          when x"1a" => v.e.opmode := OP_JMP;
                        v.pc := forward_data_ir_id(r, v.e.rbi, v.e.rb);
                        flush_pipeline(v);
          when others => assert false report "invalid instruction" severity failure;
        end case;

      when 6, 7 =>                      -- branch format
        -- integer conditional branch
        if opcode(5 downto 3) = 7 then
          v.e.wb       := 31;
          v.e.alu_inst := ALU_INST_NOP;
          v.e.opmode   := OP_BRA;
          bdisp        := r.d.inst(20 downto 0);
          cond         := forward_data_ir_id(r, v.e.rai, v.e.ra);
          if branch_success_p(cond, opcode) then
            v.pc := unsigned(signed(v.d.pc) + signed(bdisp));
          end if;
        -- unconditional branch
        elsif opcode = "110000" or opcode = "110100" then
          v.e.wb       := v.e.ra;
          v.e.alu_inst := ALU_INST_ADD;
          v.e.opmode   := OP_JMP;
          bdisp        := r.d.inst(20 downto 0);
          v.pc         := unsigned(signed(v.d.pc) + signed(bdisp));
        else
          assert false report "invalid branch instruction" severity error;
        end if;

      when others =>
        assert false report "invalid instruction" severity failure;
    end case;

    case hazard is
      when HZ_ID =>
        v.e := (opmode => OP_ALU,
                pc => r.d.pc,
                inst => unop,
                rav => (others => '0'),
                rbv => (others => '0'),
                ra => 31,
                rb => 31,
                wb => 31,
                alu_inst => ALU_ISNT_BIS);
        v.pc := r.pc;
      when HZ_EXE | HZ_CACHEMISS =>
        v.e  := r.e;
        v.pc := r.pc;
      when others => null;
    end case;

    -------------------------------------------------------------------------
    -- Execute
    -------------------------------------------------------------------------

    dout.alu.inst <= r.e.alu_inst;
    mdisp := r.e.inst(15 downto 0);

    case r.e.opmode is
      when OP_ALU =>
        dout.alu.i1 <= forward_data_ir_exe(r, r.e.rav, r.e.ra);
        if r.e.inst(12) = '1' then      -- litp
          dout.alu.i2 <= resize(r.e.inst(20 downto 13), 32);
        else
          dout.alu.i2 <= forward_data_ir_exe(r, r.e.rbv, r.e.rb);
        end if;
      when OP_LDA =>
        dout.alu.i1 <= x"0000" & mdisp;
        dout.alu.i2 <= forward_data_ir_exe(r, r.e.rbv, r.e.rb);
      when OP_LDAH =>
        dout.alu.i1 <= mdisp & x"0000";
        dout.alu.i2 <= forward_data_ir_exe(r, r.e.rbv, r.e.rb);
      When OP_LOAD | OP_STORE =>
        dout.alu.i1 <= unsigned(resize(signed(mdisp), 32));
        dout.alu.i2 <= forward_data_ir_exe(r, r.e.rbv, r.e.rb);
      when OP_JMP =>
        dout.alu.i1 <= r.e.pc;
        dout.alu.i2 <= to_unsigned(1, 32);
      when OP_BRA =>
        dout.alu.i1 <= to_unsigned(0, 32);
        dout.alu.i2 <= to_unsigned(0, 32);
      when OP_FPU =>;
                     -- fixme

      when others => null;
    end case;
    
    v.m.alu_out := din.alu.o;
    v.m.wb      := r.e.wb;
    v.m.opmode  := r.e.opmode;
    v.m.data    := forward_data_ir_exe(r, r.e.rav, r.e.ra);  -- necessary for
                                                             -- only store
    case hazard is
      when HZ_EXE =>
        v.m := (opmode  => OP_ALU,
                pc      => r.e.pc,
                wb      => 31,
                alu_out => (others => '-'),
                data    => (others => '-'));
      when HZ_CACHEMISS =>
        v.m := r.m;
      when others => null;
    end case;

    -------------------------------------------------------------------------
    -- Memory
    -------------------------------------------------------------------------

    case r.m.opmode is
      when OP_LOAD =>
        dout.mmu <= (addr => r.m.alu_out(21 downto 0),
                     data => (others => '0'),
                     en   => '1',
                     we   => '0');
      when OP_STORE =>
        dout.mmu <= (addr => r.m.alu_out(21 downto 0),
                     data => r.m.data,
                     en   => '1',
                     we   => '1');
      when others =>
        dout.mmu <= (addr => (others => '-')
                     data => (others => '-'),
                     en   => '0',
                     we   => '0');
    end case;

    v.w.wb      := r.m.wb;
    v.w.alu_out := r.m.alu_out;
    v.w.opmode  := r.m.opmode;

    case hazard is
      when HZ_CACHEMISS =>
        v.w := r.w;
      when others => null;
    end case;

    -------------------------------------------------------------------------
    -- Write Back
    -------------------------------------------------------------------------

    case r.w.opmode is
      when OP_ALU | OP_LDA | OP_LDAH | OP_JMP =>
        store_reg(v.ir, v.w.wb, v.w.alu_out);
      when OP_FPU => ;                  -- fixme
      when OP_LOAD =>
        if din.mmu.miss = '0' then store_reg(v.ir, v.w.wb, din.mmu.data); end if;
      when others => null;
    end case;    

    -------------------------------------------------------------------------
    -- Instruction Fetch
    -------------------------------------------------------------------------

    dout.instcache.addr <= v.pc;

    rin <= v;
  end process;

  seq : process (clk, rst) is
  begin
    if rst = '1' then
      r <= latch_init_value;
    elsif rising_edge(clk) then
      r <= rin;
    end if;
  end process;

end architecture behavior;
