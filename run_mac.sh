#!/bin/bash
# One-shot setup + run for Card Reader on macOS.
set -e
cd "$(dirname "$0")"

echo "== Checking tools =="
command -v flutter >/dev/null || { echo "Flutter not found on PATH. Install from https://docs.flutter.dev/get-started/install/macos"; exit 1; }
command -v ollama  >/dev/null || { echo "Ollama not found. Install from https://ollama.com/download"; exit 1; }
echo "RAM: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"

echo "== Checking Ollama is running =="
if ! curl -s http://localhost:11434/api/tags >/dev/null; then
  echo "Starting Ollama..."
  (open -a Ollama 2>/dev/null || (ollama serve >/tmp/ollama.log 2>&1 &))
  for i in {1..20}; do curl -s http://localhost:11434/api/tags >/dev/null && break; sleep 1; done
fi

echo "== Checking for a Qwen vision model =="
if ! ollama list | grep -Eq 'qwen2\.5vl|qwen3-vl'; then
  echo "Downloading qwen2.5vl:7b (~6 GB, one time only)..."
  ollama pull qwen2.5vl:7b
fi
ollama list | grep -E 'qwen2\.5vl|qwen3-vl'

echo "== Generating macOS project files (keeps existing lib/ and pubspec.yaml) =="
if [ ! -d macos ]; then
  flutter create --platforms=macos --project-name card_reader --org com.example .
  rm -f test/widget_test.dart
fi

echo "== Allowing network + file picker in the macOS sandbox =="
for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.network.client bool true" "$f" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :com.apple.security.network.client true" "$f"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-write bool true" "$f" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :com.apple.security.files.user-selected.read-write true" "$f"
done

# Turn off the App Sandbox so results can be saved next to the scanned PDF.
for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  /usr/libexec/PlistBuddy -c "Set :com.apple.security.app-sandbox false" "$f" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool false" "$f"
done

echo "== Installing packages =="
flutter pub get

echo "== Fixing macOS minimum version (Xcode needs 12.0+) =="
fix_targets() {
  sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 10\.[0-9]*;/MACOSX_DEPLOYMENT_TARGET = 12.0;/g' macos/Runner.xcodeproj/project.pbxproj
  [ -f macos/Podfile ] && sed -i '' "s/^platform :osx, '10\.[0-9]*'/platform :osx, '12.0'/" macos/Podfile
  return 0
}
fix_targets

echo "== Launching app =="
if ! flutter run -d macos; then
  echo "== Build failed; re-applying version fix and retrying once =="
  fix_targets
  (cd macos && pod install >/dev/null 2>&1 || true)
  flutter run -d macos
fi
