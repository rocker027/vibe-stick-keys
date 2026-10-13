"""離線比較 YuVibeStick 收音原始資料（.adpcm）的解碼方式。

用 IMA ADPCM 的兩種半位元組順序解碼，計算訊號特徵，並各輸出一個 WAV 供人耳比對。
正確的解碼通常較平滑（相鄰取樣差距相對 RMS 較小）、少有削峰、step index 不會長期卡在高檔。

用法：python3 -I probe/analyze_adpcm.py <檔案.adpcm> [輸出資料夾]
"""
import math
import pathlib
import struct
import sys

STEP_TABLE = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
    107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
    5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
    27086, 29794, 32767,
]
INDEX_TABLE = [-1, -1, -1, -1, 2, 4, 6, 8]
SAMPLE_RATES = [8000, 16000]
HIGH_INDEX_THRESHOLD = 60
PACKET_BYTES = 80


def decode(raw, low_first):
    """回傳（取樣, 每個取樣解碼時的 step index）。"""
    predictor, index = 0, 0
    samples, indices = [], []
    for byte in raw:
        nibbles = (byte & 0x0F, byte >> 4) if low_first else (byte >> 4, byte & 0x0F)
        for nibble in nibbles:
            step = STEP_TABLE[index]
            difference = step >> 3
            if nibble & 4:
                difference += step
            if nibble & 2:
                difference += step >> 1
            if nibble & 1:
                difference += step >> 2
            predictor += -difference if nibble & 8 else difference
            predictor = max(-32768, min(32767, predictor))
            index = max(0, min(len(STEP_TABLE) - 1, index + INDEX_TABLE[nibble & 7]))
            samples.append(predictor)
            indices.append(index)
    return samples, indices


def describe(samples, indices):
    rms = math.sqrt(sum(value * value for value in samples) / len(samples)) or 1.0
    roughness = sum(abs(samples[i] - samples[i - 1]) for i in range(1, len(samples))) / (len(samples) - 1) / rms
    clipped = sum(1 for value in samples if abs(value) >= 32767) / len(samples)
    high_index = sum(1 for index in indices if index >= HIGH_INDEX_THRESHOLD) / len(indices)
    return f"RMS {rms:8.1f}  相鄰差/RMS {roughness:5.3f}  削峰 {clipped:6.2%}  高 step 比例 {high_index:6.2%}"


def write_wav(path, samples, sample_rate):
    pcm_bytes = struct.pack(f"<{len(samples)}h", *samples)
    header = b"RIFF" + struct.pack("<I", 36 + len(pcm_bytes)) + b"WAVEfmt "
    header += struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(pcm_bytes))
    path.write_bytes(header + pcm_bytes)


def decode_per_packet(raw, low_first):
    """每個封包都從初始狀態解碼（YuVibeStick 的編碼器在每個封包開頭重設狀態）。"""
    samples, indices = [], []
    for start in range(0, len(raw), PACKET_BYTES):
        packet_samples, packet_indices = decode(raw[start:start + PACKET_BYTES], low_first)
        samples += packet_samples
        indices += packet_indices
    return samples, indices


def main(source, output_folder):
    raw = source.read_bytes()
    print(f"{source.name}：{len(raw)} B，若為 4-bit 則 {len(raw) * 2} 個取樣")
    output_folder.mkdir(parents=True, exist_ok=True)
    for low_first in (True, False):
        for is_per_packet in (False, True):
            samples, indices = (decode_per_packet if is_per_packet else decode)(raw, low_first)
            order = ("low-first" if low_first else "high-first") + ("-per-packet" if is_per_packet else "")
            print(f"  {order:22s} {describe(samples, indices)}")
            write_variants(output_folder, source.stem, order, samples)


def write_variants(output_folder, stem, order, samples):
    for sample_rate in SAMPLE_RATES:
        target = output_folder / f"{stem}-{order}-{sample_rate // 1000}k.wav"
        write_wav(target, samples, sample_rate)
        print(f"    → {target}（{len(samples) / sample_rate:.2f} 秒）")


if __name__ == "__main__":
    source_path = pathlib.Path(sys.argv[1])
    main(source_path, pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else source_path.parent / "variants")
