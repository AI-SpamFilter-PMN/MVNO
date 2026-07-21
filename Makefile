.PHONY: up down logs ps init-db test test-sms test-call test-api test-vty

up:
	./scripts/up.sh

down:
	podman compose -f docker-compose.yml down

logs:
	podman compose -f docker-compose.yml logs -f

ps:
	podman ps

init-db:
	@mkdir -p state/mongodb state/spool state/hlr state/vm-data state/grafana state/logs/kamailio state/logs/osmocom
	@sqlite3 state/kamailio.db \
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
	@sqlite3 state/hlr/hlr.db \
		"PRAGMA journal_mode=WAL;" \
		"PRAGMA synchronous=NORMAL;"
	@echo "Databases initialized."

test-api:
	@echo "Testing API health..."
	@curl -s http://localhost:8080/actuator/health/ | python3 -m json.tool
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
	@podman exec mvno-osmo-hlr bash -c 'exec 3<>/dev/tcp/localhost/4258; echo enable >&3; sleep 1; echo "show subscribers all" >&3; sleep 1; dd bs=1024 count=1 <&3 2>/dev/null' | grep -q "001010000000001" && echo "  ✓ HLR subscriber found" || echo "  ✗ HLR subscriber not found"
	@echo "=== Verifying OsmoMSC SMPP listener ==="
	@podman exec mvno-osmosmsc bash -c 'exec 3<>/dev/tcp/localhost/4254; echo enable >&3; sleep 1; echo "write terminal" >&3; sleep 1; dd bs=8192 count=1 <&3 2>/dev/null' | strings | grep -q "esme mvno-api-route" && echo "  ✓ SMPP ESME configured" || echo "  ✗ SMPP ESME not found"

test: test-vty test-api test-sms test-call

test-call:
	@echo "Testing call intercept..."
	@curl -s -X POST http://localhost:8080/api/v1/intercept/call \
		-H "Content-Type: application/json" \
		-d '{"caller":"15551234567","callee":"15557654321","call_id":"test-123","imei":"356938035643809"}' | python3 -m json.tool
