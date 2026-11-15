#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS builds require macOS and Xcode. Run this script on a Mac." >&2
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter was not found. Install Flutter and add it to PATH." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode command-line tools were not found. Install Xcode and run xcode-select --install." >&2
  exit 1
fi

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [https://server.example.com:8443]" >&2
  exit 2
fi

server_url="${1:-}"
if [[ -z "$server_url" ]]; then
  read -r -p "HTTPS chat server URL (for example https://192.168.1.14:8443): " server_url
fi

encoded_server_url="$(
  python3 -c '
import base64
import sys
import urllib.parse

value = sys.argv[1]
parsed = urllib.parse.urlsplit(value)
try:
    valid_port = parsed.port is None or 1 <= parsed.port <= 65535
except ValueError:
    valid_port = False
if (
    parsed.scheme != "https"
    or not parsed.netloc
    or parsed.username is not None
    or parsed.password is not None
    or parsed.path not in ("", "/")
    or parsed.query
    or parsed.fragment
    or not valid_port
):
    raise SystemExit("Server URL must be an HTTPS origin, such as https://chat.example.com:8443.")
encoded = bytes(byte ^ 0x5A for byte in value.encode("utf-8"))
print(base64.b64encode(encoded).decode("ascii"))
' "$server_url"
)"

cd "$project_root"
flutter pub get
flutter build ipa \
  --release \
  --target lib/main_client.dart \
  --build-name 0.1.2 \
  "--dart-define=CLIENT_SERVER_URL_XOR_B64=$encoded_server_url"

shopt -s nullglob
ipa_files=("$project_root"/build/ios/ipa/*.ipa)
if [[ "${#ipa_files[@]}" -eq 0 ]]; then
  echo "Flutter completed without producing an IPA in build/ios/ipa." >&2
  exit 1
fi

output_dir="$project_root/dist/ConsentChat-iOS"
mkdir -p "$output_dir"
cp -f "${ipa_files[0]}" "$output_dir/ConsentChat-Client.ipa"
echo "iOS client IPA is ready: $output_dir/ConsentChat-Client.ipa"
