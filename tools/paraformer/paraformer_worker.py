import argparse
import json
import os
import sys
import traceback
from pathlib import Path

os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

import torch
from funasr import AutoModel


def srt_time(milliseconds: int) -> str:
    milliseconds = max(0, int(milliseconds))
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    seconds, milliseconds = divmod(milliseconds, 1_000)
    return f"{hours:02}:{minutes:02}:{seconds:02},{milliseconds:03}"


MODEL_SNAPSHOTS = {
    "model": "iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
    "vad": "iic--speech_fsmn_vad_zh-cn-16k-common-pytorch",
    "punc": "iic--punc_ct-transformer_cn-en-common-vocab471067-large",
}
GPU_BATCH_SIZES = (60, 30, 15)


def local_snapshot(cache_root: Path, key: str) -> str:
    path = cache_root / "models" / MODEL_SNAPSHOTS[key] / "snapshots" / "master"
    if not path.is_dir():
        raise RuntimeError(f"本地 Paraformer 缓存不完整，缺少{key}模型目录：{path}")
    return str(path.resolve())


def is_cuda_compatibility_error(exc: Exception) -> bool:
    text = str(exc).lower()
    return any(marker in text for marker in (
        "no kernel image is available for execution on the device",
        "cuda error: no kernel image",
        "invalid device function",
        "cuda capability",
    ))


def is_cuda_out_of_memory_error(exc: Exception) -> bool:
    return "out of memory" in str(exc).lower()


def build_model(cache_root: Path, device: str):
    if device == "cuda" and os.environ.get("PARAFORMER_TEST_FORCE_CUDA_FAILURE") == "1":
        raise RuntimeError("CUDA error: no kernel image is available for execution on the device")
    return AutoModel(
        model=local_snapshot(cache_root, "model"),
        vad_model=local_snapshot(cache_root, "vad"),
        punc_model=local_snapshot(cache_root, "punc"),
        device=device,
        disable_update=True,
    )


def announce_cpu_fallback(reason: str = "GPU incompatible"):
    print(f"PARAFORMER_DEVICE_FALLBACK=cpu; {reason}, using CPU", file=sys.stderr)


def load_model():
    cache_value = os.environ.get("MODELSCOPE_CACHE")
    if not cache_value:
        raise RuntimeError("未设置 MODELSCOPE_CACHE，无法使用离线 Paraformer 缓存。")
    cache_root = Path(cache_value)
    prefer_cuda = torch.cuda.is_available() or os.environ.get("PARAFORMER_TEST_FORCE_CUDA_FAILURE") == "1"
    if prefer_cuda:
        try:
            return build_model(cache_root, "cuda"), "cuda"
        except RuntimeError as exc:
            if not (is_cuda_compatibility_error(exc) or is_cuda_out_of_memory_error(exc)):
                raise
            try:
                torch.cuda.empty_cache()
            except Exception:
                pass
            announce_cpu_fallback("GPU memory insufficient" if is_cuda_out_of_memory_error(exc) else "GPU incompatible")
    return build_model(cache_root, "cpu"), "cpu"


def generate_subtitles(model, device: str, cache_root: Path, audio_path: str):
    if device != "cuda":
        return model.generate(input=audio_path, batch_size_s=GPU_BATCH_SIZES[0], sentence_timestamp=True)

    for batch_size_s in GPU_BATCH_SIZES:
        try:
            return model.generate(input=audio_path, batch_size_s=batch_size_s, sentence_timestamp=True)
        except RuntimeError as exc:
            if not is_cuda_out_of_memory_error(exc):
                raise
            print(f"PARAFORMER_CUDA_OOM=batch_size_s:{batch_size_s}; retrying smaller batch", file=sys.stderr)
            torch.cuda.empty_cache()

    announce_cpu_fallback("GPU memory insufficient")
    del model
    torch.cuda.empty_cache()
    cpu_model = build_model(cache_root, "cpu")
    return cpu_model.generate(input=audio_path, batch_size_s=GPU_BATCH_SIZES[0], sentence_timestamp=True)


def write_subtitles(result, audio_path: str, srt_path: str, json_path: str):
    data = result[0]
    sentences = data.get("sentence_info", [])
    if not sentences:
        raise RuntimeError(f"Paraformer 未返回句级时间戳：{audio_path}")

    Path(json_path).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    blocks = []
    for index, sentence in enumerate(sentences, 1):
        text = (sentence.get("text") or sentence.get("sentence") or "").strip()
        if not text:
            continue
        start = sentence.get("start", sentence.get("start_time", 0))
        end = sentence.get("end", sentence.get("end_time", start + 1_000))
        blocks.append(f"{index}\n{srt_time(start)} --> {srt_time(end)}\n{text}")
    if not blocks:
        raise RuntimeError(f"Paraformer 未返回可用字幕文本：{audio_path}")
    Path(srt_path).write_text("\n\n".join(blocks) + "\n", encoding="utf-8")
    print(f"完成：{audio_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--warmup", action="store_true")
    parser.add_argument("--audio")
    parser.add_argument("--srt")
    parser.add_argument("--json")
    parser.add_argument("--batch-manifest")
    args = parser.parse_args()

    if args.warmup:
        load_model()
        print("Paraformer-large 模型已就绪。")
        return
    if args.batch_manifest:
        entries = json.loads(Path(args.batch_manifest).read_text(encoding="utf-8"))
        if not isinstance(entries, list) or not entries:
            raise ValueError("批量识别清单必须是非空数组。")
        model, device = load_model()
        cache_root = Path(os.environ["MODELSCOPE_CACHE"])
        for entry in entries:
            if not isinstance(entry, dict) or not all(entry.get(key) for key in ("audio", "srt", "json")):
                raise ValueError("批量识别清单缺少 audio、srt 或 json。")
            write_subtitles(generate_subtitles(model, device, cache_root, entry["audio"]), entry["audio"], entry["srt"], entry["json"])
        return
    if not args.audio or not args.srt or not args.json:
        raise ValueError("需要 --audio、--srt 和 --json 参数。")

    model, device = load_model()
    write_subtitles(generate_subtitles(model, device, Path(os.environ["MODELSCOPE_CACHE"]), args.audio), args.audio, args.srt, args.json)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Paraformer failed: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        raise
