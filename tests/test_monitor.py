from harness import CoCoSim

CR, ESC, BS = 0x0D, 0x1B, 0x08

# (col, row) for the keys the tests type
KEY = {
    "0": (0, 4), "1": (1, 4), "2": (2, 4), "3": (3, 4), "4": (4, 4),
    "5": (5, 4), "6": (6, 4), "7": (7, 4), "8": (0, 5), "9": (1, 5),
    "A": (1, 0), "B": (2, 0), "C": (3, 0), "D": (4, 0), "E": (5, 0),
    "F": (6, 0), "R": (2, 2), ".": (6, 5), ":": (2, 5), " ": (7, 3),
    "\r": (0, 6), "\x1b": (2, 6), "\x08": (5, 3),
}


def type_line(sim, text):
    sim.queue_keys([KEY[c] for c in text])


def test_getline_collects_characters_into_buffer():
    sim = CoCoSim()
    type_line(sim, "1234\r")
    sim.run_sub("GETLINE")
    base = sim.sym["IN"]
    assert [chr(sim.peek(base + i)) for i in range(4)] == list("1234")
    assert sim.peek(base + 4) == CR


def test_getline_echoes_to_screen():
    """GETLINE emits a CR first, as the original does, so echo lands on row 1."""
    sim = CoCoSim()
    type_line(sim, "AB\r")
    sim.run_sub("GETLINE")
    assert sim.screen_text()[1][:2] == "AB"


def test_backspace_removes_last_character():
    sim = CoCoSim()
    type_line(sim, "12\x083\r")
    sim.run_sub("GETLINE")
    base = sim.sym["IN"]
    assert [chr(sim.peek(base + i)) for i in range(2)] == list("13")
    assert sim.peek(base + 2) == CR


def test_backspace_past_start_restarts_line():
    sim = CoCoSim()
    type_line(sim, "\x08A\r")
    sim.run_sub("GETLINE")
    base = sim.sym["IN"]
    assert chr(sim.peek(base)) == "A"


def test_escape_prints_backslash_and_restarts():
    sim = CoCoSim()
    type_line(sim, "12\x1bA\r")
    sim.run_sub("GETLINE")
    assert "\\" in "".join(sim.screen_text())
    base = sim.sym["IN"]
    assert chr(sim.peek(base)) == "A"


# --- Task 7: command dispatch and MODE ---------------------------------

def _dispatch(text, mode_in=0x00):
    """Load text into IN and run one NEXTITEM pass."""
    sim = CoCoSim()
    base = sim.sym["IN"]
    for i, ch in enumerate(text + "\r"):
        sim.poke(base + i, ord(ch))
    sim.poke(sim.sym["MODE"], mode_in)
    sim.run_sub("NEXTITEM", b=0, u=base)
    return sim


def test_period_sets_block_mode():
    """'.' sets MODE to $AE while the line is still being walked."""
    sim = _dispatch("1000.")
    assert sim.peek(sim.sym["MODE"]) == 0xAE


def test_completed_block_examine_returns_to_xam_mode():
    """XAMNEXT clears MODE once the range is exhausted, as the original's
    STX MODE (with X=0) does -- so MODE is $00 again after a full dump."""
    sim = _dispatch("1000.1010")
    assert sim.peek(sim.sym["MODE"]) == 0x00


def test_colon_sets_store_mode():
    sim = _dispatch("1000: AA")
    assert sim.peek(sim.sym["MODE"]) == 0x74


def test_bare_address_leaves_xam_mode():
    sim = _dispatch("1000")
    assert sim.peek(sim.sym["MODE"]) == 0x00


def test_mode_values_match_original_exactly():
    """$74 is ASL of ':' ($BA); $AE is '.'. The OCR listing had these wrong."""
    store = _dispatch("00:")
    assert store.peek(store.sym["MODE"]) == 0x74
    blok = _dispatch("00.")
    assert blok.peek(blok.sym["MODE"]) == 0xAE


def test_spaces_are_skipped_as_delimiters():
    sim = _dispatch("10 20 30")
    assert sim.peek(sim.sym["MODE"]) == 0x00


def test_malformed_input_prints_backslash():
    """No hex digits where hex is expected is the monitor's only error path.

    It prints '\\' and returns, so MAINLOOP reads a fresh line -- matching
    the original, whose ESCAPE prints '\\' then falls into GETLINE.
    """
    sim = _dispatch("G")
    assert "\\" in "".join(sim.screen_text())


def test_hex_letters_all_parse():
    """Regression guard for the 6809 carry inversion.

    With the original's ADC #$88 constant instead of ADDA #$89, every one
    of these is rejected as non-hex and HEX is never populated.
    """
    for letter in "ABCDEF":
        sim = _dispatch(letter * 4)
        expected = int(letter * 4, 16)
        assert sim.peek_word(sim.sym["HEX"]) == expected, f"{letter} failed"


# --- Task 8: examine and block examine ---------------------------------

def _examine(text, pattern=None):
    sim = CoCoSim()
    if pattern:
        for addr, val in pattern.items():
            sim.poke(addr, val)
    base = sim.sym["IN"]
    for i, ch in enumerate(text + "\r"):
        sim.poke(base + i, ord(ch))
    sim.poke(sim.sym["MODE"], 0x00)
    sim.run_sub("NEXTITEM", b=0, u=base)
    return sim


def test_single_examine_prints_address_and_byte():
    sim = _examine("0500", {0x0500: 0xA9})
    assert "0500: A9" in "".join(sim.screen_text())


def test_block_examine_prints_eight_bytes_per_line():
    pattern = {0x0500 + i: i for i in range(16)}
    sim = _examine("0500.050F", pattern)
    text = "".join(sim.screen_text())
    assert "0500: 00 01 02 03 04 05 06 07" in text
    assert "0508: 08 09 0A 0B 0C 0D 0E 0F" in text


def test_dump_line_fits_32_columns():
    pattern = {0x0500 + i: 0xFF for i in range(8)}
    sim = _examine("0500.0507", pattern)
    for row in sim.screen_text():
        assert len(row.rstrip()) <= 32


def test_block_examine_across_page_boundary():
    """Exercises the INC XAM carry path the OCR listing got wrong."""
    pattern = {0x04FE: 0xAA, 0x04FF: 0xBB, 0x0500: 0xCC, 0x0501: 0xDD}
    sim = _examine("04FE.0501", pattern)
    text = "".join(sim.screen_text())
    assert "AA BB" in text
    assert "CC DD" in text


def test_examine_sets_xam_to_parsed_address():
    sim = _examine("1234")
    assert sim.peek_word(sim.sym["XAM"]) >= 0x1234


# --- Task 9: store mode ------------------------------------------------

def test_store_writes_byte_at_address():
    sim = _examine("0500: AA")
    assert sim.peek(0x0500) == 0xAA


def test_store_multiple_bytes_advances():
    sim = _examine("0500: 11 22 33")
    assert [sim.peek(0x0500 + i) for i in range(3)] == [0x11, 0x22, 0x33]


def test_store_across_page_boundary():
    sim = _examine("04FE: 11 22 33 44")
    assert [sim.peek(0x04FE + i) for i in range(4)] == [0x11, 0x22, 0x33, 0x44]


def test_store_uses_low_byte_only():
    sim = _examine("0500: 1234")
    assert sim.peek(0x0500) == 0x34


def test_bare_colon_continues_from_last_store_index():
    """ST persists across lines, so ':' with no address resumes storing."""
    sim = CoCoSim()
    base = sim.sym["IN"]

    def feed(text):
        for i, ch in enumerate(text + "\r"):
            sim.poke(base + i, ord(ch))
        sim.poke(sim.sym["MODE"], 0x00)
        sim.run_sub("NEXTITEM", b=0, u=base)

    feed("0500: 11 22")
    feed(": 33 44")
    assert [sim.peek(0x0500 + i) for i in range(4)] == [0x11, 0x22, 0x33, 0x44]
