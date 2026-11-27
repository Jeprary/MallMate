"""Local-only audio worker. stdout contains response JSON only, never diagnostics."""
import contextlib
import json
import os
import subprocess
import sys
import tempfile
import wave

MODEL, FFMPEG = sys.argv[1:3]
PROVIDER = sys.argv[3] if len(sys.argv) > 3 else "whisper"
model = None
FORMATS = {"matroska", "ogg", "wav", "mov", "mp3", "aac", "flac"}


def run(task):
    global model
    filename = task.get("file", "")
    if task.get("format") not in FORMATS or task.get("language") not in (None, "zh", "en"):
        return {"error": "invalid_audio"}
    if not os.path.isfile(filename) or os.path.getsize(filename) > 6 * 1024 * 1024:
        return {"error": "invalid_audio"}
    # Decode at most 31 seconds, then reject >30; never silently truncate a long recording.
    with tempfile.TemporaryDirectory(prefix="decoded-", dir=os.path.dirname(filename)) as directory:
        wav = os.path.join(directory, "audio.wav")
        try:
            subprocess.run([FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                            "-protocol_whitelist", "file,pipe", "-f", task["format"], "-i", filename,
                            "-map", "0:a:0", "-vn", "-t", "31", "-ac", "1", "-ar", "16000",
                            "-c:a", "pcm_s16le", wav], check=True, timeout=30,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with wave.open(wav, "rb") as audio:
                seconds = audio.getnframes() / audio.getframerate()
            if seconds > 30:
                return {"error": "too_long"}
            if seconds < 0.1:
                return {"error": "invalid_audio"}
            # Exact digital silence has no speech content. Do not let an
            # autoregressive decoder turn an empty recording into filler words.
            with wave.open(wav, "rb") as decoded:
                if not any(decoded.readframes(decoded.getnframes())):
                    return {"error": "no_speech"}
        except (subprocess.SubprocessError, OSError, wave.Error, EOFError):
            return {"error": "invalid_audio"}
        try:
            with contextlib.redirect_stdout(sys.stderr):
                if PROVIDER == "qwen":
                    if model is None:
                        from mlx_audio.stt import load
                        model = load(MODEL)
                    language = {"zh": "Chinese", "en": "English"}.get(task.get("language"))
                    result = model.generate(wav, language=language, max_tokens=512, temperature=0.0, verbose=False)
                    text = result.text.strip() if isinstance(result.text, str) else ""
                    reported = getattr(result, "language", None)
                    if isinstance(reported, (list, tuple)):
                        reported = ", ".join(dict.fromkeys(item.strip() for item in reported if isinstance(item, str) and item.strip()))
                    detected = reported.strip() if isinstance(reported, str) else ""
                    return {"text": text, "language": detected} if text else {"error": "no_speech"}
                if model is None:
                    from faster_whisper import WhisperModel
                    model = WhisperModel(MODEL, device="cpu", compute_type="int8", local_files_only=True)
                import numpy as np
                with wave.open(wav, "rb") as decoded:
                    samples = np.frombuffer(decoded.readframes(decoded.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
                segments, info = model.transcribe(samples, language=task.get("language"), beam_size=3,
                                                  vad_filter=True, condition_on_previous_text=False)
                text = " ".join(segment.text.strip() for segment in segments).strip()
            return {"text": text, "language": info.language} if text else {"error": "no_speech"}
        except Exception:
            return {"error": "unavailable"}


for line in sys.stdin:
    task = {}
    try:
        task = json.loads(line)
        result = run(task)
    except Exception:
        result = {"error": "invalid_audio"}
    print(json.dumps({"id": task.get("id"), **result}, ensure_ascii=False), flush=True)
