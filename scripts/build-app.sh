#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=Debug
derived_data=''
signing_identity=''
team_id=''
typeset -a xcode_options signing_options
xcode_options=()
signing_options=()
while (( $# )); do
  case "$1" in
    --configuration|--derived-data|--signing-identity|--team-id)
      if (( $# < 2 )); then
        print -u2 -- "Missing value for $1"
        exit 2
      fi
      case "$1" in
        --configuration) configuration="$2" ;;
        --derived-data) derived_data="$2" ;;
        --signing-identity) signing_identity="$2" ;;
        --team-id) team_id="$2" ;;
      esac
      shift 2
      ;;
    --help)
      print -- 'Usage: scripts/build-app.sh [--configuration Debug|Release] [--derived-data PATH] [--signing-identity NAME_OR_SHA] [--team-id TEAM] [Xcode options]'
      print -- 'Release requires an explicitly supplied Developer ID Application identity for KBLA5ALX62.'
      exit 0
      ;;
    --) shift; xcode_options+=("$@"); break ;;
    *) xcode_options+=("$1"); shift ;;
  esac
done
if [[ "$configuration" != Debug && "$configuration" != Release ]]; then
  print -u2 -- 'Configuration must be Debug or Release.'
  exit 2
fi
for option in "${xcode_options[@]}"; do
  case "$option" in
    -configuration|-derivedDataPath)
      print -u2 -- "Use --configuration or --derived-data instead of $option"
      exit 2
      ;;
  esac
done
if [[ "$configuration" == Release ]]; then
  if [[ -z "$signing_identity" || -z "$team_id" ]]; then
    print -u2 -- 'Release requires --signing-identity and --team-id; no identity is selected automatically.'
    exit 2
  fi
  for option in "${xcode_options[@]}"; do
    case "$option" in
      -configuration|-derivedDataPath|DEVELOPMENT_TEAM=*|CODE_SIGN_IDENTITY=*|CODE_SIGNING_ALLOWED=*|CODE_SIGN_INJECT_BASE_ENTITLEMENTS=*|OTHER_CODE_SIGN_FLAGS=*|SWIFT_ACTIVE_COMPILATION_CONDITIONS=*|OTHER_SWIFT_FLAGS=*)
        print -u2 -- "Use the explicit Release options instead of overriding $option"
        exit 2
        ;;
    esac
  done
  /usr/bin/python3 scripts/package-release.py identity --identity "$signing_identity" --team-id "$team_id" --quiet
  signing_options=("CODE_SIGN_IDENTITY=$signing_identity" "DEVELOPMENT_TEAM=$team_id"
    'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO' 'OTHER_CODE_SIGN_FLAGS=--timestamp')
  [[ -n "$derived_data" ]] || derived_data=.build/release-app
else
  [[ -n "$derived_data" ]] || derived_data=.build/app
  [[ -z "$signing_identity" ]] || signing_options+=("CODE_SIGN_IDENTITY=$signing_identity")
  [[ -z "$team_id" ]] || signing_options+=("DEVELOPMENT_TEAM=$team_id")
fi
if [[ ! -f Spillcheck.xcodeproj/project.pbxproj || project.yml -nt Spillcheck.xcodeproj/project.pbxproj ]]; then
  xcodegen generate --spec project.yml
fi
xcodebuild -quiet -project Spillcheck.xcodeproj -scheme Spillcheck -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" \
  "${signing_options[@]}" "${xcode_options[@]}"
print -- "Built $derived_data/Build/Products/$configuration/Spillcheck.app"
