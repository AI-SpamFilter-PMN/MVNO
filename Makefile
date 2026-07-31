# ==============================================================================
# MVNO Telecom Interception Core — Automation Makefile
# ==============================================================================
# Provides developer build targets for rootless container lifecycle management,
# SQLite WAL database initialization, VTY control socket assertions, and REST API testing.
# ==============================================================================

.PHONY: up down logs ps init-db init-native-db up-native clean rebuild test test-sms test-call test-api test-vty

# Launches all rootless container services using scripts/up.sh
up:
	./scripts/up.sh

# Stops and removes all container services
down:
	./scripts/up.sh down

# Streams live container logs across all microservices
logs:
	./scripts/up.sh logs

# Displays running container status
ps:
	./scripts/up.sh ps

# Completely resets runtime container volumes and state directory
clean:
	./scripts/up.sh down -v
	rm -rf state/kamailio/* state/spool/* state/hlr/* state/vm-data/* state/grafana/*

# Rebuilds all custom images from source, initializes databases, and starts the stack
rebuild: clean init-db
	./scripts/up.sh --build

# Initializes SQLite WAL subscriber databases and creates seed subscriber test records
init-db:
	@mkdir -p state/mongodb state/spool state/hlr state/kamailio state/vm-data state/grafana state/logs/kamailio state/logs/osmocom
	@sqlite3 state/kamailio/kamailio.db \
		"CREATE TABLE IF NOT EXISTS version (id INTEGER PRIMARY KEY, table_name TEXT UNIQUE, table_version INTEGER);" \
		"INSERT OR IGNORE INTO version VALUES (1, 'version', 1);" \
		"CREATE TABLE IF NOT EXISTS subscriber ( \
			id INTEGER PRIMARY KEY AUTOINCREMENT, \
			username VARCHAR(64) NOT NULL DEFAULT '', \
			domain VARCHAR(64) NOT NULL DEFAULT '', \
			password VARCHAR(64) NOT NULL DEFAULT '', \
			ha1 VARCHAR(128) NOT NULL DEFAULT '', \
			ha1b VARCHAR(128) NOT NULL DEFAULT '', \
			msisdn TEXT UNIQUE, \
			balance INTEGER DEFAULT 100, \
			imei TEXT, imsi TEXT, blocked INTEGER DEFAULT 0 \
		);" \
		"INSERT OR IGNORE INTO subscriber (username, domain, password, ha1, ha1b, msisdn, balance) \
			VALUES ('15551234567', 'mvno.local', 'testpass', \
				'', '', '15551234567', 100);" \
		"INSERT OR IGNORE INTO subscriber (username, domain, password, ha1, ha1b, msisdn, balance) \
			VALUES ('15557654321', 'mvno.local', 'testpass', \
				'', '', '15557654321', 0);" \
		"PRAGMA journal_mode=WAL;" \
		"PRAGMA synchronous=NORMAL;"
	@cp -f state/kamailio/kamailio.db state/kamailio.db
	@if [ -f state/hlr/hlr.db ]; then \
		sqlite3 state/hlr/hlr.db "INSERT OR IGNORE INTO subscriber (id, imsi, msisdn) VALUES (1, '001010000000001', '15551234567');" 2>/dev/null || true; \
	fi
	@sqlite3 state/hlr/hlr.db \
		"PRAGMA journal_mode=WAL;" \
		"PRAGMA synchronous=NORMAL;"

# Alias for native systemd database initialization
init-native-db: init-db

# Starts native systemd services for non-containerized deployments
up-native: init-db
	@echo "Starting native systemd telecom core services..."
	@sudo systemctl start kamailio ngcp-rtpengine osmo-msc osmo-hlr 2>/dev/null || sudo systemctl start kamailio rtpengine osmo-msc osmo-hlr
	@sudo systemctl is-active --quiet kamailio && echo "  ✓ kamailio service active" || echo "  ✗ kamailio service inactive"
	@sudo systemctl is-active --quiet ngcp-rtpengine || sudo systemctl is-active --quiet rtpengine && echo "  ✓ rtpengine service active" || echo "  ✗ rtpengine service inactive"
	@sudo systemctl is-active --quiet osmo-msc && echo "  ✓ osmo-msc service active" || echo "  ✗ osmo-msc service inactive"
	@sudo systemctl is-active --quiet osmo-hlr && echo "  ✓ osmo-hlr service active" || echo "  ✗ osmo-hlr service inactive"

test-api:
	@echo "Testing API health..."
	@curl -s http://localhost:8080/actuator/health | python3 -m json.tool
	@echo ""
	@echo "Testing subscriber endpoint..."
	@curl -s http://localhost:8080/api/v1/intercept/subscriber/15551234567 | python3 -m json.tool

test-sms:
	@echo "Testing SMS intercept..."
	@curl -s -X POST http://localhost:8080/api/v1/intercept/sms \
		-H "Content-Type: application/json" \
		-d '{"sender":"15551234567","recipient":"15557654321","content":"Test SMS"}' | python3 -m json.tool

test-vty:
	@echo "=== Verifying OsmoHLR subscriber ==="
	@./scripts/vty.sh mvno-osmo-hlr 4258 "show subscribers all" | grep -q "001010000000001" && echo "  ✓ HLR subscriber found" || echo "  ✗ HLR subscriber not found"
	@echo "=== Verifying OsmoMSC SMPP listener ==="
	@./scripts/vty.sh mvno-osmosmsc 4254 "write terminal" | grep -q "esme mvno-api-route" && echo "  ✓ SMPP ESME configured" || echo "  ✗ SMPP ESME not found"

test: test-vty test-api test-sms test-call

test-call:
	@echo "Testing call intercept..."
	@curl -s -X POST http://localhost:8080/api/v1/intercept/call \
		-H "Content-Type: application/json" \
		-d '{"caller":"15551234567","callee":"15557654321","call_id":"test-123","imei":"356938035643809"}' | python3 -m json.tool
