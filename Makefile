.PHONY: scanner-dependencies test app

test:
	python3 scripts/prepare-scanner.py
	swift test

app:
	scripts/build-app.sh

scanner-dependencies:
	python3 scripts/install-scanner.py
	python3 scripts/prepare-scanner.py
