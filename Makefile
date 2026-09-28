APP := build/Mach Saver.app
BIN := build/Mach\ Saver.app/Contents/MacOS/MachSaver
SOURCES := $(wildcard App/*.swift) $(wildcard screensavers/*/*.swift)
SAVERS := $(notdir $(wildcard screensavers/*))
INSTALLED := $(HOME)/Applications/Mach Saver.app

.PHONY: all build install uninstall preview snapshot jet icon clean

all: build

# Each screensaver's .txt/.png/.json assets land in Contents/Resources/<name>/.
build: $(SOURCES) Info.plist
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	swiftc -O -target arm64-apple-macos14.0 -o $(BIN) $(SOURCES)
	cp Info.plist "$(APP)/Contents/"
	cp Icon/AppIcon.icns "$(APP)/Contents/Resources/"
	for s in $(SAVERS); do \
		mkdir -p "$(APP)/Contents/Resources/$$s"; \
		find screensavers/$$s -maxdepth 1 -type f ! -name '*.swift' -exec cp {} "$(APP)/Contents/Resources/$$s/" \; ; \
	done
	codesign --force --sign - "$(APP)"

# Copies to ~/Applications, links the mach-saver command, and restarts the app in the menu bar.
install: build
	-pkill -x MachSaver
	rm -rf "$(INSTALLED)"
	mkdir -p $(HOME)/Applications $(HOME)/.local/bin
	cp -R "$(APP)" "$(INSTALLED)"
	ln -sf $(CURDIR)/bin/mach-saver $(HOME)/.local/bin/mach-saver
	open "$(INSTALLED)" --args --background

uninstall:
	-pkill -x MachSaver
	rm -rf "$(INSTALLED)" $(HOME)/.local/bin/mach-saver

# Shows the active screensaver now. Move the mouse or type to exit.
preview:
	open -g mach-saver://show

# Renders a frame of each screensaver to docs/<name>.png without taking over the screen.
snapshot: build
	for s in $(SAVERS); do $(BIN) --snapshot docs/$$s.png 4 $$s; done

# Rebuilds the afterburner jet from its source screenshot.
jet:
	swift screensavers/afterburner/tools/img2braille.swift screensavers/afterburner/tools/jet-source.png > screensavers/afterburner/jet.txt

# Redraws the app icon (Icon/make-icon.swift) from the afterburner jet.
icon:
	swift Icon/make-icon.swift Icon/AppIcon.iconset
	iconutil -c icns Icon/AppIcon.iconset -o Icon/AppIcon.icns

clean:
	rm -rf build
