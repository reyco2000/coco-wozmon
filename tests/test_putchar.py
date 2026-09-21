from harness import CoCoSim, SCREEN, SCREND

CR = 0x0D


def test_writes_one_char_and_advances_cursor():
    sim = CoCoSim()
    sim.run_sub("PUTCHAR", a=ord("A"))
    assert sim.screen_text()[0][0] == "A"
    assert sim.peek_word(sim.sym["CURSOR"]) == SCREEN + 1


def test_preserves_registers():
    sim = CoCoSim()
    sim.run_sub("PUTCHAR", a=ord("Z"), b=0x5A, x=0x1234)
    assert sim.cpu.accu_a.value == ord("Z")
    assert sim.cpu.accu_b.value == 0x5A
    assert sim.cpu.index_x.value == 0x1234


def test_cr_moves_to_start_of_next_line():
    sim = CoCoSim()
    for ch in "ABC":
        sim.run_sub("PUTCHAR", a=ord(ch))
    sim.run_sub("PUTCHAR", a=CR)
    assert sim.peek_word(sim.sym["CURSOR"]) == SCREEN + 32
    sim.run_sub("PUTCHAR", a=ord("X"))
    assert sim.screen_text()[0][:3] == "ABC"
    assert sim.screen_text()[1][0] == "X"


def test_cr_at_column_31_advances_exactly_one_line():
    """Boundary: the round-up must not skip a line when already at col 31."""
    sim = CoCoSim()
    sim.poke_word(sim.sym["CURSOR"], SCREEN + 31)
    sim.run_sub("PUTCHAR", a=CR)
    assert sim.peek_word(sim.sym["CURSOR"]) == SCREEN + 32


def test_scrolls_when_cursor_passes_end_of_screen():
    sim = CoCoSim()
    sim.poke_word(sim.sym["CURSOR"], SCREEN + 15 * 32)   # last row
    for ch in "HELLO":
        sim.run_sub("PUTCHAR", a=ord(ch))
    sim.run_sub("PUTCHAR", a=CR)                         # forces scroll
    assert sim.screen_text()[14][:5] == "HELLO"
    assert sim.screen_text()[15] == " " * 32
    assert sim.peek_word(sim.sym["CURSOR"]) == SCREND - 32


def test_scroll_preserves_earlier_rows_shifted_up():
    sim = CoCoSim()
    for r in range(16):
        sim.poke(SCREEN + r * 32, ord("0") + (r % 10))
    sim.poke_word(sim.sym["CURSOR"], SCREND - 1)
    sim.run_sub("PUTCHAR", a=ord("!"))    # fills last cell, triggers scroll
    text = sim.screen_text()
    assert text[0][0] == "1"              # old row 1 is now row 0
    assert text[14][0] == "5"             # old row 15 is now row 14
