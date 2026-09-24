.PHONY: build test bench app run icon clean

build:
	swift build

# The Command Line Tools macro plugin server occasionally fails on the first compile
# after a change ("plugin for module 'TestingMacros' not found"); a retry fixes it.
test:
	swift build --build-tests || swift build --build-tests
	swift test --skip-build

bench:
	swift build -c release --build-tests -Xswiftc -enable-testing || swift build -c release --build-tests -Xswiftc -enable-testing
	swift test -c release --skip-build -Xswiftc -enable-testing --filter StitcherPerformance

# Assemble and sign build/Xnap.app (pass SIGN_IDENTITY=… for a stable signature).
app:
	./scripts/build-app.sh

run: app
	open build/Xnap.app

icon:
	rm -f Resources/AppIcon.icns
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
