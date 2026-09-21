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
    sim = _dispatch("1000.1010")
    assert sim.peek(sim.sym["MODE"]) == 0xAE


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
