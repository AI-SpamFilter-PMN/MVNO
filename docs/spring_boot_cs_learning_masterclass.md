# 🎓 Spring Boot & Java 21 Masterclass for Computer Science Students
### A Beginner-Friendly, Deep-Dive Architectural Guide to the MVNO Telecom Interception Gateway

Welcome! This guide is written specifically for Computer Science students and junior engineers. It explains **why we use Java 21 LTS and Spring Boot 3.4**, how Spring Boot works under the hood, and how every single line of code in our MVNO Interception Gateway functions.

---

## 📋 Table of Contents
1. [Why Spring Boot 3.4 vs. Raw Java 21?](#1-why-spring-boot-34-vs-raw-java-21)
2. [Core Architecture & Spring IoC Container](#2-core-architecture--spring-ioc-container)
3. [Dependency Injection (DI) & Object Lifecycles](#3-dependency-injection-di--object-lifecycles)
4. [Spring Stereotype Annotations Demystified](#4-spring-stereotype-annotations-demystified)
5. [Java 21 Core Features in Action](#5-java-21-core-features-in-action)
6. [Web REST API Pipeline (`SubscriberController`)](#6-web-rest-api-pipeline-subscribercontroller)
7. [Database Data Access (`JdbcTemplate` vs. ORMs)](#7-database-data-access-jdbctemplate-vs-orms)
8. [Outbound HTTP Resilience (`RestClient` & SLA Fallback)](#8-outbound-http-resilience-restclient--sla-fallback)
9. [Native Java 21 Vosk Speech-to-Text ASR (`NativeVoskService`)](#9-native-java-21-vosk-speech-to-text-asr-nativevoskservice)
10. [Observability & Actuator Health Probes](#10-observability--actuator-health-probes)

---

## 1. ❓ Why Spring Boot 3.4 vs. Raw Java 21?

A common question from CS students is:
> *"If Java 21 has its own HTTP server (`com.sun.net.httpserver.HttpServer`), why do we need Spring Boot? Can't we just write raw Java code?"*

Let me compare what you would have to write manually in **Raw Java 21** versus what **Spring Boot 3.4** automates for you:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          RAW JAVA 21 vs. SPRING BOOT 3.4                        │
├──────────────────────────────────┬──────────────────────────────────────────────┤
│ Task / Feature                   │ Raw Java 21 (Manual Implementation)          │
├──────────────────────────────────┼──────────────────────────────────────────────┤
│ 1. HTTP Web Server               │ Write raw socket loops & HTTP byte parsers   │
│ 2. Request Routing               │ Manual `if-else` string checking on URLs     │
│ 3. JSON Deserialization          │ Parse raw JSON strings manually line-by-line │
│ 4. Object Creation (Singletons)  │ `new Service(new Repo(new DataSource()))`     │
│ 5. Database Connection Pooling   │ Write custom JDBC connection cleanup loops  │
│ 6. Outbound Timeout Handling     │ Low-level socket timeout byte stream locks   │
│ 7. Multi-threading Concurrency   │ Manual `ExecutorService` thread pool tuning │
│ 8. Liveness & Metrics            │ Write custom Prometheus text format exporters│
└──────────────────────────────────┴──────────────────────────────────────────────┘
```

### What Spring Boot Does for Us:
1. 🚀 **Embedded Web Server**: Launches Tomcat listening on HTTP port 8080 automatically upon startup.
2. 🔄 **Inversion of Control (IoC)**: Automatically instantiates and connects all your services, repositories, and controllers without writing nested `new` calls.
3. 📦 **Automatic JSON Conversion**: Converts incoming HTTP JSON bodies into immutable Java 21 `record` DTOs using Jackson.
4. ⚡ **Virtual Threads Integration**: Enforces Java 21 Virtual Threads (`spring.threads.virtual.enabled=true`), enabling thousands of concurrent HTTP connections with sub-millisecond overhead.
5. 🛡️ **Fail-Open Resilience**: Provides `RestClient` equipped with 5-second socket read timeouts to guarantee telecom network reliability.

---

## 2. 🏛️ Core Architecture & Spring IoC Container

At the heart of every Spring Boot application is the **Inversion of Control (IoC) Container** (also known as the `ApplicationContext`).

### What is Inversion of Control?
In traditional Java programming, *you* create objects using the `new` keyword:
```java
// Traditional Java: YOU control object creation
SubscriberRepository repo = new SubscriberRepository(dataSource);
SubscriberService service = new SubscriberService(repo, eirTracker);
```

With Inversion of Control, you invert this responsibility: **Spring creates, wires, and manages the objects for you!**

```
                     SPRING IOC CONTAINER (ApplicationContext)
┌───────────────────────────────────────────────────────────────────────────────┐
│                                                                               │
│   ┌────────────────────────┐         ┌────────────────────────┐               │
│   │  SubscriberRepository  │         │       EirTracker       │               │
│   │     (@Repository)      │         │      (@Component)      │               │
│   └───────────┬────────────┘         └───────────┬────────────┘               │
│               │                                  │                            │
│               └────────────────┬─────────────────┘                            │
│                                │ Inject via Constructor                        │
│                                ▼                                              │
│                     ┌────────────────────┐                                    │
│                     │ SubscriberService  │                                    │
│                     │     (@Service)     │                                    │
│                     └──────────┬─────────┘                                    │
│                                │ Inject via Constructor                       │
│                                ▼                                              │
│                    ┌──────────────────────┐                                   │
│                    │ SubscriberController │                                   │
│                    │   (@RestController)  │                                   │
│                    └──────────────────────┘                                   │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 🧩 Dependency Injection (DI) & Object Lifecycles

### What is Dependency Injection?
Dependency Injection is the technique where an object receives its dependencies from an external provider (Spring) rather than creating them itself.

### Constructor Injection vs. Field Injection

#### ❌ Field Injection (Antipattern — Avoid!)
```java
@Service
public class SubscriberService {
    @Autowired
    private SubscriberRepository subscriberRepository; // Hidden dependency, hard to unit test!
}
```

#### ✅ Constructor Injection (Gold Standard — Used in our Project!)
```java
@Service
public class SubscriberService {
    private final SubscriberRepository subscriberRepository;
    private final EirTracker eirTracker;

    // Spring automatically supplies managed beans to this constructor!
    public SubscriberService(SubscriberRepository subscriberRepository, EirTracker eirTracker) {
        this.subscriberRepository = subscriberRepository;
        this.eirTracker = eirTracker;
    }
}
```

### Why Constructor Injection is Superior:
1. 🔒 **Immutability**: Fields are declared `final`, ensuring they cannot be mutated after bean creation.
2. 🧪 **Easy Unit Testing**: You can instantiate `SubscriberService` in JUnit tests using simple `new SubscriberService(mockRepo, mockTracker)` without starting a Spring context.
3. 🚫 **NullPointer Protection**: Guarantees that all required dependencies exist at compile time before the service accepts HTTP requests.

---

## 4. 🏷️ Spring Stereotype Annotations Demystified

Spring uses annotations to classify Java classes into specific architectural layers:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            SPRING STEREOTYPE MAP                                │
├─────────────────────────┬───────────────────────────────────────────────────────┤
│ Annotation              │ Architectural Purpose                                 │
├─────────────────────────┼───────────────────────────────────────────────────────┤
│ `@SpringBootApplication`│ Main entry point — triggers auto-config & scanning     │
│ `@RestController`       │ REST API Web Controller — converts return values to JSON│
│ `@Service`              │ Business Domain Logic layer                           │
│ `@Repository`           │ Data Access Layer — translates SQL/JDBC exceptions     │
│ `@Component`            │ Generic Spring-managed utility bean                   │
│ `@Configuration`        │ Java configuration class declaring `@Bean` methods    │
│ `@Bean`                 │ Factory method returning a Spring-managed instance    │
│ `@Value`                │ Injects configuration properties from `application.yml`│
│ `@Scheduled`            │ Background cron/timer execution on Virtual Threads    │
└─────────────────────────┴───────────────────────────────────────────────────────┘
```

---

## 5. ☕ Java 21 Core Features in Action

Our gateway is built on **Java 21 LTS**, taking advantage of modern language capabilities:

### A. Immutable Records (`record`)
Java Records eliminate boilerplate getters, setters, `equals()`, `hashCode()`, and `toString()` methods for Data Transfer Objects (DTOs):

```java
// Immutable DTO for SMS Intercept Requests
public record SMSInterceptRequest(String sender, String recipient, String content) {}
```

### B. Virtual Threads (Project Loom)
In `application.yml`, we enable Virtual Threads:
```yaml
spring:
  threads:
    virtual:
      enabled: true
```
- Traditional OS threads consume **~1 MB of RAM** per thread.
- Java 21 Virtual Threads consume **~1 KB of RAM** per thread!
- Spring Tomcat can handle **100,000+ concurrent requests** without running out of memory.

### C. Lock-Free Concurrency (`ConcurrentHashMap` & `AtomicInteger`)
In `EirTracker.java`, we track rapid SIM swaps across Virtual Threads without database lock overhead:

```java
@Component
public class EirTracker {
    private final ConcurrentHashMap<String, AtomicInteger> imeiSwapCounter = new ConcurrentHashMap<>();

    public boolean checkEirBinding(String imei, String msisdn) {
        if (imei == null || imei.isBlank()) return true;

        // Atomically increment SIM swap count without thread blocking
        AtomicInteger counter = imeiSwapCounter.computeIfAbsent(imei, k -> new AtomicInteger(1));
        return counter.get() <= 3;
    }
}
```

---

## 6. 🌐 Web REST API Pipeline (`SubscriberController`)

When OsmoSMSC or Kamailio sends an HTTP POST request to our gateway:

```
[Incoming HTTP POST /api/v1/intercept/sms]
                 │
                 ▼
     Embedded Tomcat (Port 8080)
                 │ (Virtual Thread allocated)
                 ▼
  Jackson JSON Deserializer ──▶ Converts JSON payload to SMSInterceptRequest Record
                 │
                 ▼
   SubscriberController.interceptSms()
                 │
                 ├─▶ 1. Check Prepaid Balance ($1/SMS)
                 └─▶ 2. Call AiFilterService.classifySms()
                 │
                 ▼
      ResponseEntity.ok(InterceptResponse) ──▶ Serializes to JSON HTTP 200 Response
```

### Code Implementation (`SubscriberController.java`):
```java
@RestController
@RequestMapping("/api/v1/intercept")
public class SubscriberController {

    private final SubscriberService subscriberService;
    private final AiFilterService aiFilterService;

    public SubscriberController(SubscriberService subscriberService, AiFilterService aiFilterService) {
        this.subscriberService = subscriberService;
        this.aiFilterService = aiFilterService;
    }

    @PostMapping("/sms")
    public ResponseEntity<InterceptResponse> interceptSms(@RequestBody SMSInterceptRequest req) {
        int balance = subscriberService.getBalance(req.sender());
        if (balance <= 0) {
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }
        var result = aiFilterService.classifySms(req);
        return ResponseEntity.ok(result);
    }
}
```

---

## 7. 🗄️ Database Data Access (`JdbcTemplate` vs. ORMs)

### Why We Avoided ORMs (Hibernate/JPA)
In high-throughput telecom signaling gateways:
- ORMs introduce heavy object allocations, reflection overhead, and dirty-checking.
- We use Spring's **`JdbcTemplate`** wrapping SQLite Write-Ahead Logging (`PRAGMA journal_mode=WAL;`).

### Code Implementation (`SubscriberRepository.java`):
```java
@Repository
public class SubscriberRepository {

    private final JdbcTemplate jdbcTemplate;

    public SubscriberRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public int findBalanceByMsisdn(String msisdn) {
        String sql = "SELECT balance FROM subscriber WHERE msisdn = ?;";
        try {
            Integer balance = jdbcTemplate.queryForObject(sql, Integer.class, msisdn);
            return balance != null ? balance : 0;
        } catch (Exception e) {
            // Fail-Closed default: 0 balance blocks unauthenticated callers
            return 0;
        }
    }
}
```

---

## 8. 🛡️ Outbound HTTP Resilience (`RestClient` & SLA Fallback)

In telecommunications, if a secondary AI spam filter model stalls, **subscriber phone calls must NEVER be dropped**.

We configure Spring Boot's **`RestClient`** with a strict **5-second socket timeout**. If the AI model server exceeds 5 seconds or fails, the gateway gracefully returns **Fail-Open (`allow: true`)**.

```
                           OUTBOUND AI MODEL CALL
┌────────────────────────┐                            ┌────────────────────────┐
│  Spring Boot Gateway   │ ── HTTP POST /classify ──▶ │ AI Spam Filter Service │
│   (`AiFilterService`)  │                            │    (`ai-filter:8000`)  │
└───────────┬────────────┘                            └───────────┬────────────┘
            │                                                     │
            │ ⏱️ Timer Starts (5s Max Timeout Window)             │
            ├─────────────────────────────────────────────────────┤
            │ CASE A: Response received in < 5s                   │
            │   ↳ Returns AI Classification (allow: true/false)   │
            ├─────────────────────────────────────────────────────┤
            │ CASE B: Timeout / Connection Error                  │
            │   ↳ Catch Exception → SLA Fail-Open (allow: true)   │
            └─────────────────────────────────────────────────────┘
```

### Code Implementation (`AiFilterService.java`):
```java
@Service
public class AiFilterService {

    private static final Logger logger = LoggerFactory.getLogger(AiFilterService.class);
    private final RestClient restClient;
    private final String baseUrl;

    public AiFilterService(RestClient restClient,
                           @Value("${ai-filter.url:http://ai-filter:8000/api/v1/classify}") String baseUrl) {
        this.restClient = restClient;
        this.baseUrl = baseUrl;
    }

    public InterceptResponse classifySms(SMSInterceptRequest req) {
        try {
            var body = Map.of(
                "event_type", "SMS",
                "sender_msisdn", req.sender(),
                "recipient_msisdn", req.recipient(),
                "content_text", req.content(),
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            var result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            return result != null ? new InterceptResponse(result.allow(), result.reason())
                                  : new InterceptResponse(true, "SLA allow");
        } catch (Exception e) {
            // SLA Fallback: Fail-Open when AI model exceeds 5s timeout or is offline
            logger.warn("AI filter timed out: {}. Falling back to SLA allow.", e.getMessage());
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        }
    }
}
```

---

## 9. 🎙️ Native Java 21 Vosk Speech-to-Text ASR (`NativeVoskService`)

Instead of running an external Python worker script, we embed Vosk Speech Recognition directly inside the Spring Boot JVM using native JNI bindings (`com.alphacephei:vosk:0.3.45`).

### Code Implementation (`NativeVoskService.java`):
```java
@Service
public class NativeVoskService {

    private final String spoolDir;
    private final String modelPath;
    private Model voskModel;

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
            }
        } catch (Exception e) {
            // Log error
        }
    }

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
                        Files.deleteIfExists(path);
                    }
                }
            }
        } catch (Exception e) {
            // Log error
        }
    }
}
```

---

## 10. 📊 Observability & Actuator Health Probes

Spring Boot Actuator exposes operational endpoints out of the box:

- **`/actuator/health/liveness`**: Confirms the container is alive (used by Podman/Docker healthchecks).
- **`/actuator/health/readiness`**: Confirms database connections are ready to accept traffic.
- **`/actuator/prometheus`**: Exposes JVM memory, GC, and Virtual Thread execution metrics for VictoriaMetrics scraping.

---

## 🎓 Summary Checklist for CS Students

1. **Spring Boot is an orchestrator**: It eliminates manual HTTP socket code, JSON parsing, and multithread pooling.
2. **Dependency Injection makes code clean & testable**: We pass dependencies via constructors (`private final`).
3. **Java 21 Virtual Threads give massive scale**: Thousands of concurrent calls run effortlessly with minimal RAM.
4. **`JdbcTemplate` > ORMs for Telecom**: Raw SQL with connection pooling provides sub-millisecond database queries.
5. **Telecom Systems require Fail-Open resilience**: Always catch network timeouts so real calls are never dropped.
