"""把 YuVibeStick 收音原始資料（.adpcm 檔，實為每 80 B 一個封包）包成 Ogg Opus，驗證「每個封包是一個 Opus 封包」的假設。

每個封包視為 20 ms 的 Opus 封包（48 kHz granule 每包加 960）。輸出的 .opus 可用 ffmpeg 解碼。

用法：python3 -I probe/wrap_ogg_opus.py <檔案.adpcm> <輸出.opus>
"""
import pathlib
import struct
import sys

PACKET_BYTES = 80
SAMPLES_PER_PACKET_48K = 960
PACKETS_PER_PAGE = 50
OGG_CRC_POLYNOMIAL = 0x04C11DB7
STREAM_SERIAL = 0x56494245  # 任意固定值


def build_crc_table():
    table = []
    for index in range(256):
        value = index << 24
        for _ in range(8):
            value = ((value << 1) ^ OGG_CRC_POLYNOMIAL) if value & 0x80000000 else value << 1
        table.append(value & 0xFFFFFFFF)
    return table


CRC_TABLE = build_crc_table()


def ogg_crc(page):
    crc = 0
    for byte in page:
        crc = ((crc << 8) ^ CRC_TABLE[((crc >> 24) ^ byte) & 0xFF]) & 0xFFFFFFFF
    return crc


def ogg_page(packets, granule, sequence, header_type):
    lacing = b""
    for packet in packets:
        lacing += bytes([255] * (len(packet) // 255) + [len(packet) % 255])
    header = struct.pack("<4sBBqIIIB", b"OggS", 0, header_type, granule, STREAM_SERIAL, sequence, 0, len(lacing))
    page = bytearray(header + lacing + b"".join(packets))
    struct.pack_into("<I", page, 22, ogg_crc(page))
    return bytes(page)


def wrap(raw):
    opus_head = b"OpusHead" + struct.pack("<BBHIhB", 1, 1, 0, 48000, 0, 0)
    opus_tags = b"OpusTags" + struct.pack("<I", 6) + b"vibe-s" + struct.pack("<I", 0)
    pages = [ogg_page([opus_head], 0, 0, 0x02), ogg_page([opus_tags], 0, 1, 0)]
    packets = [raw[i:i + PACKET_BYTES] for i in range(0, len(raw), PACKET_BYTES)]
    for page_index, start in enumerate(range(0, len(packets), PACKETS_PER_PAGE)):
        chunk = packets[start:start + PACKETS_PER_PAGE]
        granule = (start + len(chunk)) * SAMPLES_PER_PACKET_48K
        is_last = start + PACKETS_PER_PAGE >= len(packets)
        pages.append(ogg_page(chunk, granule, page_index + 2, 0x04 if is_last else 0))
    return b"".join(pages)


if __name__ == "__main__":
    pathlib.Path(sys.argv[2]).write_bytes(wrap(pathlib.Path(sys.argv[1]).read_bytes()))
