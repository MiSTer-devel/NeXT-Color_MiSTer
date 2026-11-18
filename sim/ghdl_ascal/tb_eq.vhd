-- Equivalence check: upstream ascal OSWEEP counters / poly_final vs the
-- NeXT-Color patched versions.  Random o_ce, random htotal/vtotal/vsstart
-- changes, random o_vrr_sync2.  Poly: random DSP products.
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE ieee.math_real.ALL;

ENTITY tb_eq IS END;

ARCHITECTURE sim OF tb_eq IS
  SUBTYPE uint12 IS natural RANGE 0 TO 4095;
  SIGNAL clk : std_logic := '0';
  SIGNAL o_ce : std_logic := '0';
  SIGNAL o_htotal, o_vtotal, o_vsstart : uint12 := 10;
  SIGNAL o_vrr_sync2 : boolean := false;
  -- old
  SIGNAL a_hcpt, a_pre3, a_pre2, a_pre, a_vcpt, a_sync : uint12 := 0;
  -- new
  SIGNAL b_hcpt, b_pre3, b_pre2, b_pre, b_vcpt, b_sync : uint12 := 0;
  SIGNAL o_heol, o_veol : boolean := false;
  SIGNAL done : boolean := false;
  SIGNAL resync : boolean := false;

  TYPE type_pix IS RECORD r,g,b : unsigned(7 DOWNTO 0); END RECORD;
  FUNCTION bound(a : unsigned; s : natural) RETURN unsigned IS
  BEGIN
    IF a(a'left)='1' THEN RETURN x"00";
    ELSIF a(a'left DOWNTO s)/=0 THEN RETURN x"FF";
    ELSE RETURN a(s-1 DOWNTO s-8); END IF;
  END FUNCTION;
BEGIN
  clk <= NOT clk AFTER 5 ns WHEN NOT done;

  POLD: PROCESS(clk) BEGIN
    IF rising_edge(clk) THEN
      IF o_ce='1' THEN
        IF a_hcpt+1<o_htotal THEN
          a_hcpt<=(a_hcpt+1) MOD 4096;
        ELSE
          a_hcpt<=0;
          IF a_sync /= 4095 THEN a_sync<=a_sync+1; END IF;
          IF a_pre3+1>=o_vtotal THEN a_pre3<=0;
          ELSIF o_vrr_sync2 THEN a_pre3<=o_vsstart;
          ELSE a_pre3<=(a_pre3+1) MOD 4096; END IF;
          a_pre2<=a_pre3; a_pre<=a_pre2; a_vcpt<=a_pre;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  PNEW: PROCESS(clk) BEGIN
    IF rising_edge(clk) AND resync THEN
      b_hcpt<=a_hcpt; b_pre3<=a_pre3; b_pre2<=a_pre2; b_pre<=a_pre; b_vcpt<=a_vcpt; b_sync<=a_sync;
      o_heol<=false; o_veol<=false;
    ELSIF rising_edge(clk) THEN
      o_veol<=(b_pre3+1>=o_vtotal);
      IF o_ce='1' THEN
        IF o_heol THEN o_heol<=(1>=o_htotal);
        ELSE o_heol<=(b_hcpt+2>=o_htotal); END IF;
      ELSE
        o_heol<=(b_hcpt+1>=o_htotal);
      END IF;
      IF o_ce='1' THEN
        IF NOT o_heol THEN
          b_hcpt<=(b_hcpt+1) MOD 4096;
        ELSE
          b_hcpt<=0;
          IF b_sync /= 4095 THEN b_sync<=b_sync+1; END IF;
          IF o_veol THEN b_pre3<=0;
          ELSIF o_vrr_sync2 THEN b_pre3<=o_vsstart;
          ELSE b_pre3<=(b_pre3+1) MOD 4096; END IF;
          b_pre2<=b_pre3; b_pre<=b_pre2; b_vcpt<=b_pre;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  STIM: PROCESS
    VARIABLE s1, s2 : positive := 7;
    VARIABLE r : real;
    VARIABLE mism, eol : natural := 0;
    VARIABLE t0r,t1r : signed(26 DOWNTO 0);
    VARIABLE sum : signed(18 DOWNTO 0);
    VARIABLE pa, pb : unsigned(7 DOWNTO 0);
    VARIABLE pmis : natural := 0;
    VARIABLE ri : integer;
    VARIABLE quiet : natural := 4;
  BEGIN
    -- poly_final(t) vs poly_bound(poly_sum(t)), one channel (same code x3)
    FOR i IN 0 TO 200000 LOOP
      uniform(s1,s2,r); ri := integer(trunc((r-0.5)*2.0**26));
      t0r := to_signed(ri,27);
      uniform(s1,s2,r); ri := integer(trunc((r-0.5)*2.0**26));
      t1r := to_signed(ri,27);
      IF i < 2000 THEN  -- also small values near the clamp edges
        uniform(s1,s2,r); t0r := to_signed(integer(trunc((r-0.5)*2.0**24)),27);
        uniform(s1,s2,r); t1r := to_signed(integer(trunc((r-0.5)*2.0**24)),27);
      END IF;
      pa := bound(unsigned(t0r(26 DOWNTO 8)+t1r(26 DOWNTO 8)),15);
      sum := t0r(26 DOWNTO 8)+t1r(26 DOWNTO 8);
      pb := bound(unsigned(sum),15);
      IF pa /= pb THEN pmis := pmis+1; END IF;
    END LOOP;
    REPORT "poly mismatches: " & integer'image(pmis);

    -- counters
    FOR cyc IN 0 TO 3000000 LOOP
      WAIT UNTIL falling_edge(clk);
      resync <= false;
      IF quiet > 0 THEN quiet := quiet-1;
      ELSIF a_hcpt/=b_hcpt OR a_pre3/=b_pre3 OR a_pre2/=b_pre2 OR a_pre/=b_pre
         OR a_vcpt/=b_vcpt OR a_sync/=b_sync THEN
        mism := mism+1;
        IF mism < 10 THEN
          REPORT "mismatch cyc " & integer'image(cyc) & " hcpt " &
            integer'image(a_hcpt) & "/" & integer'image(b_hcpt) & " pre3 " &
            integer'image(a_pre3) & "/" & integer'image(b_pre3) & " htot " &
            integer'image(o_htotal);
        END IF;
      END IF;
      IF a_hcpt = 0 THEN eol := eol+1; END IF;
      uniform(s1,s2,r); IF r < 0.7 THEN o_ce<='1'; ELSE o_ce<='0'; END IF;
      uniform(s1,s2,r); o_vrr_sync2 <= r < 0.05;
      -- mode changes: rare, applied while running (like a resolution switch)
      uniform(s1,s2,r);
      IF r < 0.0005 THEN
        uniform(s1,s2,r); o_htotal <= 2 + integer(trunc(r*60.0));
        uniform(s1,s2,r); o_vtotal <= 1 + integer(trunc(r*20.0));
        uniform(s1,s2,r); o_vsstart <= integer(trunc(r*20.0));
        quiet := 4;
      END IF;
      IF quiet = 3 THEN o_ce <= '0'; END IF;
      IF quiet = 2 THEN resync <= true; o_ce <= '0'; END IF;
      IF quiet = 1 THEN o_ce <= '0'; END IF;
    END LOOP;
    REPORT "counter mismatch cycles: " & integer'image(mism) &
           "  hcpt=0 cycles " & integer'image(eol);
    done <= true;
    WAIT;
  END PROCESS;
END;
