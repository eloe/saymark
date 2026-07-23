# Saymark — build helpers.
#
# Builds are RELEASE: MLX-Swift in Debug is ~4-5x slower (RTF 2.6 vs 0.59 on the
# same clip) because every MLXArray call goes through unoptimised Swift wrappers
# → not realtime. Xcode 26 also breaks explicitly-built modules for some SPM deps
# (swift-algorithms → RealModule), so builds disable them; arm64-only keeps the
# heavy MLX build short.

WORKSPACE = Saymark.xcworkspace
SCHEME    = Saymark
XCB = tuist xcodebuild build -workspace $(WORKSPACE) -scheme $(SCHEME) \
	-configuration Release -destination 'generic/platform=macOS' -allowProvisioningUpdates \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO

.PHONY: legal-check gen gen-local build run setup-local-signing install-local clean cli run-cli bench bench-accept-efficient bench-accept-live \
	test-unit test-integration model-fixture prepare-model-tests test-model-efficient test-model-live \
	test-model-parakeet-int8 test-model-live-parakeet-int8 report-diagnostics

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
UI_TEST_DERIVED_DATA ?= /tmp/saymark-ui-tests
LOCAL_BUILD ?= 1001
LOCAL_DERIVED_DATA ?= /tmp/saymark-local-build

legal-check:
	Scripts/check-legal-notices.sh

gen: legal-check
	tuist generate --no-open

gen-local: legal-check
	DEVELOPER_DIR="$(DEVELOPER_DIR)" TUIST_SAYMARK_LOCAL_BUILD=1 \
		TUIST_APP_VERSION=0.1.1 TUIST_APP_BUILD="$(LOCAL_BUILD)" tuist generate --no-open

build: gen
	$(XCB)

run: build
	-killall Saymark 2>/dev/null          # quit a stale background agent so `open` launches the fresh build
	@sleep 1                             # let it fully die — else `open` races LaunchServices (-600)
	open "$$(find $(HOME)/Library/Developer/Xcode/DerivedData/Saymark-*/Build/Products/Release -maxdepth 1 -name Saymark.app | head -1)"

# One-time, local-only identity. It neither needs nor impersonates the upstream
# owner's Developer ID certificate and cannot create notarized release builds.
setup-local-signing:
	Scripts/setup-local-signing.sh

# Build and install the separate local bundle without the upstream owner's team.
install-local: setup-local-signing gen-local
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild build -workspace "$(WORKSPACE)" \
		-scheme "$(SCHEME)" -configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" -skipPackagePluginValidation \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet
	Scripts/install-local.sh "$(LOCAL_DERIVED_DATA)/Build/Products/Release/Saymark.app"

# saymark-cli — same SaymarkKit core as the app, RELEASE. `swift build` is flaky at
# emitting mlx-swift's Cmlx metallib bundle in a fresh checkout, so copy a
# known-good one next to the binary (app DerivedData, else main mlx-audio-swift).
KIT_REL     = SaymarkKit/.build/release
CMLX_BUNDLE = mlx-swift_Cmlx.bundle
CMLX_SRC := $(firstword \
	$(wildcard $(HOME)/Library/Developer/Xcode/DerivedData/Saymark-*/Build/Products/Release/$(CMLX_BUNDLE)) \
	$(wildcard /Volumes/DATA/mlx-audio-swift/.build/arm64-apple-macosx/release/$(CMLX_BUNDLE)) \
	$(wildcard /Volumes/DATA/mlx-audio-swift/.build/arm64-apple-macosx/debug/$(CMLX_BUNDLE)))

cli:
	cd SaymarkKit && swift build -c release --product saymark-cli
	@if [ ! -e "$(KIT_REL)/$(CMLX_BUNDLE)/Contents/Resources/default.metallib" ]; then \
		if [ -n "$(CMLX_SRC)" ]; then cp -R "$(CMLX_SRC)" "$(KIT_REL)/" && echo "→ copied metallib bundle next to saymark-cli"; \
		else echo "WARN: no metallib bundle found — run 'make build' (the app) once to produce it"; fi; \
	fi

run-cli: cli
	"$(KIT_REL)/saymark-cli"

# Offline timing on a fixed file: make bench WAV=/path/to/clip.wav
WAV ?= /path/to/clip.wav
REFERENCE ?= Benchmarks/saymark-performance-reference.txt
MODEL_BENCHMARK_WAV ?= /tmp/saymark-performance.aiff
MODEL_BENCHMARK_RUNS ?= 20
DIAGNOSTIC_LOG ?= $(HOME)/Library/Logs/com.eloe.saymark.local/saymark.jsonl
bench: cli
	"$(KIT_REL)/saymark-cli" --wav "$(WAV)"

bench-accept-efficient: cli
	"$(KIT_REL)/saymark-cli" --wav "$(WAV)" --mode accurate --runs 20 \
		--accept efficient --reference "$(REFERENCE)"

bench-accept-live: cli
	"$(KIT_REL)/saymark-cli" --wav "$(WAV)" --mode hybrid --runs 20 \
		--accept live-preview --reference "$(REFERENCE)"

model-fixture:
	@if [ ! -s "$(MODEL_BENCHMARK_WAV)" ]; then \
		say -v Samantha -f "$(REFERENCE)" -o "$(MODEL_BENCHMARK_WAV)"; \
	fi

prepare-model-tests:
	cd SaymarkKit && DEVELOPER_DIR="$(DEVELOPER_DIR)" swift test -c release \
		--filter RealModelAcceptanceTests/testSelectedModelProfileMeetsAcceptanceBudget
	@bin="$$(cd SaymarkKit && DEVELOPER_DIR="$(DEVELOPER_DIR)" swift build -c release --show-bin-path)"; \
		mkdir -p "$$bin/SaymarkKitPackageTests.xctest/Contents/Resources"; \
		ditto "$$bin/$(CMLX_BUNDLE)" \
			"$$bin/SaymarkKitPackageTests.xctest/Contents/Resources/$(CMLX_BUNDLE)"

test-model-efficient: model-fixture prepare-model-tests
	cd SaymarkKit && SAYMARK_MODEL_PROFILE=efficient \
		SAYMARK_MODEL_BENCHMARK_WAV="$(MODEL_BENCHMARK_WAV)" \
		SAYMARK_MODEL_BENCHMARK_REFERENCE="$(abspath $(REFERENCE))" \
		SAYMARK_MODEL_BENCHMARK_RUNS="$(MODEL_BENCHMARK_RUNS)" \
		DEVELOPER_DIR="$(DEVELOPER_DIR)" swift test -c release --skip-build \
		--filter RealModelAcceptanceTests/testSelectedModelProfileMeetsAcceptanceBudget

test-model-live: model-fixture prepare-model-tests
	cd SaymarkKit && SAYMARK_MODEL_PROFILE=live-preview \
		SAYMARK_MODEL_BENCHMARK_WAV="$(MODEL_BENCHMARK_WAV)" \
		SAYMARK_MODEL_BENCHMARK_REFERENCE="$(abspath $(REFERENCE))" \
		SAYMARK_MODEL_BENCHMARK_RUNS="$(MODEL_BENCHMARK_RUNS)" \
		DEVELOPER_DIR="$(DEVELOPER_DIR)" swift test -c release --skip-build \
		--filter RealModelAcceptanceTests/testSelectedModelProfileMeetsAcceptanceBudget

test-model-parakeet-int8: model-fixture prepare-model-tests
	cd SaymarkKit && SAYMARK_MODEL_PROFILE=efficient \
		SAYMARK_PARAKEET_REPO="beshkenadze/parakeet-tdt-0.6b-v3-mlx-encoder-int8" \
		SAYMARK_MODEL_BENCHMARK_WAV="$(MODEL_BENCHMARK_WAV)" \
		SAYMARK_MODEL_BENCHMARK_REFERENCE="$(abspath $(REFERENCE))" \
		SAYMARK_MODEL_BENCHMARK_RUNS="$(MODEL_BENCHMARK_RUNS)" \
		DEVELOPER_DIR="$(DEVELOPER_DIR)" swift test -c release --skip-build \
		--filter RealModelAcceptanceTests/testSelectedModelProfileMeetsAcceptanceBudget

test-model-live-parakeet-int8: model-fixture prepare-model-tests
	cd SaymarkKit && SAYMARK_MODEL_PROFILE=live-preview \
		SAYMARK_PARAKEET_REPO="beshkenadze/parakeet-tdt-0.6b-v3-mlx-encoder-int8" \
		SAYMARK_MODEL_BENCHMARK_WAV="$(MODEL_BENCHMARK_WAV)" \
		SAYMARK_MODEL_BENCHMARK_REFERENCE="$(abspath $(REFERENCE))" \
		SAYMARK_MODEL_BENCHMARK_RUNS="$(MODEL_BENCHMARK_RUNS)" \
		DEVELOPER_DIR="$(DEVELOPER_DIR)" swift test -c release --skip-build \
		--filter RealModelAcceptanceTests/testSelectedModelProfileMeetsAcceptanceBudget

report-diagnostics:
	Scripts/report-diagnostics.sh "$(DIAGNOSTIC_LOG)"

# Fast app/HUD suite against an optimized arm64 build. Testability is enabled
# only for this invocation, never for the normal distributable Release build.
test-unit: gen-local
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild test -workspace "$(WORKSPACE)" \
		-scheme "$(SCHEME)" -configuration Release -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath "$(UI_TEST_DERIVED_DATA)" -skipPackagePluginValidation \
		-only-testing:SaymarkTests ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
		SWIFT_ENABLE_EXPLICIT_MODULES=NO ENABLE_TESTABILITY=YES \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet

# Native macOS end-to-end tests. External boundaries are deterministic; the real
# SwiftUI/AppKit onboarding, navigation, and lifecycle run under XCUITest.
test-integration: gen-local
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild test -workspace "$(WORKSPACE)" \
		-scheme "$(SCHEME)" -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath "$(UI_TEST_DERIVED_DATA)" -skipPackagePluginValidation \
		-only-testing:SaymarkUITests SWIFT_ENABLE_EXPLICIT_MODULES=NO \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet
	@Scripts/report-xcresult.sh "$(UI_TEST_DERIVED_DATA)"

clean:
	rm -rf build Saymark.xcodeproj Saymark.xcworkspace Derived SaymarkKit/.build
