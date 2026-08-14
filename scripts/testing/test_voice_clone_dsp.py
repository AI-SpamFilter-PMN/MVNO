#!/usr/bin/env python3
"""
AI Voice Clone & Synthetic Audio DSP Spectral Detector Verification Test
Validates:
1. Pure sine / Synthetic mechanical TTS pitch track -> SYNTHETIC_AI_VOICE_CLONE (Jitter < 0.85%)
2. Natural biological human speech with pitch perturbation -> NATURAL_BIOLOGICAL_SPEECH (Jitter > 2.0%)
"""
import sys
import math
import struct
import base64
import json
import urllib.request

DSP_URL = "http://localhost:8080/api/v1/intercept/dsp/voice-clone"
API_KEY = "mvno-demo-key-2026"

def generate_pcm_audio(is_synthetic=False, sample_rate=8000, duration_sec=1.5):
    """
    Generates synthetic (flat pitch) or natural (jitter-perturbed) 16-bit PCM mono audio.
    """
    samples = []
    num_samples = int(sample_rate * duration_sec)
    
    # Base pitch: 150 Hz
    base_f0 = 150.0
    phase = 0.0
    
    for i in range(num_samples):
        t = i / sample_rate
        
        if is_synthetic:
            # Synthetic: Perfectly flat frequency (0% jitter)
            current_f0 = base_f0
        else:
            # Natural: Biological micro-tremor jitter (4.5% RAP perturbation)
            jitter_factor = 1.0 + 0.045 * math.sin(2 * math.pi * 7.5 * t) + 0.02 * math.sin(2 * math.pi * 18.0 * t)
            current_f0 = base_f0 * jitter_factor
            
        phase += 2.0 * math.pi * current_f0 / sample_rate
        # Harmonics
        sample_val = 0.6 * math.sin(phase) + 0.3 * math.sin(2 * phase) + 0.1 * math.sin(3 * phase)
        # Apply amplitude envelope (fade in/out)
        env = min(1.0, min(t * 10, (duration_sec - t) * 10))
        int_val = int(sample_val * env * 25000.0)
        samples.append(max(-32768, min(32767, int_val)))
        
    pcm_bytes = struct.pack(f"<{len(samples)}h", *samples)
    return base64.b64encode(pcm_bytes).decode("ascii")

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
    print(" 🧠 TEST 2: AI VOICE CLONE & SYNTHETIC AUDIO DSP DETECTOR VALIDATION")
    print("==========================================================================")
    
    # 1. Test Synthetic / AI Voice Clone Audio
    print("\n[*] Generating Synthetic / Robotic TTS Audio (Flat Pitch Track)...")
    synthetic_b64 = generate_pcm_audio(is_synthetic=True)
    res_synth = query_dsp_service(synthetic_b64)
    print(f"[*] Synthetic Audio Result: {json.dumps(res_synth, indent=2)}")
    
    if not res_synth.get("syntheticSuspect", False):
        print("[FAIL] Expected syntheticSuspect=True for flat mechanical TTS audio!")
        sys.exit(1)
        
    # 2. Test Natural Human Speech Audio
    print("\n[*] Generating Natural Human Speech Audio (Biological Pitch Micro-Jitter)...")
    natural_b64 = generate_pcm_audio(is_synthetic=False)
    res_nat = query_dsp_service(natural_b64)
    print(f"[*] Natural Audio Result: {json.dumps(res_nat, indent=2)}")
    
    if res_nat.get("syntheticSuspect", True):
        print("[FAIL] Expected syntheticSuspect=False for natural human speech!")
        sys.exit(1)
        
    print("\n🎉 ALL AI VOICE CLONE & DSP DETECTOR TESTS PASSED (2/2)!")
    sys.exit(0)

if __name__ == "__main__":
    main()
