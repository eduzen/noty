set shell := ["bash", "-cu"]

project := "Noty.xcodeproj"
scheme := "Noty"
destination := "platform=macOS"
derived_data := "build/DerivedData"
app_path := derived_data + "/Build/Products/Debug/Noty.app"

default:
    @just --list

build:
    xcodebuild -project "{{project}}" -scheme "{{scheme}}" -destination "{{destination}}" -derivedDataPath "{{derived_data}}" build -quiet

test:
    xcodebuild -project "{{project}}" -scheme "{{scheme}}" -destination "{{destination}}" -derivedDataPath "{{derived_data}}" test -quiet

test-only target:
    xcodebuild -project "{{project}}" -scheme "{{scheme}}" -destination "{{destination}}" -derivedDataPath "{{derived_data}}" test -quiet "-only-testing:NotyTests/{{target}}"

test-controller:
    xcodebuild -project "{{project}}" -scheme "{{scheme}}" -destination "{{destination}}" -derivedDataPath "{{derived_data}}" test -quiet -only-testing:NotyTests/RecordingControllerTests -only-testing:NotyTests/MenuBarViewTests

test-integration:
    xcodebuild -project "{{project}}" -scheme "{{scheme}}" -destination "{{destination}}" -derivedDataPath "{{derived_data}}" test -quiet -only-testing:NotyTests/RecordingPipelineIntegrationTests

run: build
    open "{{app_path}}"

quit:
    osascript -e 'tell application "Noty" to quit'

clean:
    xcodebuild -project "{{project}}" -scheme "{{scheme}}" -derivedDataPath "{{derived_data}}" clean

check:
    just test
    just build
    git diff --check

format:
    prek run --all-files
