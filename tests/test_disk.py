"""WOZMON.DSK must stay in sync with what the source currently builds."""
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DSK = ROOT / "WOZMON.DSK"

FAT = 17 * 18 * 256 + 1 * 256      # track 17, sector 2
DIR = 17 * 18 * 256 + 2 * 256      # track 17, sector 3
EXPECTED = {"WOZMON.BIN": "build/wozmon.bin",
            "WOZMONC.BIN": "build/wozmonc.bin"}


def _gran_offset(g):
    """Granules 0-33 map to tracks 0-16; track 17 is the directory."""
    track = g // 2
    if track >= 17:
        track += 1
    return track * 18 * 256 + (g % 2) * 9 * 256


def _read_disk():
    """Return {filename: contents} by walking the directory and FAT chains."""
    d = DSK.read_bytes()
    files = {}
    for i in range(DIR, DIR + 8 * 256, 32):
        e = d[i:i + 32]
        if not e or e[0] in (0x00, 0xFF):
            continue
        name = e[0:8].decode().rstrip() + "." + e[8:11].decode().rstrip()
        last_bytes = (e[14] << 8) | e[15]
        blob, g = b"", e[13]
        while True:
            link = d[FAT + g]
            off = _gran_offset(g)
            if link >= 0xC0:                       # final granule of the chain
                blob += d[off: off + (link - 0xC0 - 1) * 256 + last_bytes]
                break
            blob += d[off: off + 2304]
            g = link
        files[name] = blob
    return files


@pytest.fixture(scope="module")
def disk():
    if not DSK.exists():
        pytest.skip("WOZMON.DSK not present")
    subprocess.run(["make", "clean", "all"], cwd=ROOT, check=True,
                   capture_output=True)
    return _read_disk()


def test_disk_is_a_standard_35_track_image():
    if not DSK.exists():
        pytest.skip("WOZMON.DSK not present")
    assert DSK.stat().st_size == 35 * 18 * 256      # 161280


def test_disk_holds_both_builds(disk):
    assert set(disk) == set(EXPECTED)


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_disk_copy_matches_current_build(disk, name):
    """Catches a disk image left behind after the source changed."""
    current = (ROOT / EXPECTED[name]).read_bytes()
    assert disk[name] == current, (
        f"{name} on WOZMON.DSK is stale -- rebuild and rewrite the disk")


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_disk_copy_loads_and_runs_at_4000(disk, name):
    blob = disk[name]
    assert blob[0] == 0x00                          # DECB preamble
    assert (blob[3] << 8) | blob[4] == 0x4000       # load address
    assert (blob[-2] << 8) | blob[-1] == 0x4000     # exec address
