#!/usr/bin/env python3
import json
import sys
import wave


def response(payload):
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()


def read_request():
    try:
        return json.loads(sys.stdin.read())
    except Exception as exc:
        response({"error": f"invalid request JSON: {exc}"})
        sys.exit(0)


def wav_duration_and_rate(path):
    with wave.open(path, "rb") as wav:
        frames = wav.getnframes()
        sample_rate = wav.getframerate()
        duration = frames / float(sample_rate) if sample_rate else 0.0
        return duration, sample_rate


def main():
    request = read_request()
    wav_path = request.get("wavPath")
    model_id = request.get("modelID") or "speechbrain/spkrec-ecapa-voxceleb"
    if not wav_path:
        response({"error": "wavPath is required"})
        return

    try:
        duration_seconds, sample_rate = wav_duration_and_rate(wav_path)
    except Exception as exc:
        response({"error": f"failed to read WAV: {exc}"})
        return

    try:
        import torch
        from speechbrain.inference.speaker import EncoderClassifier
        from torchaudio import load as load_audio
    except Exception as exc:
        response({"error": f"speechbrain dependencies are not installed: {exc}"})
        return

    try:
        classifier = EncoderClassifier.from_hparams(source=model_id)
        signal, _ = load_audio(wav_path)
        with torch.no_grad():
            embedding = classifier.encode_batch(signal).squeeze()
        vector = embedding.detach().cpu().reshape(-1).tolist()
    except Exception as exc:
        response({"error": f"embedding failed: {exc}"})
        return

    response({
        "modelID": model_id,
        "embedding": vector,
        "durationSeconds": duration_seconds,
        "sampleRate": sample_rate,
        "quality": {
            "embeddingDimensions": str(len(vector))
        }
    })


if __name__ == "__main__":
    main()
