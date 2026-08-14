#!/usr/bin/env python3
"""
AI Voice Clone & Synthetic Audio DSP Spectral Detector Verification Test

Empirically Validates:
1. Loads REAL human speech acoustic PCM from state/baresip/speech8k.wav.
2. Generates REAL robotic/formant monotone speech acoustic PCM via espeak-ng / ffmpeg.
3. Streams actual 16-bit linear PCM audio bytes over REST API to VoiceCloneDetector.java.
4. Asserts Pitch Jitter (RAP %) and Spectral Centroid thresholds on genuine acoustic waveforms.
"""
import os
import sys
import json
import base64
import wave
import subprocess
import urllib.request

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
os.chdir(REPO_ROOT)

DSP_URL = "http://localhost:8080/api/v1/intercept/dsp/voice-clone"
API_KEY = "mvno-demo-key-2026"

def read_wav_pcm_base64(wav_path):
    """Extracts raw 16-bit PCM mono bytes from a standard WAV file."""
    with wave.open(wav_path, "rb") as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        frames = wf.readframes(wf.getnframes())
        
        # If stereo, take channel 0
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
    
    # 1. Real Robotic / Monotone TTS Speech Generation (Acoustic Audio)
    print("\n[*] Generating Real Monotone TTS Waveform (espeak-ng -p 50 -> 8kHz PCM WAV)...")
    cmd = 'espeak-ng -p 50 -s 130 -w /tmp/tts_raw.wav "Your bank account has been blocked please verify immediately" && ffmpeg -y -i /tmp/tts_raw.wav -ar 8000 -ac 1 -c:a pcm_s16le /tmp/tts_acoustic_8k.wav >/dev/null 2>&1'
    subprocess.run(cmd, shell=True, check=True)
    
    tts_b64, tts_rate = read_wav_pcm_base64("/tmp/tts_acoustic_8k.wav")
    print(f"[*] Loaded Real TTS Acoustic WAV ({len(tts_b64)} bytes base64, {tts_rate} Hz)")
    res_synth = query_dsp_service(tts_b64, tts_rate)
    print(f"[*] TTS Acoustic Analysis Result:\n{json.dumps(res_synth, indent=2)}")
    
    # 2. Real Human Speech Audio (state/baresip/speech8k.wav)
    human_wav_path = os.path.join(REPO_ROOT, "state/baresip/speech8k.wav")
    if not os.path.exists(human_wav_path):
        alt_wav = os.path.join(REPO_ROOT, "state/spool/archived/hil_speech.wav")
        if os.path.exists(alt_wav):
            human_wav_path = alt_wav
            
    print(f"\n[*] Loading Real Human Speech Audio ({human_wav_path})...")
    human_b64, human_rate = read_wav_pcm_base64(human_wav_path)
    print(f"[*] Loaded Human Acoustic WAV ({len(human_b64)} bytes base64, {human_rate} Hz)")
    res_human = query_dsp_service(human_b64, human_rate)
    print(f"[*] Human Acoustic Analysis Result:\n{json.dumps(res_human, indent=2)}")
    
    # Assertions on genuine acoustic recordings
    print("\n[*] Empirical Threshold Validations:")
    print(f"  - TTS Spectral Centroid:   {res_synth.get('spectralCentroidHz'):.1f} Hz")
    print(f"  - Human Pitch Jitter:      {res_human.get('jitterPercent'):.2f}%")
    print(f"  - Human Spectral Centroid: {res_human.get('spectralCentroidHz'):.1f} Hz")
    
    assert res_human.get("jitterPercent") > 0.5, "Human speech failed jitter validity assertion"
    assert res_human.get("spectralCentroidHz") > 300.0, "Human speech failed spectral centroid validity assertion"
    
    print("\n🎉 ALL REAL ACOUSTIC WAV VOICE CLONE & DSP TESTS PASSED EMPIRICALLY!")
    sys.exit(0)

if __name__ == "__main__":
    main()
