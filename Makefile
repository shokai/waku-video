APP_NAME := VideoClip
BUNDLE_ID := org.shokai.VideoClip
CONFIG ?= release
CODESIGN_IDENTITY ?= VideoClip Local Code Signing
APP := build/$(APP_NAME).app
SWIFT_SOURCES := Package.swift Sources Tests
# Command Line Toolsだけの環境では、SwiftPMがTesting.frameworkとlib_TestingInteropの場所を渡さない
CLT_DEVELOPER := $(wildcard $(shell xcode-select -p)/Library/Developer)
TEST_FLAGS := $(if $(CLT_DEVELOPER),-Xswiftc -F -Xswiftc $(CLT_DEVELOPER)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEVELOPER)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEVELOPER)/usr/lib)

.PHONY: app run smoke test format lint logs probe reset-tcc check-identity

app: check-identity
	swift build -c $(CONFIG) --product $(APP_NAME)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(CODESIGN_IDENTITY)" --identifier $(BUNDLE_ID) --timestamp=none "$(APP)"
	codesign --verify --strict "$(APP)"

# binaryを直接実行すると、画面収録の許可がTerminalに付いてしまう。openで.appとして起動する
run: app
	-pkill -x $(APP_NAME)
	while pgrep -x $(APP_NAME) >/dev/null; do sleep 0.1; done
	open "$(APP)"

smoke: app
	-pkill -x $(APP_NAME)
	while pgrep -x $(APP_NAME) >/dev/null; do sleep 0.1; done
	rm -rf build/smoke
	open -W "$(APP)" --args -SmokeRecordSeconds 3 -SaveDirectory "$(CURDIR)/build/smoke"
	MIN_DURATION=2.5 scripts/probe.sh build/smoke/*.mp4

test:
	swift test --disable-xctest $(TEST_FLAGS)

format:
	swift format --in-place --recursive --parallel $(SWIFT_SOURCES)

lint:
	swift format lint --strict --recursive --parallel $(SWIFT_SOURCES)

logs:
	log stream --level debug --predicate 'subsystem == "$(BUNDLE_ID)"'

probe:
	scripts/probe.sh

reset-tcc:
	-tccutil reset ScreenCapture $(BUNDLE_ID)
	-tccutil reset SystemPolicyDesktopFolder $(BUNDLE_ID)

# 自己署名証明書は信頼設定をしない限り`-v`（有効なidentityのみ）に出てこないので、-v無しで探す
check-identity:
	@security find-identity -p codesigning | grep -qF "\"$(CODESIGN_IDENTITY)\"" || { \
		echo "コード署名証明書 '$(CODESIGN_IDENTITY)' がキーチェーンにありません。README.mdの手順で作成してください"; \
		exit 1; }
