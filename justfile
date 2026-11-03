set shell := ["bash", "-cu"]

project := "Noty.xcodeproj"
scheme := "Noty"
destination := "platform=macOS"
derived_data := "build/DerivedData"
app_path := derived_data + "/Build/Products/Debug/Noty.app"

default:
    @just --list

build:
    # Xcode test preparation rewrites cached entitlements, including inherited helpers.
    # Regenerate these signing inputs so a normal build restores production permissions.
    rm -f "{{derived_data}}/Build/Intermediates.noindex/Noty.build/Debug/Noty.build/Noty.app.xcent" "{{derived_data}}/Build/Intermediates.noindex/Noty.build/Debug/NotyTranscriptionWorker.build/NotyTranscriptionWorker.xcent"
    rm -f "{{app_path}}/Contents/MacOS/NotyTranscriptionWorker"
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

# Clear stale privacy grants left by earlier ad-hoc builds. Run once after switching signing.
reset-permissions:
    -tccutil reset Microphone com.eduzen.noty
    -tccutil reset AudioCapture com.eduzen.noty
    -tccutil reset ScreenCapture com.eduzen.noty

# Create a self-signed "Noty Local" code-signing identity (no Apple ID) and point the build at it.
setup-signing:
    #!/usr/bin/env bash
    set -euo pipefail
    identity="Noty Local"
    keychain="$HOME/Library/Keychains/login.keychain-db"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    # Import once. Re-running after a cancelled trust prompt only repeats the trust step.
    if ! security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
        printf '%s\n' \
            '[req]' 'distinguished_name = dn' 'x509_extensions = ext' 'prompt = no' \
            '[dn]' 'CN = Noty Local' \
            '[ext]' 'basicConstraints = critical,CA:false' \
            'keyUsage = critical,digitalSignature' 'extendedKeyUsage = critical,codeSigning' \
            > "$tmp/openssl.cnf"
        /usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
            -config "$tmp/openssl.cnf" -keyout "$tmp/key.pem" -out "$tmp/cert.pem"
        /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
            -name "$identity" -passout pass:noty -out "$tmp/noty.p12"
        security import "$tmp/noty.p12" -k "$keychain" -P noty -T /usr/bin/codesign
    fi
    # codesign only uses identities the user trusts for code signing. macOS asks for your
    # password or Touch ID here.
    if ! security find-identity -v -p codesigning | grep -q "\"$identity\""; then
        security find-certificate -c "$identity" -p "$keychain" > "$tmp/trusted.pem"
        security add-trusted-cert -p codeSign -k "$keychain" "$tmp/trusted.pem"
    fi
    printf 'CODE_SIGN_STYLE = Manual\nCODE_SIGN_IDENTITY = %s\n' "$identity" > Config/Signing.local.xcconfig
    echo "Signing identity ready: $identity (Config/Signing.local.xcconfig written)"
