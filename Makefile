.PHONY: scanner-dependencies test app

# Debug test runs read the sealed ledger back after every write and compare it with memory.
test:
	python3 scripts/prepare-scanner.py
	SPILLCHECK_VERIFY_LEDGER_LAYOUT=1 swift test

app:
	scripts/build-app.sh

scanner-dependencies:
	python3 scripts/install-scanner.py
	python3 scripts/prepare-scanner.py
