import pytest
from harness import CoCoSim


def _printed(sim):
    return sim.screen_text()[0].rstrip()


@pytest.mark.parametrize("value,expected", [
    (0x00, "00"), (0x09, "09"), (0x0A, "0A"), (0x0F, "0F"),
    (0xA0, "A0"), (0xFF, "FF"), (0x5A, "5A"), (0x3C, "3C"),
])
def test_prbyte_prints_two_hex_digits(value, expected):
    sim = CoCoSim()
    sim.run_sub("PRBYTE", a=value)
    assert _printed(sim) == expected


@pytest.mark.parametrize("value,expected", [
    (0x00, "0"), (0x09, "9"), (0x0A, "A"), (0x0F, "F"),
    (0xF3, "3"),   # high nibble must be ignored
])
def test_prhex_prints_low_nibble(value, expected):
    sim = CoCoSim()
    sim.run_sub("PRHEX", a=value)
    assert _printed(sim) == expected


def test_nine_to_a_boundary():
    """The ':' between '9' and 'A' in ASCII is where the +7 fixup matters."""
    sim = CoCoSim()
    sim.run_sub("PRBYTE", a=0x9A)
    assert _printed(sim) == "9A"
