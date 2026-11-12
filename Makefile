# MacPad: a native macOS text editor (AppKit front end, Scintilla + Lexilla editing core).
# Requires only the Xcode command line tools (xcode-select --install).
#
#   make              build build/<APP_NAME>.app for this Mac's architecture
#   make UNIVERSAL=1  build a universal (arm64 + x86_64) app
#   make run          build and launch the app
#   make test         run the end-to-end self test (opens windows for about a minute)
#   make install      copy the app to /Applications
#   make dist         universal build packed as build/<APP_NAME>-<version>.dmg and .zip
#   make clean        remove the build directory
#
# iOS app (needs Xcode and XcodeGen):
#   make ios-project  generate ios/MacPad.xcodeproj from ios/project.yml
#   make ios          build the iOS app for the simulator
#   make ios-test     run the iOS tests on a simulator (IOS_SIMULATOR="iPhone 17")
#
# The build runs in parallel by default; pass -j1 for a serial build.

APP_NAME    ?= MacPad
BUNDLE_ID   ?= dev.macpad.editor
APP_VERSION ?= 0.2.0
MIN_MACOS   ?= 11.0
# Code signing identity. "-" signs ad hoc; use "Developer ID Application: ..." to distribute.
SIGN_ID     ?= -
# Web page of the project, shown in the Help menu when set (for example the GitHub repository).
HOMEPAGE    ?= https://jeffjna.github.io/MacPad/

# Scintilla and Lexilla, unchanged (see vendor/README.md).
SCI := vendor/scintilla
LEX := vendor/lexilla

BUILD := build
APP   := $(BUILD)/$(APP_NAME).app

CXX := clang++

ifeq ($(filter -j%,$(MAKEFLAGS)),)
MAKEFLAGS += -j$(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)
endif

# Objects of each architecture set live in their own directory.
ifeq ($(UNIVERSAL),1)
ARCHFLAGS := -arch arm64 -arch x86_64
OBJ       := $(BUILD)/obj-universal
else
ARCHFLAGS :=
OBJ       := $(BUILD)/obj
endif

COMMON_FLAGS := $(ARCHFLAGS) -mmacosx-version-min=$(MIN_MACOS) -O2 -DNDEBUG -MMD -MP
CXXSTD       := -std=c++17
INCLUDES     := -I$(SCI)/include -I$(SCI)/cocoa -I$(LEX)/include -I$(LEX)/lexlib -Ishared
# Third-party code is built as-is; keep its warnings out of the way.
# (scintilla/src is only needed there, and has its own Document.h.)
THIRD_PARTY_FLAGS := $(COMMON_FLAGS) $(CXXSTD) $(INCLUDES) -I$(SCI)/src -w
APP_FLAGS         := $(COMMON_FLAGS) $(CXXSTD) -Isrc $(INCLUDES) -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
                     -DMACPAD_VERSION='"$(APP_VERSION)"'

LDFLAGS := $(ARCHFLAGS) -mmacosx-version-min=$(MIN_MACOS) \
           -framework Cocoa -framework QuartzCore -framework UniformTypeIdentifiers

SCI_SRC     := $(wildcard $(SCI)/src/*.cxx)
COCOA_SRC   := $(wildcard $(SCI)/cocoa/*.mm)
LEXLIB_SRC  := $(wildcard $(LEX)/lexlib/*.cxx)
LEXERS_SRC  := $(wildcard $(LEX)/lexers/*.cxx)
LEXILLA_SRC := $(LEX)/src/Lexilla.cxx
SHARED_SRC  := $(wildcard shared/*.mm)
APP_SRC     := $(wildcard src/*.mm)

OBJS := $(patsubst $(SCI)/src/%.cxx,$(OBJ)/scintilla/%.o,$(SCI_SRC)) \
        $(patsubst $(SCI)/cocoa/%.mm,$(OBJ)/cocoa/%.o,$(COCOA_SRC)) \
        $(patsubst $(LEX)/lexlib/%.cxx,$(OBJ)/lexlib/%.o,$(LEXLIB_SRC)) \
        $(patsubst $(LEX)/lexers/%.cxx,$(OBJ)/lexers/%.o,$(LEXERS_SRC)) \
        $(OBJ)/lexilla/Lexilla.o \
        $(patsubst shared/%.mm,$(OBJ)/shared/%.o,$(SHARED_SRC)) \
        $(patsubst src/%.mm,$(OBJ)/app/%.o,$(APP_SRC))

EXE := $(APP)/Contents/MacOS/$(APP_NAME)

.PHONY: all app run test install dist clean ios-project ios ios-test

all: app

app: $(EXE) $(APP)/Contents/Info.plist resources
	@codesign --force --sign "$(SIGN_ID)" "$(APP)" >/dev/null 2>&1 || true
	@echo "Built $(APP)"

run: app
	open "$(APP)"

install: app
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	@echo "Installed /Applications/$(APP_NAME).app"

clean:
	rm -rf $(BUILD)

# Distribution: a universal build in a disk image and a zip.
DIST_NAME := $(APP_NAME)-$(APP_VERSION)
dist:
	@MAKEFLAGS="$(filter-out -j% --jobserver%,$(MAKEFLAGS))" $(MAKE) UNIVERSAL=1 app
	@rm -rf "$(BUILD)/dmg" "$(BUILD)/$(DIST_NAME).dmg" "$(BUILD)/$(DIST_NAME).zip"
	@mkdir -p "$(BUILD)/dmg"
	@cp -R "$(APP)" "$(BUILD)/dmg/"
	@ln -s /Applications "$(BUILD)/dmg/Applications"
	@hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$(BUILD)/dmg" -ov -format UDZO "$(BUILD)/$(DIST_NAME).dmg"
	@rm -rf "$(BUILD)/dmg"
	@ditto -c -k --keepParent "$(APP)" "$(BUILD)/$(DIST_NAME).zip"
	@echo "Packed $(BUILD)/$(DIST_NAME).dmg and $(BUILD)/$(DIST_NAME).zip"

# The self test is linked into a copy of the app with its own bundle id, so it never
# touches the settings of the real app. Results: build/test-results/log.txt and *.png.
TEST_APP := $(BUILD)/$(APP_NAME)Test.app
TEST_OUT := $(BUILD)/test-results

$(OBJ)/test/SelfTest.o: test/SelfTest.mm
	@mkdir -p $(dir $@)
	@echo "  OBJC $<"
	@$(CXX) $(APP_FLAGS) -c $< -o $@

test: app $(OBJ)/test/SelfTest.o
	@rm -rf "$(TEST_APP)" "$(TEST_OUT)"
	@cp -R "$(APP)" "$(TEST_APP)"
	@$(CXX) $(OBJS) $(OBJ)/test/SelfTest.o $(LDFLAGS) -o "$(TEST_APP)/Contents/MacOS/$(APP_NAME)"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID).selftest" "$(TEST_APP)/Contents/Info.plist"
	@codesign --force --sign - "$(TEST_APP)" >/dev/null 2>&1 || true
	@defaults delete "$(BUNDLE_ID).selftest" >/dev/null 2>&1 || true
	@rm -rf "$(HOME)/Library/Application Support/$(BUNDLE_ID).selftest"
	@open -n -W --env MACPAD_SELFTEST="$(abspath $(TEST_OUT))" "$(TEST_APP)" --args -ApplePersistenceIgnoreState YES
	@# The first run ends by quitting with unsaved documents; the second checks that they come back.
	@open -n -W --env MACPAD_SELFTEST="$(abspath $(TEST_OUT))" --env MACPAD_SELFTEST_PHASE=2 \
	    -a "$(abspath $(TEST_APP))" "$(abspath $(TEST_OUT))/files/relaunch-extra.txt" --args -ApplePersistenceIgnoreState YES
	@cat "$(TEST_OUT)/log.txt"
	@! grep -q '^FAIL' "$(TEST_OUT)/log.txt"
	@# Both runs must have reached their summary line: a crash half-way is a failure too.
	@test "$$(grep -c '^== [0-9]* passed, 0 failed' "$(TEST_OUT)/log.txt")" = 2

# Relink when switching between native and UNIVERSAL=1 builds: the stamp only
# changes (and so only triggers a link) when the architecture flags change.
ARCH_STAMP := $(BUILD)/.archflags
$(ARCH_STAMP): FORCE
	@mkdir -p $(dir $@)
	@echo '$(ARCHFLAGS)' | cmp -s - $@ || echo '$(ARCHFLAGS)' > $@

.PHONY: FORCE
FORCE:

$(EXE): $(OBJS) $(ARCH_STAMP)
	@mkdir -p $(dir $@)
	@echo "  LINK $@"
	@$(CXX) $(OBJS) $(LDFLAGS) -o $@

# Always regenerated: its content depends on variables given on the command line.
$(APP)/Contents/Info.plist: Info.plist Makefile FORCE
	@mkdir -p $(dir $@)
	@sed -e 's/@APP_NAME@/$(APP_NAME)/g' -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' \
	    -e 's/@APP_VERSION@/$(APP_VERSION)/g' -e 's/@MIN_MACOS@/$(MIN_MACOS)/g' \
	    -e 's|@HOMEPAGE@|$(HOMEPAGE)|g' $< > $@

# Languages, style map and themes (data/, see tools/gen-data.py).
RES := $(APP)/Contents/Resources
.PHONY: resources
resources:
	@rm -rf "$(RES)"
	@mkdir -p "$(RES)/themes"
	@cp data/languages.json data/stylemap.json "$(RES)/"
	@cp data/themes/*.json "$(RES)/themes/"
	@cp resources/AppIcon.icns "$(RES)/AppIcon.icns"
	@cp LICENSE "$(RES)/LICENSE.txt"
	@cp resources/Acknowledgements.txt "$(RES)/Acknowledgements.txt"
	@tiffutil -cathidpicheck $(SCI)/cocoa/res/mac_cursor_busy.png $(SCI)/cocoa/res/mac_cursor_busy@2x.png \
	    -out "$(RES)/mac_cursor_busy.tiff" >/dev/null 2>&1
	@tiffutil -cathidpicheck $(SCI)/cocoa/res/mac_cursor_flipped.png $(SCI)/cocoa/res/mac_cursor_flipped@2x.png \
	    -out "$(RES)/mac_cursor_flipped.tiff" >/dev/null 2>&1
	@tiffutil -cathidpicheck $(SCI)/cocoa/res/info_bar_bg.png $(SCI)/cocoa/res/info_bar_bg@2x.png \
	    -out "$(RES)/info_bar_bg.tiff" >/dev/null 2>&1

$(OBJ)/scintilla/%.o: $(SCI)/src/%.cxx
	@mkdir -p $(dir $@)
	@echo "  CXX  $<"
	@$(CXX) $(THIRD_PARTY_FLAGS) -c $< -o $@

$(OBJ)/cocoa/%.o: $(SCI)/cocoa/%.mm
	@mkdir -p $(dir $@)
	@echo "  OBJC $<"
	@$(CXX) $(THIRD_PARTY_FLAGS) -fobjc-arc -c $< -o $@

$(OBJ)/lexlib/%.o: $(LEX)/lexlib/%.cxx
	@mkdir -p $(dir $@)
	@echo "  CXX  $<"
	@$(CXX) $(THIRD_PARTY_FLAGS) -c $< -o $@

$(OBJ)/lexers/%.o: $(LEX)/lexers/%.cxx
	@mkdir -p $(dir $@)
	@echo "  CXX  $<"
	@$(CXX) $(THIRD_PARTY_FLAGS) -c $< -o $@

$(OBJ)/lexilla/Lexilla.o: $(LEXILLA_SRC)
	@mkdir -p $(dir $@)
	@echo "  CXX  $<"
	@$(CXX) $(THIRD_PARTY_FLAGS) -DLEXILLA_NO_EXPORT -c $< -o $@

$(OBJ)/shared/%.o: shared/%.mm
	@mkdir -p $(dir $@)
	@echo "  OBJC $<"
	@$(CXX) $(APP_FLAGS) -c $< -o $@

$(OBJ)/app/%.o: src/%.mm
	@mkdir -p $(dir $@)
	@echo "  OBJC $<"
	@$(CXX) $(APP_FLAGS) -c $< -o $@

-include $(OBJS:.o=.d)

# iOS ---------------------------------------------------------------------------------

IOS_SIMULATOR ?= iPhone 17
IOS_PROJECT   := ios/MacPad.xcodeproj
IOS_FLAGS     := -project $(IOS_PROJECT) -scheme MacPad -derivedDataPath $(BUILD)/ios \
                 -destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR)' -quiet

# The generated project is kept in the repository, so that Xcode opens it directly;
# run `make ios-project` after changing ios/project.yml or adding files.
ios-project:
	@cd ios && xcodegen generate --quiet
	@echo "Generated $(IOS_PROJECT)"

$(IOS_PROJECT):
	@cd ios && xcodegen generate --quiet

ios: | $(IOS_PROJECT)
	@xcodebuild -project $(IOS_PROJECT) -scheme MacPad -derivedDataPath $(BUILD)/ios \
	    -destination 'generic/platform=iOS Simulator' -quiet build
	@echo "Built $(BUILD)/ios/Build/Products/Debug-iphonesimulator/MacPad.app"

ios-test: | $(IOS_PROJECT)
	@xcodebuild $(IOS_FLAGS) test
