from harness import CoCoSim, SCREEN, assemble


def test_assembles_and_exports_symbols():
    _, syms = assemble(target=0)
    for name in ("ENTRY", "WORK", "ORIGIN", "XAM", "MODE", "IN"):
        assert name in syms, f"missing symbol {name}"
    assert syms["ORIGIN"] == 0x4000
    assert syms["WORK"] == 0x3F00


def test_both_targets_assemble():
    _, bin_syms = assemble(target=0)
    _, cart_syms = assemble(target=1)
    assert bin_syms["ORIGIN"] == 0x4000
    assert cart_syms["ORIGIN"] == 0xC000
    assert cart_syms["WORK"] == 0x0600


def test_run_sub_returns_at_sentinel():
    """ENTRY is currently just setup + RTS, so it must return cleanly."""
    sim = CoCoSim()
    sim.run_sub("ENTRY")
    assert sim.cpu.direct_page.value == 0x3F


def test_pia_simulation_reports_pressed_key():
    sim = CoCoSim()
    sim.press(col=2, row=5)              # the ':' key
    sim.poke(0xFF02, 0xFF & ~(1 << 2))   # strobe column 2
    assert sim.peek(0xFF00) == (~(1 << 5)) & 0xFF
    sim.poke(0xFF02, 0xFF & ~(1 << 3))   # strobe a different column
    assert sim.peek(0xFF00) == 0xFF      # nothing pressed there


def test_screen_starts_blank():
    sim = CoCoSim()
    assert sim.screen_text()[0] == " " * 32
