#!/usr/bin/env python3
"""Fail closed when an iOS XCTest screenshot is blank or has the wrong appearance."""

from __future__ import annotations

import argparse
import binascii
import json
import math
import struct
import tempfile
import zlib
from dataclasses import asdict, dataclass
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class ValidationError(Exception):
    pass


@dataclass(frozen=True)
class ScreenshotMetrics:
    width: int
    height: int
    appearance: str
    sampled_pixels: int
    mean_luminance: float
    p05_luminance: float
    p95_luminance: float
    dark_pixel_ratio: float
    bright_pixel_ratio: float
    opaque_pixel_ratio: float


def paeth(left: int, up: int, up_left: int) -> int:
    prediction = left + up - up_left
    left_distance = abs(prediction - left)
    up_distance = abs(prediction - up)
    up_left_distance = abs(prediction - up_left)
    if left_distance <= up_distance and left_distance <= up_left_distance:
        return left
    if up_distance <= up_left_distance:
        return up
    return up_left


def read_png(path: Path) -> tuple[int, int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValidationError("not a PNG file")

    offset = len(PNG_SIGNATURE)
    header: tuple[int, int, int, int, int] | None = None
    compressed = bytearray()
    saw_end = False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValidationError("truncated PNG chunk")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_start = offset + 8
        chunk_end = chunk_start + length
        crc_end = chunk_end + 4
        if crc_end > len(data):
            raise ValidationError("truncated PNG chunk payload")
        payload = data[chunk_start:chunk_end]
        expected_crc = struct.unpack(">I", data[chunk_end:crc_end])[0]
        actual_crc = binascii.crc32(chunk_type + payload) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValidationError(f"invalid PNG CRC for {chunk_type.decode('ascii', 'replace')}")
        offset = crc_end

        if chunk_type == b"IHDR":
            if length != 13 or header is not None:
                raise ValidationError("invalid PNG IHDR")
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if compression != 0 or filtering != 0 or interlace != 0:
                raise ValidationError("unsupported compressed, filtered, or interlaced PNG")
            header = (width, height, bit_depth, color_type, interlace)
        elif chunk_type == b"IDAT":
            compressed.extend(payload)
        elif chunk_type == b"IEND":
            saw_end = True
            break

    if header is None or not compressed or not saw_end:
        raise ValidationError("PNG is missing IHDR, IDAT, or IEND")

    width, height, bit_depth, color_type, _ = header
    if width == 0 or height == 0 or width > 10_000 or height > 10_000:
        raise ValidationError(f"unsupported PNG dimensions: {width}x{height}")
    if bit_depth != 8 or color_type not in (0, 2, 4, 6):
        raise ValidationError(f"unsupported PNG format: bit depth {bit_depth}, color type {color_type}")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    stride = width * channels
    try:
        filtered = zlib.decompress(bytes(compressed))
    except zlib.error as error:
        raise ValidationError(f"invalid PNG image data: {error}") from error
    expected_size = height * (stride + 1)
    if len(filtered) != expected_size:
        raise ValidationError(
            f"unexpected PNG image size: decoded {len(filtered)} bytes, expected {expected_size}"
        )

    decoded = bytearray(height * stride)
    previous = bytearray(stride)
    source_offset = 0
    for row_index in range(height):
        filter_type = filtered[source_offset]
        source_offset += 1
        source = filtered[source_offset : source_offset + stride]
        source_offset += stride
        row = bytearray(stride)
        for index, value in enumerate(source):
            left = row[index - channels] if index >= channels else 0
            up = previous[index]
            up_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                result = value
            elif filter_type == 1:
                result = value + left
            elif filter_type == 2:
                result = value + up
            elif filter_type == 3:
                result = value + ((left + up) // 2)
            elif filter_type == 4:
                result = value + paeth(left, up, up_left)
            else:
                raise ValidationError(f"unsupported PNG row filter {filter_type}")
            row[index] = result & 0xFF
        start = row_index * stride
        decoded[start : start + stride] = row
        previous = row
    return width, height, color_type, bytes(decoded)


def validate(path: Path, appearance: str) -> ScreenshotMetrics:
    width, height, color_type, pixels = read_png(path)
    if width < 320 or height < 600:
        raise ValidationError(f"screenshot is too small: {width}x{height}")

    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    total_pixels = width * height
    sample_step = max(1, math.ceil(math.sqrt(total_pixels / 200_000)))
    luminances: list[float] = []
    opaque = 0
    for y in range(0, height, sample_step):
        for x in range(0, width, sample_step):
            offset = (y * width + x) * channels
            if color_type in (0, 4):
                red = green = blue = pixels[offset]
            else:
                red, green, blue = pixels[offset : offset + 3]
            alpha = pixels[offset + channels - 1] if color_type in (4, 6) else 255
            opaque += int(alpha == 255)
            luminances.append((0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0)

    luminances.sort()
    count = len(luminances)
    mean = sum(luminances) / count
    p05 = luminances[int((count - 1) * 0.05)]
    p95 = luminances[int((count - 1) * 0.95)]
    dark_ratio = sum(value < 0.35 for value in luminances) / count
    bright_ratio = sum(value > 0.65 for value in luminances) / count
    opaque_ratio = opaque / count
    metrics = ScreenshotMetrics(
        width=width,
        height=height,
        appearance=appearance,
        sampled_pixels=count,
        mean_luminance=round(mean, 4),
        p05_luminance=round(p05, 4),
        p95_luminance=round(p95, 4),
        dark_pixel_ratio=round(dark_ratio, 4),
        bright_pixel_ratio=round(bright_ratio, 4),
        opaque_pixel_ratio=round(opaque_ratio, 4),
    )

    if opaque_ratio < 0.999:
        raise ValidationError(f"screenshot contains transparent pixels: {json.dumps(asdict(metrics))}")
    if p95 - p05 < 0.18:
        raise ValidationError(f"screenshot lacks visible contrast: {json.dumps(asdict(metrics))}")
    if appearance == "light":
        if mean < 0.55 or dark_ratio < 0.005:
            raise ValidationError(f"light screenshot is blank or too dark: {json.dumps(asdict(metrics))}")
    elif appearance == "dark":
        if mean > 0.55 or bright_ratio < 0.005:
            raise ValidationError(f"dark screenshot is blank or too bright: {json.dumps(asdict(metrics))}")
    else:
        raise ValidationError(f"unsupported appearance: {appearance}")
    return metrics


def png_chunk(chunk_type: bytes, payload: bytes) -> bytes:
    crc = binascii.crc32(chunk_type + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + chunk_type + payload + struct.pack(">I", crc)


def write_fixture(path: Path, mode: str) -> None:
    width, height = 320, 600
    rgba = mode == "transparent"
    channels = 4 if rgba else 3
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            if mode == "light":
                value = 20 if x < 48 or (250 < y < 300) else 245
            elif mode == "dark":
                value = 235 if x < 48 or (250 < y < 300) else 12
            elif mode == "white":
                value = 255
            else:
                value = 0
            rows.extend((value, value, value))
            if rgba:
                rows.append(0)
    color_type = 6 if channels == 4 else 2
    header = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    path.write_bytes(
        PNG_SIGNATURE
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", zlib.compress(bytes(rows)))
        + png_chunk(b"IEND", b"")
    )


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for mode, appearance in (("light", "light"), ("dark", "dark")):
            path = root / f"{mode}.png"
            write_fixture(path, mode)
            validate(path, appearance)

        for mode, appearance in (
            ("black", "light"),
            ("white", "light"),
            ("dark", "light"),
            ("transparent", "dark"),
        ):
            path = root / f"reject-{mode}-{appearance}.png"
            write_fixture(path, mode)
            try:
                validate(path, appearance)
            except ValidationError:
                pass
            else:
                raise AssertionError(f"validator accepted {mode} as {appearance}")
    print("validate_ios_screenshot.py self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", type=Path)
    parser.add_argument("--appearance", choices=("light", "dark"))
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0
    if args.path is None or args.appearance is None:
        raise SystemExit("path and --appearance are required unless --self-test is used")
    try:
        metrics = validate(args.path, args.appearance)
    except (OSError, ValidationError) as error:
        print(f"Screenshot validation failed: {error}")
        return 1
    print(json.dumps(asdict(metrics), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
