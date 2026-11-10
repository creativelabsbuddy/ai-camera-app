"""v11.39: 4K request maps to Ultra HD; colour gain cap; chroma softening."""
import io
from PIL import Image
import color_match as CM


def test_gain_cap_and_soften():
    assert CM._MAX_GAIN <= 1.0
    b = io.BytesIO(); Image.new("RGB", (64, 64), (120, 80, 40)).save(b, "JPEG")
    out = CM.soften_chroma(b.getvalue())
    assert Image.open(io.BytesIO(out)).size == (64, 64)


def test_4k_mapped():
    src = open("main.py").read()
    assert 'if quality == "4k":' in src and 'quality = "ultra_hd"' in src
