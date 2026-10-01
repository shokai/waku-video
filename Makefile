APP_NAME := WakuVideo
BUNDLE_ID := org.shokai.WakuVideo
REPO := shokai/waku-video
CONFIG ?= release
CODESIGN_IDENTITY ?= WakuVideo Local Code Signing
APP := build/$(APP_NAME).app
# zip名にversionを含めず、releases/latest/download/WakuVideo.zipを最新版の固定のURLにする
ZIP := build/$(APP_NAME).zip
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
# make releaseを始めた時のcommit。ビルド後もHEADがこれと同じかを確かめ、tagもこれに打つ
RELEASE_SHA := $(shell git rev-parse HEAD 2>/dev/null)
# 利用者の画面収録の許可はこの証明書に紐付くので、配布物は必ずこの証明書で署名する
RELEASE_CERT_LEAF := e1d53b91d0a963517a14d858bc900dc02bc134f6
ZIP_CHECK_APP := build/zip-check/$(APP_NAME).app
SWIFT_SOURCES := Package.swift Sources Tests
# pkill（SIGTERM）だとapplicationShouldTerminateを通らず、録画中の動画を失う。通常のquitを送って終了を待つ
QUIT_APP := osascript -e 'if application id "$(BUNDLE_ID)" is running then tell application id "$(BUNDLE_ID)" to quit' \
	&& while pgrep -x $(APP_NAME) >/dev/null; do sleep 0.1; done
# Command Line Toolsだけの環境では、SwiftPMがTesting.framework・lib_TestingInterop・TestingMacrosのpluginの場所を渡さない
CLT_DEVELOPER := $(wildcard $(shell xcode-select -p)/Library/Developer)
CLT_TESTING_PLUGINS := $(wildcard $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing)
TEST_FLAGS := $(if $(CLT_DEVELOPER),-Xswiftc -F -Xswiftc $(CLT_DEVELOPER)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEVELOPER)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEVELOPER)/usr/lib) \
	$(if $(CLT_TESTING_PLUGINS),-Xswiftc -plugin-path -Xswiftc $(CLT_TESTING_PLUGINS))

.PHONY: app zip release run smoke test format lint logs probe reset-tcc check-identity check-release check-zip

app: check-identity
	swift build -c $(CONFIG) --product $(APP_NAME)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(CODESIGN_IDENTITY)" --identifier $(BUNDLE_ID) --options runtime --timestamp=none "$(APP)"
	codesign --verify --strict "$(APP)"

# xattrをzipに入れると、unzip等で展開した時に._*が.appの中に混ざり、署名が壊れる
zip: app
	rm -f "$(ZIP)"
	ditto -c -k --norsrc --keepParent "$(APP)" "$(ZIP)"

# ビルド中にcommitを切り替えたりファイルを編集したりした時に、tagと違う中身を配布しないよう、ビルドの前後で同じcommit・versionを検査する
release: check-release
	$(MAKE) zip CONFIG=release
	$(MAKE) check-release VERSION=$(VERSION)
	@test "$$(git rev-parse HEAD)" = "$(RELEASE_SHA)" || { echo "ビルド中にHEADが変わりました"; exit 1; }
	$(MAKE) check-zip VERSION=$(VERSION)
	gh release create "v$(VERSION)" "$(ZIP)" --repo $(REPO) --target "$(RELEASE_SHA)" --title "$(APP_NAME) $(VERSION)" \
		--notes "インストール方法は[README](https://github.com/$(REPO)#インストール)を参照" --generate-notes

# binaryを直接実行すると、画面収録の許可がTerminalに付いてしまう。openで.appとして起動する
run: app
	$(QUIT_APP)
	open "$(APP)"

# 自動で録画する経路はdebugビルドにしか無い
smoke:
	$(MAKE) app CONFIG=debug
	$(QUIT_APP)
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
	-tccutil reset SystemPolicyDocumentsFolder $(BUNDLE_ID)
	-tccutil reset SystemPolicyDownloadsFolder $(BUNDLE_ID)
	-tccutil reset SystemPolicyRemovableVolumes $(BUNDLE_ID)
	-tccutil reset SystemPolicyNetworkVolumes $(BUNDLE_ID)

# 自己署名証明書は信頼設定をしない限り`-v`（有効なidentityのみ）に出てこないので、-v無しで探す
check-identity:
	@security find-identity -p codesigning | grep -qF "\"$(CODESIGN_IDENTITY)\"" || { \
		echo "コード署名証明書 '$(CODESIGN_IDENTITY)' がキーチェーンにありません。README.mdの手順で作成してください"; \
		exit 1; }

# releaseではなくtagの有無を見る。tagだけ残っていると、gh release create --targetはtagを動かさず、そのtagに載せてしまう
check-release:
	@test -n "$(VERSION)" || { echo "Support/Info.plistからversionを読めません"; exit 1; }
	@test -z "$$(git status --porcelain --untracked-files=all)" || { echo "commitしていない変更があります"; exit 1; }
	@git fetch --quiet --tags origin main
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { \
		echo "HEADがorigin/mainと一致しません。mainをpullしてから実行してください"; \
		exit 1; }
	@! git rev-parse --quiet --verify "refs/tags/v$(VERSION)" >/dev/null || { \
		echo "tag v$(VERSION) は既にあります。公開済みならSupport/Info.plistのversionを上げ、失敗したmake releaseの残りならREADMEの「リリース」を見てください"; \
		exit 1; }

check-zip:
	rm -rf build/zip-check
	ditto -x -k "$(ZIP)" build/zip-check
	codesign --verify --strict -R='identifier "$(BUNDLE_ID)" and certificate leaf = H"$(RELEASE_CERT_LEAF)"' "$(ZIP_CHECK_APP)"
	@codesign -dv "$(ZIP_CHECK_APP)" 2>&1 | grep -q '(runtime)' || { echo "hardened runtimeが有効ではありません"; exit 1; }
	@test "$$(lipo -archs "$(ZIP_CHECK_APP)/Contents/MacOS/$(APP_NAME)")" = arm64 || { echo "arm64だけのbinaryではありません"; exit 1; }
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(ZIP_CHECK_APP)/Contents/Info.plist")" = "$(VERSION)" || { \
		echo "zipの中のversionが$(VERSION)ではありません"; \
		exit 1; }
