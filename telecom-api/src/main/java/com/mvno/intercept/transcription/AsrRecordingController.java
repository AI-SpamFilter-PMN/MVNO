package com.mvno.intercept.transcription;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Map;

/**
 * On-Demand ASR & Recording Endpoints
 *
 * Exposes two REST endpoints for the SipClient integration:
 * - POST /api/v1/asr: upload a WAV file and receive a Vosk ASR transcript
 * - GET  /api/v1/recordings/{filename}: download a recording from the spool directory
 *
 * @author MVNO Core Engineering Team
 */
@RestController
@RequestMapping("/api/v1")
public class AsrRecordingController {

    private static final Logger logger = LoggerFactory.getLogger(AsrRecordingController.class);

    private final NativeVoskService voskService;
    private final String spoolDir;

    public AsrRecordingController(final NativeVoskService voskService,
                                  @Value("${vosk.spool-dir:/var/spool/rtpengine}") final String spoolDir) {
        this.voskService = voskService;
        this.spoolDir = spoolDir;
    }

    /**
     * On-demand ASR: accepts a WAV file upload and returns the Vosk transcript.
     * The file is saved to the spool directory, transcribed, then archived.
     */
    @PostMapping(value = "/asr", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<Map<String, String>> transcribe(@RequestParam("file") final MultipartFile file) {
        if (file == null || file.isEmpty()) {
            return ResponseEntity.badRequest().body(Map.of("error", "No audio file provided"));
        }

        try {
            final Path spoolPath = Paths.get(spoolDir);
            if (!Files.exists(spoolPath)) {
                Files.createDirectories(spoolPath);
            }

            final String filename = file.getOriginalFilename() != null ? file.getOriginalFilename() : "upload.wav";
            final Path dest = spoolPath.resolve(filename);
            file.transferTo(dest.toFile());

            final String transcript = voskService.transcribeWav(dest.toFile());

            // Archive the uploaded file after transcription
            final Path archiveDir = spoolPath.resolve("archived");
            if (!Files.exists(archiveDir)) {
                Files.createDirectories(archiveDir);
            }
            Files.move(dest, archiveDir.resolve(filename),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING);

            logger.info("On-demand ASR transcript for [{}]: {}", filename,
                    transcript.length() > 80 ? transcript.substring(0, 80) + "..." : transcript);

            return ResponseEntity.ok(Map.of(
                    "filename", filename,
                    "transcript", transcript
            ));
        } catch (final Exception e) {
            logger.error("On-demand ASR transcription error: {}", e.getMessage());
            return ResponseEntity.internalServerError().body(Map.of("error", e.getMessage()));
        }
    }

    /**
     * Serves a recording file from the spool or archived directory.
     */
    @GetMapping("/recordings/{filename}")
    public ResponseEntity<Resource> getRecording(@PathVariable final String filename) {
        // Search archived dir first, then spool dir
        final Path archivedDir = Paths.get(spoolDir).resolve("archived");
        File recording = archivedDir.resolve(filename).toFile();
        if (!recording.exists()) {
            recording = Paths.get(spoolDir).resolve(filename).toFile();
        }

        if (!recording.exists()) {
            return ResponseEntity.notFound().build();
        }

        final Resource resource = new FileSystemResource(recording);
        return ResponseEntity.ok()
                .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"" + filename + "\"")
                .contentType(MediaType.APPLICATION_OCTET_STREAM)
                .body(resource);
    }
}
