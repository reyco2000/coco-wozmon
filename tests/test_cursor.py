"""The blinking-cursor variant, src/wozmon-cursor.asm."""
from harness import CoCoSim, SRC_CURSOR, SCREEN
from test_monitor import type_line, KEY

CURGLYPH = 0x00          # screen code for '@'


def _sim():
    return CoCoSim(source=SRC_CURSOR)


def test_cursor_variant_shares_the_monitor_behaviour():
    """The only difference from the plain build is GETKEY, so a full
    session must still work exactly the same."""
    sim = _sim()
    type_line(sim, "1000: DE AD\r1000.1001\r")
    sim.run_entry_briefly(ops=400_000)
    assert "1000: DE AD" in "".join(sim.screen_text())


def test_cursor_blinks_while_waiting_for_a_key():
    """With nothing pressed, the cursor cell must alternate between the
    '@' glyph and whatever was underneath it."""
    sim = _sim()
    sim.cpu.direct_page.set(0)
    sim.cpu.system_stack_pointer.set(0x7EFF)
    sim.cpu.program_counter.set(sim.sym["ENTRY"])

    seen = set()
    cursor_addr = None
    for _ in range(600_000):
        sim.cpu.get_and_call_next_op()
        cur = sim.peek_word(sim.sym["CURSOR"])
        if SCREEN <= cur < SCREEN + 512:
            cursor_addr = cur
            seen.add(sim.peek(cur))
        if len(seen) > 1:
            break
    assert cursor_addr is not None, "cursor never landed on screen"
    assert CURGLYPH in seen, f"'@' glyph never drawn; saw {sorted(seen)}"
    assert len(seen) > 1, "cell never changed -- not blinking"


def test_cursor_is_erased_before_a_key_is_returned():
    """Whichever half of the blink we stop on, the character underneath
    must be restored -- the cursor must not leave a mark."""
    sim = _sim()
    type_line(sim, "1\r")
    sim.run_entry_briefly(ops=400_000)
    row = sim.screen_text()[1]
    assert row.startswith("1"), f"expected the typed '1', got {row!r}"
    # '@' would render as '@' via the harness's reverse mapping
    assert "@" not in "".join(sim.screen_text()), "cursor left behind on screen"
