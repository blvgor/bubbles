# Bubbles — build with the Command Line Tools only (no Xcode).
#   make check   build + all tests (the one check command)
#   make test    tests only;  one suite: swift test --filter <SuiteName>
#   make app     build/Bubbles.app (release, ad-hoc signed)
#   make run     launch it
#   make install copy to ~/Applications
#   make check-direct / make app DIRECT=1   same without SwiftPM, for restricted sandboxes
#   make vendor  download whisper.cpp and the Whisper model into Vendor/ (once; build and app do it themselves)

# Module cache inside .build so builds work where the default cache folder is not writable.
export CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.build/module-cache
# --disable-sandbox: SwiftPM's own manifest sandbox cannot nest inside another sandbox.
SWIFTPM_FLAGS ?= --disable-sandbox
export SWIFTPM_FLAGS
# Where the Command Line Tools keep the TestingMacros plugin: without it `swift test` sometimes fails to
# expand @Test / #expect («plugin not found»).
TESTING_PLUGINS ?= /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TEST_FLAGS ?= -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)

APP := build/Bubbles.app

.PHONY: check build test app run install clean check-direct vendor whisper-framework

check: build test

# The package links Vendor/whisper.xcframework: SwiftPM needs it on disk even for the core tests.
whisper-framework:
	scripts/fetch-whisper.sh framework

vendor:
	scripts/fetch-whisper.sh all

build: whisper-framework
	swift build $(SWIFTPM_FLAGS)

test: whisper-framework
	swift test $(SWIFTPM_FLAGS) $(TEST_FLAGS)

check-direct:
	scripts/direct-build.sh app
	scripts/direct-build.sh test

app:
	scripts/build-app.sh

run: app
	open $(APP)

install: app
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/Bubbles.app
	cp -R $(APP) $(HOME)/Applications/

clean:
	rm -rf .build build
