import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _build():
    subprocess.run(["make", "clean", "all"], cwd=ROOT, check=True,
                   capture_output=True)


def test_both_images_build():
    _build()
    assert (ROOT / "build" / "wozmon.bin").exists()
    assert (ROOT / "build" / "wozmon.rom").exists()


def test_cart_image_is_exactly_8k():
    _build()
    assert (ROOT / "build" / "wozmon.rom").stat().st_size == 8192


def test_bin_image_is_decb_format():
    """DECB preamble: $00, 2-byte length, 2-byte load address."""
    _build()
    data = (ROOT / "build" / "wozmon.bin").read_bytes()
    assert data[0] == 0x00
    load_addr = (data[3] << 8) | data[4]
    assert load_addr == 0x4000


def test_bin_postamble_sets_exec_address():
    """Trailer: $FF, $0000, then the exec address from the end directive."""
    _build()
    data = (ROOT / "build" / "wozmon.bin").read_bytes()
    assert data[-5] == 0xFF
    exec_addr = (data[-2] << 8) | data[-1]
    assert exec_addr == 0x4000


def test_cursor_images_build_too():
    _build()
    assert (ROOT / "build" / "wozmonc.bin").exists()
    assert (ROOT / "build" / "wozmonc.rom").exists()


def test_cursor_cart_is_also_exactly_8k():
    _build()
    assert (ROOT / "build" / "wozmonc.rom").stat().st_size == 8192


def test_cursor_build_is_larger_than_plain():
    """The cursor is the only difference, so it must cost a few bytes."""
    _build()
    plain = (ROOT / "build" / "wozmon.bin").stat().st_size
    cursor = (ROOT / "build" / "wozmonc.bin").stat().st_size
    assert cursor > plain
