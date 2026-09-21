import pytest
from harness import CoCoSim


def _parse(text):
    """Load text into IN, run PARSEHEX, return (HEX value, stop index)."""
    sim = CoCoSim()
    base = sim.sym["IN"]
    for i, ch in enumerate(text):
        sim.poke(base + i, ord(ch))
    sim.poke_word(sim.sym["HEX"], 0)
    sim.run_sub("PARSEHEX", b=0, u=base)
    return sim.peek_word(sim.sym["HEX"]), sim.cpu.accu_b.value


@pytest.mark.parametrize("text,value", [
    ("0", 0x0000), ("F", 0x000F), ("FF", 0x00FF),
    ("1234", 0x1234), ("ABCD", 0xABCD), ("DEAD", 0xDEAD),
    ("00FF", 0x00FF), ("E000", 0xE000),
])
def test_parses_hex_value(text, value):
    assert _parse(text + " ")[0] == value


def test_keeps_only_last_four_digits():
    """The original shifts left without overflow checking."""
    assert _parse("12345 ")[0] == 0x2345


def test_stops_at_first_non_hex():
    value, idx = _parse("1A.")
    assert value == 0x001A
    assert idx == 2


def test_lowercase_is_not_hex():
    """The CoCo 2 keyboard produces uppercase only; 'a' must not parse."""
    value, idx = _parse("a")
    assert idx == 0


def test_g_is_not_hex():
    value, idx = _parse("1G")
    assert value == 0x0001
    assert idx == 1
