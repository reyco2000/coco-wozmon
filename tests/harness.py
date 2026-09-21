"""Host-side CoCo 2 simulator for testing the Wozmon port."""
import pathlib
import re
import subprocess
import tempfile

from MC6809.components.cpu6809 import CPU
from MC6809.components.memory import Memory
from MC6809.core.configs import BaseConfig

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "wozmon.asm"

SENTINEL = 0x7F00          # RAM the monitor never executes; marks "subroutine returned"
SCREEN = 0x0400
SCREND = 0x0600
PIA0DA = 0xFF00            # keyboard rows, active low
PIA0DB = 0xFF02            # keyboard column strobe, active low


class _Cfg(BaseConfig):
    # MC6809 asserts RAM_SIZE * 2 <= 65536, so RAM caps at 32K.
    RAM_START, RAM_END = 0x0000, 0x7FFF
    ROM_START, ROM_END = 0x8000, 0xFFFF


def assemble(target=0, source=SRC):
    """Assemble the monitor. Returns (blob: bytes, symbols: dict[str, int])."""
    with tempfile.TemporaryDirectory() as td:
        out = pathlib.Path(td) / "o.bin"
        mp = pathlib.Path(td) / "o.map"
        proc = subprocess.run(
            ["lwasm", "--format=raw", f"--output={out}", f"--map={mp}",
             f"-DTARGET={target}", str(source)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            raise AssertionError(f"lwasm failed:\n{proc.stdout}\n{proc.stderr}")
        syms = {}
        for line in mp.read_text().splitlines():
            m = re.match(r"Symbol:\s+(\S+)\s+\(.*\)\s+=\s+([0-9A-Fa-f]+)", line)
            if m:
                syms[m.group(1)] = int(m.group(2), 16)
        return out.read_bytes(), syms


class CoCoSim:
    """A 6809 running the monitor, with a simulated CoCo keyboard and screen.

    Only TARGET=0 (origin $4000) is used for functional tests, because
    MC6809 caps RAM at 32K and the cart origin $C000 lands in its ROM area.
    The cart build is covered by Task 11's build tests plus hardware checks.
    """

    def __init__(self, target=0):
        blob, self.sym = assemble(target)
        cfg = _Cfg({"verbosity": None, "trace": None})
        self.mem = Memory(cfg)
        self.cpu = CPU(self.mem, cfg)
        self.mem.load(self.sym["ORIGIN"], bytearray(blob))
        self._keys = set()           # {(col, row)} currently held
        self._strobe = 0xFF
        self.mem.add_write_byte_callback(self._pia_write, PIA0DB)
        self.mem.add_read_byte_callback(self._pia_read, PIA0DA)
        self.poke(self.sym["CURSOR"], SCREEN >> 8)
        self.poke(self.sym["CURSOR"] + 1, SCREEN & 0xFF)
        self.clear_screen()

    # --- PIA simulation -------------------------------------------------
    def _pia_write(self, cycles, last_op, address, value):
        self._strobe = value

    def _pia_read(self, cycles, last_op, address):
        rows = 0
        for col, row in self._keys:
            if not (self._strobe >> col) & 1:     # column driven low = selected
                rows |= 1 << row
        return (~rows) & 0xFF                     # rows are active low

    def press(self, col, row):
        self._keys.add((col, row))

    def release_all(self):
        self._keys.clear()

    # --- memory ---------------------------------------------------------
    def peek(self, addr):
        return self.mem.read_byte(addr)

    def poke(self, addr, val):
        self.mem.write_byte(addr, val)

    def peek_word(self, addr):
        return (self.peek(addr) << 8) | self.peek(addr + 1)

    def poke_word(self, addr, val):
        self.poke(addr, (val >> 8) & 0xFF)
        self.poke(addr + 1, val & 0xFF)

    # --- screen ---------------------------------------------------------
    def clear_screen(self):
        for a in range(SCREEN, SCREND):
            self.poke(a, 0x20)

    def screen_text(self):
        """Screen as 16 rows of 32 chars, VDG codes mapped back to ASCII."""
        rows = []
        for r in range(16):
            base = SCREEN + r * 32
            rows.append("".join(
                self._vdg_to_ascii(self.peek(base + c)) for c in range(32)))
        return rows

    @staticmethod
    def _vdg_to_ascii(code):
        code &= 0x3F
        return chr(code + 0x40) if code < 0x20 else chr(code)

    # --- execution ------------------------------------------------------
    def run_sub(self, label, a=0, b=0, x=0, u=0, max_cycles=2_000_000):
        """Call a monitor subroutine and run until it returns.

        Pushes SENTINEL as the return address, so the routine's RTS lands
        there and MC6809's test_run stops.
        """
        self.cpu.accu_a.set(a)
        self.cpu.accu_b.set(b)
        self.cpu.index_x.set(x)
        self.cpu.user_stack_pointer.set(u)      # U, not index_u
        self.cpu.direct_page.set(self.sym["WORK"] >> 8)
        sp = 0x7EFF
        self.mem.write_byte(sp - 1, (SENTINEL >> 8) & 0xFF)
        self.mem.write_byte(sp, SENTINEL & 0xFF)
        self.cpu.system_stack_pointer.set(sp - 1)
        self.cpu.test_run(self.sym[label], SENTINEL, max_ops=max_cycles)
        return self.cpu.accu_a.value
