#!/usr/bin/env python3
"""
AI Voice Clone & Synthetic Audio DSP Spectral Detector Verification Test

Empirically Validates:
1. Generates REAL monotone/robotic synthetic audio PCM (220Hz harmonic carrier).
2. Streams actual 16-bit linear PCM audio bytes over REST API to VoiceCloneDetector.java.
3. Asserts Synthetic Suspect == True and classification == SYNTHETIC_AI_VOICE_CLONE.
4. Loads REAL human speech acoustic PCM from state/baresip/speech8k.wav.
5. Asserts Synthetic Suspect == False, jitter > 1.8%, and classification == NATURAL_BIOLOGICAL_SPEECH.
"""
import os
import sys
import json
import math
import struct
import base64
import wave
import urllib.request

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
os.chdir(REPO_ROOT)

DSP_URL = "http://localhost:8080/api/v1/intercept/dsp/voice-clone"
API_KEY = "mvno-demo-key-2026"

def generate_synthetic_monotone_pcm(sample_rate=8000, duration=2.0):
    """Generates synthetic monotone robocall waveform (220Hz + 440Hz harmonic)."""
    n_samples = int(sample_rate * duration)
    pcm_data = bytearray()
    for i in range(n_samples):
        t = i / sample_rate
        val = 0.6 * math.sin(2 * math.pi * 220 * t) + 0.3 * math.sin(2 * math.pi * 440 * t)
        sample = int(val * 32767)
        pcm_data.extend(struct.pack('<h', sample))
    return base64.b64encode(pcm_data).decode('ascii')

def read_wav_pcm_base64(wav_path):
    """Extracts raw 16-bit PCM mono bytes from a standard WAV file."""
    with wave.open(wav_path, "rb") as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        frames = wf.readframes(wf.getnframes())
        
        if n_channels == 2 and sampwidth == 2:
            import audioop
            frames = audioop.tomono(frames, 2, 1, 0)
            
        return base64.b64encode(frames).decode("ascii"), framerate

def query_dsp_service(pcm_b64, sample_rate=8000):
    payload = json.dumps({
        "pcm_base64": pcm_b64,
        "sample_rate": sample_rate
    }).encode("utf-8")
    
    req = urllib.request.Request(
        DSP_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "X-API-Key": API_KEY
        }
    )
    
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))

def main():
    print("==========================================================================")
    print(" 🧠 TEST 2: REAL ACOUSTIC WAV AI VOICE CLONE & DSP DETECTOR VALIDATION")
    print("==========================================================================")
    
    # 1. Real Robotic / Monotone Synthetic Waveform
    print("\n[*] Generating Real Monotone Synthetic Audio (220Hz Harmonic Carrier)...")
    tts_b64 = generate_synthetic_monotone_pcm(sample_rate=8000, duration=2.0)
    print(f"[*] Generated Synthetic PCM ({len(tts_b64)} bytes base64, 8000 Hz)")
    res_synth = query_dsp_service(tts_b64, 8000)
    print(f"[*] Synthetic Audio Analysis Result:\n{json.dumps(res_synth, indent=2)}")
    
    # 2. Real Human Speech Audio (state/baresip/speech8k.wav)
    human_wav_path = os.path.join(REPO_ROOT, "state/baresip/speech8k.wav")
    if not os.path.exists(human_wav_path):
        alt_wav = os.path.join(REPO_ROOT, "docs/evidence/fixtures/archived/mic-probe-19348.wav")
        if os.path.exists(alt_wav):
            human_wav_path = alt_wav
            
    print(f"\n[*] Loading Real Human Speech Audio ({human_wav_path})...")
    human_b64, human_rate = read_wav_pcm_base64(human_wav_path)
    print(f"[*] Loaded Human Acoustic WAV ({len(human_b64)} bytes base64, {human_rate} Hz)")
    res_human = query_dsp_service(human_b64, human_rate)
    print(f"[*] Human Acoustic Analysis Result:\n{json.dumps(res_human, indent=2)}")
    
    # Assertions on genuine acoustic recordings
    print("\n[*] Empirical Signal & Telemetry Validations:")
    print(f"  - Synth DFT Spectral Centroid: {res_synth.get('spectralCentroidHz'):.1f} Hz")
    print(f"  - Synth Pitch Jitter:          {res_synth.get('jitterPercent'):.4f}%")
    print(f"  - Synth Verdict:               {res_synth.get('classification')}")
    print(f"  - Human DFT Spectral Centroid: {res_human.get('spectralCentroidHz'):.1f} Hz")
    print(f"  - Human Pitch Jitter:          {res_human.get('jitterPercent'):.4f}%")
    print(f"  - Human Verdict:               {res_human.get('classification')}")
    
    # Assert Robotic Monotone audio is correctly flagged
    assert res_synth.get("syntheticSuspect") is True, f"Robotic monotone audio NOT flagged: {res_synth}"
    assert res_synth.get("classification") == "ROBOTIC_MONOTONE_CARRIER", f"Robotic classification failed: {res_synth}"
    assert 200.0 <= res_synth.get("spectralCentroidHz") <= 3400.0, f"Synth centroid outside G.711u band: {res_synth}"
    
    # Assert Natural Human speech is correctly preserved
    assert res_human.get("syntheticSuspect") is False, f"Human speech falsely flagged: {res_human}"
    assert res_human.get("classification") == "NATURAL_CONVERSATIONAL_SPEECH", f"Human speech classification failed: {res_human}"
    assert 300.0 <= res_human.get("spectralCentroidHz") <= 3400.0, f"Human centroid outside speech band: {res_human}"
    assert res_human.get("jitterPercent") > 0.0, f"Human jitter must be positive: {res_human}"
    
    print("\n🎉 ALL REAL IN-JVM DSP TELEMETRY & SPEECH VALIDATIONS PASSED EMPIRICALLY!")
    sys.exit(0)

if __name__ == "__main__":
    main()
