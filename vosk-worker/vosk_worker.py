#!/usr/bin/env python3
"""
==============================================================================
MVNO Voice Call Interception & Speech Translation Pipeline — Vosk Worker
==============================================================================
This worker daemon monitors RTPEngine's PCAP spool directory (/var/spool/rtpengine),
converts PCAP audio captures into 16kHz mono WAV format using ffmpeg, transcribes
the speech offline using the local Vosk ASR model, extracts voice biometrics, and
posts the transcript to the Spring Boot Interception Gateway (/api/v1/transcriptions).

Key Capabilities:
1. PCAP-to-WAV conversion via ffmpeg (RTPEngine records PCAP frames, not raw WAV).
2. Offline Speech-to-Text via Vosk (zero cloud dependency, zero external API latency).
3. Voice Biometrics: Calculates silence ratio (robocall detection) & spectral flatness (TTS synthetic detection).
4. DTMF Keypress Parsing from RTPEngine companion JSON metadata.
"""

import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path

import httpx
import soundfile as sf
import numpy as np
from vosk import Model, KaldiRecognizer

# Spool directory shared with RTPEngine container via volume mount
SPOOL_DIR = "/var/spool/rtpengine"

# Local Vosk Speech-to-Text English model directory
MODEL_PATH = "/opt/vosk-model-small-en-us-0.15"

# Spring Boot Gateway REST endpoint for post-call transcription analytics
API_URL = "http://telecom-api:8080/api/v1/transcriptions"

# Directory polling interval in seconds
POLL_INTERVAL = 2

# Logging setup
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("vosk-worker")


def pcap_to_wav(pcap_path: str) -> str | None:
    """
    Converts RTPEngine PCAP (Ethernet frame format) to 16kHz Mono WAV format for Vosk ASR.
    
    :param pcap_path: Path to the input .pcap file in /var/spool/rtpengine.
    :return: Output .wav file path, or None if conversion failed.
    """
    wav_path = pcap_path.replace(".pcap", ".wav")
    try:
        # ffmpeg extracts PCM audio stream, resamples to 16,000 Hz, downmixes to 1 channel
        subprocess.run(
            ["ffmpeg", "-y", "-i", pcap_path, "-acodec", "pcm_s16le",
             "-ar", "16000", "-ac", "1", wav_path],
            capture_output=True, timeout=30, check=True
        )
        logger.info(f"Successfully converted PCAP → WAV: {wav_path}")
        return wav_path
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        logger.error(f"PCAP to WAV conversion failed for {pcap_path}: {e}")
        return None


def extract_voice_biometrics(wav_path: str) -> dict:
    """
    Feature #6: Calculates voice biometrics to detect robocalls and synthetic Text-to-Speech (TTS).
    
    1. Silence Ratio: Automated robocallers typically exhibit unusually high initial silence ratios.
    2. Spectral Flatness: Synthetic TTS voices exhibit lower spectral flatness compared to human vocal tracts.
    
    :param wav_path: Path to the converted 16kHz WAV file.
    :return: Dictionary containing silence_ratio, spectral_flatness, and duration_seconds.
    """
    try:
        audio, sr = sf.read(wav_path)
        if len(audio.shape) > 1:
            audio = audio.mean(axis=1) # Downmix stereo to mono
            
        # Normalize audio amplitude
        audio = audio / (np.max(np.abs(audio)) + 1e-10)

        # 20ms frame energy calculation for silence detection
        frame_length = int(sr * 0.02)
        energy = np.array([
            np.sum(audio[i:i+frame_length]**2)
            for i in range(0, len(audio) - frame_length, frame_length)
        ])
        silence_threshold = 0.01 * np.max(energy)
        silence_ratio = np.sum(energy < silence_threshold) / len(energy) if len(energy) > 0 else 0.0

        # FFT Spectral Flatness calculation (geometric mean / arithmetic mean of power spectrum)
        spectrum = np.abs(np.fft.rfft(audio))
        spectral_flatness = np.exp(np.mean(np.log(spectrum + 1e-10))) / (np.mean(spectrum) + 1e-10)

        return {
            "silence_ratio": float(round(silence_ratio, 4)),
            "spectral_flatness": float(round(spectral_flatness, 4)),
            "duration_seconds": float(round(len(audio) / sr, 2)),
        }
    except Exception as e:
        logger.error(f"Biometrics calculation error: {e}")
        return {"silence_ratio": 0.0, "spectral_flatness": 0.0, "duration_seconds": 0.0}


def parse_dtmf_metadata(json_path: str) -> list:
    """
    Feature #5: Extracts DTMF keypress events from RTPEngine's companion JSON metadata file.
    """
    try:
        with open(json_path) as f:
            metadata = json.load(f)
        return metadata.get("dtmf_events", [])
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        return []


def process_wav(wav_path: str, pcap_path: str):
    """
    Runs Vosk ASR offline transcription, extracts biometrics and DTMF events,
    and posts the JSON result to the Spring Boot Gateway.
    """
    logger.info(f"Starting Vosk transcription for {wav_path}")
    try:
        wf = sf.SoundFile(wav_path, mode="r")
        rec = KaldiRecognizer(model, wf.samplerate)
        rec.SetWords(True)
        text_parts = []

        # Read audio frames in 4000-sample chunks
        while True:
            data = wf.read(4000, dtype="int16")
            if len(data) == 0:
                break
            if rec.AcceptWaveform(data.tobytes()):
                result = json.loads(rec.Result())
                text_parts.append(result.get("text", ""))

        final_result = json.loads(rec.FinalResult())
        text_parts.append(final_result.get("text", ""))
        transcript = " ".join(filter(None, text_parts))

        # Extract biometrics & DTMF events
        biometrics = extract_voice_biometrics(wav_path)
        json_path = wav_path.replace(".wav", ".json")
        dtmf_events = parse_dtmf_metadata(json_path)

        payload = {
            "callId": os.path.basename(wav_path).replace(".wav", ""),
            "audioFile": os.path.basename(wav_path),
            "transcript": transcript,
            "biometrics": {
                "silenceRatio": biometrics["silence_ratio"],
                "spectralFlatness": biometrics["spectral_flatness"],
                "durationSeconds": biometrics["duration_seconds"],
            },
            "dtmfEvents": [
                {"digit": e.get("digit", 0), "timestamp": e.get("timestamp", 0)}
                for e in dtmf_events
            ],
        }

        # Post transcription payload to Spring Boot Interception Gateway
        with httpx.Client(timeout=5.0) as client:
            resp = client.post(API_URL, json=payload)
            resp.raise_for_status()

        logger.info(f"Transcribed Call [{payload['callId']}]: '{transcript[:60]}...'")

        # Clean up processed spool files
        os.remove(pcap_path)
        os.remove(wav_path)
        if os.path.exists(json_path):
            os.remove(json_path)
    except Exception as e:
        logger.error(f"Processing error on {wav_path}: {e}")


if __name__ == "__main__":
    logger.info("Starting Vosk Speech-to-Text Pipeline Worker Daemon...")
    model_path = os.environ.get("VOSK_MODEL_PATH", MODEL_PATH)

    if not os.path.exists(model_path):
        logger.error(f"Vosk ASR model not found at {model_path}")
        sys.exit(1)

    logger.info(f"Loading Vosk ASR model from {model_path}...")
    model = Model(model_path)
    logger.info("Vosk model loaded successfully. Watching /var/spool/rtpengine for PCAP audio captures...")

    while True:
        # Scan spool directory for finalized .pcap files (modified > 3 seconds ago)
        for pcap_path in list(Path(SPOOL_DIR).glob("*.pcap")):
            if time.time() - os.path.getmtime(pcap_path) > 3:
                pcap = str(pcap_path)
                wav = pcap_to_wav(pcap)
                if wav:
                    process_wav(wav, pcap)
        time.sleep(POLL_INTERVAL)
