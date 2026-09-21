"""The examples/hello.asm program, typed in and run through the monitor."""
import pathlib
import subprocess

from harness import CoCoSim
from test_monitor import type_line, KEY

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _hello_bytes():
    out = ROOT / "examples" / "hello.bin"
    subprocess.run(["lwasm", "--format=raw", f"--output={out}",
                    str(ROOT / "examples" / "hello.asm")], check=True,
                   capture_output=True)
    return out.read_bytes()


def test_hello_example_assembles_to_expected_entry():
    data = _hello_bytes()
    assert data[0] == 0x8E          # LDX #MSG
    assert data[7:10] == b"\xBD\x40\x3C"   # JSR PUTCHAR at the monitor entry
    assert b"HELLO WORLD" in data


def test_hello_example_runs_from_the_monitor():
    """Type the program in as hex and run it, exactly as a user would."""
    data = _hello_bytes()
    lines = []
    for i in range(0, len(data), 8):
        chunk = data[i:i + 8]
        lines.append(f"{0x1000 + i:04X}: " + " ".join(f"{b:02X}" for b in chunk))
    session = "\r".join(lines) + "\r1000R\r"
    assert not {c for c in session if c not in KEY}

    sim = CoCoSim()
    type_line(sim, session)
    sim.run_entry_briefly(ops=1_500_000)
    assert "HELLO WORLD" in "".join(sim.screen_text())
