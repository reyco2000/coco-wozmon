import pytest
from harness import CoCoSim

CR, ESC, BS = 0x0D, 0x1B, 0x08


@pytest.mark.parametrize("col,row,expected", [
    (0, 4, "0"), (7, 4, "7"), (0, 5, "8"), (1, 5, "9"),
    (1, 0, "A"), (2, 0, "B"), (6, 0, "F"),
    (2, 2, "R"),
    (6, 5, "."), (2, 5, ":"),
])
def test_scankey_maps_matrix_to_ascii(col, row, expected):
    sim = CoCoSim()
    sim.press(col, row)
    assert chr(sim.run_sub("SCANKEY")) == expected


@pytest.mark.parametrize("col,row,expected", [
    (0, 6, CR),    # ENTER
    (2, 6, ESC),   # BREAK
    (5, 3, BS),    # left arrow
])
def test_scankey_maps_control_keys(col, row, expected):
    sim = CoCoSim()
    sim.press(col, row)
    assert sim.run_sub("SCANKEY") == expected


def test_scankey_returns_zero_when_nothing_pressed():
    sim = CoCoSim()
    assert sim.run_sub("SCANKEY") == 0


def test_scankey_returns_zero_for_unused_matrix_positions():
    sim = CoCoSim()
    sim.press(7, 6)          # SHIFT, unused by the monitor
    assert sim.run_sub("SCANKEY") == 0


def test_scankey_preserves_registers():
    sim = CoCoSim()
    sim.press(1, 0)
    sim.run_sub("SCANKEY", b=0x77, x=0x4321)
    assert sim.cpu.accu_b.value == 0x77
    assert sim.cpu.index_x.value == 0x4321
