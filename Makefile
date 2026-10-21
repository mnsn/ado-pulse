.PHONY: build test app package install uninstall run demo dump watch render icon signing-identity signing-key-check demo-check screenshots clean

# With only the Command Line Tools installed, the compiler sometimes misses Swift Testing's macro
# plugin (it lives in a subfolder), so point it there explicitly.
TESTING_PLUGINS := $(abspath $(dir $(shell xcrun --find swift))../lib/swift/host/plugins/testing)

# The binary that demo-check runs: the debug build, unless scripts/check-app.sh passes a built app.
PULSE := .build/debug/ADOPulse
SCREENSHOTS := menubar-light menubar-dark widget-large-light widget-large-dark

build:
	swift build

test:
	swift test $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

app:
	./scripts/build-app.sh

# The release zip: a universal app, checked and zipped, with its SHA-256 and notes in build/release.
package:
	./scripts/package.sh

install:
	./scripts/build-app.sh --install

uninstall:
	-pgrep -f "/ADO Pulse.app/Contents/MacOS/ADOPulse" | xargs kill 2>/dev/null
	rm -rf "$(HOME)/Applications/ADO Pulse.app"

run: build
	.build/debug/ADOPulse

# Runs the app with made-up pull requests instead of yours. Ctrl-C quits.
demo: build
	.build/debug/ADOPulse --demo

dump: build
	.build/debug/ADOPulse --dump

watch: build
	.build/debug/ADOPulse --watch

# Renders your own pull requests: the pictures show their titles, so they go to the ignored render/.
render: build
	.build/debug/ADOPulse --render render

# Checks that the made-up pull requests land in the expected groups.
demo-check: $(if $(filter command line,$(origin PULSE)),,build)
	@counts=$$("$(PULSE)" --demo --json | jq -cS .counts); \
	expected='{"answered":1,"done":1,"failing":2,"idle":2,"needsYou":4,"ready":2,"toReview":1,"waiting":2}'; \
	if [ "$$counts" != "$$expected" ]; then echo "demo-check failed: expected $$expected, got $$counts" >&2; exit 1; fi; \
	if ! "$(PULSE)" --demo --orgs | grep -qx '\*+ contoso'; then \
		echo "demo-check failed: --demo --orgs doesn't list only the made-up organization" >&2; exit 1; fi; \
	if ! "$(PULSE)" --demo --watch | grep -q 'needsYou  Priya Shah commented: !4091'; then \
		echo "demo-check failed: --demo --watch doesn't show the made-up change" >&2; exit 1; fi; \
	if ! "$(PULSE)" --demo --chats | grep -q 'Dana Whitfield .*contoso/4113'; then \
		echo "demo-check failed: --demo --chats doesn't show the made-up links" >&2; exit 1; fi; \
	echo "demo-check passed: $$counts"

# Renders the README screenshots from the demo data.
screenshots: build
	.build/debug/ADOPulse --demo --render build/screenshots
	mkdir -p docs/images
	for name in $(SCREENSHOTS); do cp build/screenshots/$$name.png docs/images/; done

# Once per Mac: a certificate to sign builds with, so Full Disk Access survives rebuilds.
signing-identity:
	./scripts/make-signing-identity.sh

# Checks, in throwaway keychains, that no app may use the keys builds and releases are signed with
# without asking (but codesign, for a release's), and that they can't be exported.
signing-key-check:
	./scripts/test-signing-key.sh

icon:
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
