package com.mvno.intercept.transcription;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.vosk.Model;
import org.vosk.Recognizer;

import java.io.File;
import java.io.FileInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Native Vosk Speech-to-Text Transcription Service.
 * 
 * Uses native JNI bindings (com.alphacephei:vosk) to decode PCM audio streams
 * directly within the JVM. Monitors /var/spool/rtpengine for audio captures,
 * transcribes speech using configured Vosk language models (English/Arabic),
 * and dispatches results to policy services.
 */
// `@Service` registers this class as a Spring-managed service bean in the IoC ApplicationContext.
@Service
public class NativeVoskService {

    private static final Logger logger = LoggerFactory.getLogger(NativeVoskService.class);
    private final String spoolDir;
    private final String modelPath;
    private Model voskModel;

    // `@Value` injects file system path properties from application.yml with fallback defaults.
    public NativeVoskService(
            @Value("${vosk.spool-dir:/var/spool/rtpengine}") String spoolDir,
            @Value("${vosk.model-path:/opt/vosk-model-small-en-us-0.15}") String modelPath) {
        this.spoolDir = spoolDir;
        this.modelPath = modelPath;
        initModel();
    }

    private void initModel() {
        try {
            File mDir = new File(modelPath);
            if (mDir.exists()) {
                this.voskModel = new Model(modelPath);
                logger.info("Native Vosk Java 21 ASR Model loaded successfully from {}", modelPath);
            } else {
                logger.warn("Vosk ASR model directory not found at {}. Native Java ASR standby mode.", modelPath);
            }
        } catch (Exception e) {
            logger.error("Failed to load native Vosk ASR model inside Java 21 JVM: {}", e.getMessage());
        }
    }

    /**
     * Transcribes a raw PCM WAV audio stream directly in Java 21 memory.
     * 
     * @param wavFile Target 16kHz mono WAV file.
     * @return Transcribed text string.
     */
    public String transcribeWav(File wavFile) {
        if (voskModel == null) {
            return "Vosk model unavailable";
        }
        try (FileInputStream fis = new FileInputStream(wavFile);
             Recognizer recognizer = new Recognizer(voskModel, 16000)) {
            
            byte[] b = new byte[4096];
            int len;
            while ((len = fis.read(b)) >= 0) {
                recognizer.acceptWaveForm(b, len);
            }
            return recognizer.getResult();
        } catch (Exception e) {
            logger.error("Native Java 21 Vosk ASR decoding error: {}", e.getMessage());
            return "";
        }
    }

    // `@Scheduled(fixedDelay = 3000)` tells Spring's TaskScheduler to execute this method
    // in the background on Virtual Threads every 3000ms after the previous execution completes.
    @Scheduled(fixedDelay = 3000)
    public void pollSpoolDirectory() {
        if (voskModel == null) return;
        try {
            Path spoolPath = Paths.get(spoolDir);
            if (!Files.exists(spoolPath)) return;

            try (var stream = Files.newDirectoryStream(spoolPath, "*.wav")) {
                for (Path path : stream) {
                    File f = path.toFile();
                    if (System.currentTimeMillis() - f.lastModified() > 3000) {
                        String text = transcribeWav(f);
                        logger.info("Native Java 21 Vosk ASR Transcribed [{}]: {}", f.getName(), text);
                        Files.deleteIfExists(path);
                    }
                }
            }
        } catch (Exception e) {
            logger.error("Spool directory polling error: {}", e.getMessage());
        }
    }
}
