"""Draw the app icon and write it as a multi-size .ico.  Usage: make_icon.py <out.ico> [preview.png]"""
import struct
import sys

from PySide6.QtCore import QBuffer, QByteArray, QIODevice, QRectF, Qt
from PySide6.QtGui import QColor, QImage, QPainter

SIZES = [16, 24, 32, 48, 64, 128, 256]

# (x, y, width, height, colour) on a 256 grid: a centre tile flanked by two receding ones.
TILES = [
    (34, 84, 50, 88, "#8b8f98"),
    (172, 84, 50, 88, "#8b8f98"),
    (92, 56, 72, 144, "#f4f1ea"),
]


def draw(size):
    image = QImage(size, size, QImage.Format.Format_ARGB32)
    image.fill(Qt.GlobalColor.transparent)
    p = QPainter(image)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.scale(size / 256, size / 256)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QColor("#17181c"))
    p.drawRoundedRect(QRectF(8, 8, 240, 240), 52, 52)
    for x, y, w, h, colour in TILES:
        p.setBrush(QColor(colour))
        p.drawRoundedRect(QRectF(x, y, w, h), 10, 10)
    p.end()
    return image


def png_bytes(image):
    data = QByteArray()
    buf = QBuffer(data)
    buf.open(QIODevice.OpenModeFlag.WriteOnly)
    image.save(buf, "PNG")
    buf.close()
    return bytes(data)


def main():
    out = sys.argv[1]
    blobs = [png_bytes(draw(s)) for s in SIZES]
    header = struct.pack("<HHH", 0, 1, len(SIZES))
    offset = len(header) + 16 * len(SIZES)
    entries = b""
    for size, blob in zip(SIZES, blobs):
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    with open(out, "wb") as f:
        f.write(header + entries + b"".join(blobs))
    if len(sys.argv) > 2:
        draw(256).save(sys.argv[2])


if __name__ == "__main__":
    main()
