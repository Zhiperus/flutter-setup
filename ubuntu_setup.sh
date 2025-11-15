#!/usr/bin/env bash
set -euo pipefail

#############################################
# CONFIG
#############################################

PROJECT_REPO="${PROJECT_REPO:-git@github.com:ezpartyphdev/ezpartyph-flutter.git}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)/ezpartyph-flutter}"
SECRETS_BASE_URL="${SECRETS_BASE_URL:-https://secrets.example.com/mobile}"
SECRETS_TOKEN="${SECRETS_TOKEN:-}"

ANDROID_SDK_ROOT="$HOME/Android/Sdk"
ANDROID_PLATFORM="android-34"
SYSTEM_IMAGE="system-images;android-34;google_apis;arm64-v8a"

#############################################
# HELPERS
#############################################

log() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
error() {
  echo -e "\e[31m[ERROR]\e[0m $*"
  exit 1
}

#############################################
# CORE DEPENDENCIES
#############################################
install_core_packages() {
  log "Installing core system dependencies..."
  sudo apt update
  sudo apt install -y \
    curl wget unzip zip git jq \
    apt-transport-https ca-certificates gnupg \
    build-essential \
    libgtk-3-dev clang cmake ninja-build pkg-config \
    openjdk-17-jdk
}

#############################################
# SWAP CREATION (SAFE)
#############################################
ensure_swap() {
  local swapsize
  swapsize=$(free | awk '/Swap:/ {print $2}')

  if [[ "$swapsize" -lt 2097152 ]]; then
    log "Adding 2GB swap..."
    sudo dd if=/dev/zero of=/myswap bs=1M count=2048
    sudo chmod 600 /myswap
    sudo mkswap /myswap
    sudo swapon /myswap
    echo "/myswap none swap sw 0 0" | sudo tee -a /etc/fstab
  else
    log "Swap exists — skipping."
  fi
}

#############################################
# CLONE PROJECT
#############################################
clone_project() {
  if [[ ! -d "$PROJECT_DIR/.git" ]]; then
    log "Cloning project..."
    git clone "$PROJECT_REPO" "$PROJECT_DIR"
  else
    log "Project already exists."
  fi
}

#############################################
# DETECT FLUTTER VERSION
#############################################
detect_flutter_version() {
  local config="$PROJECT_DIR/.fvm/fvm_config.json"
  if [[ -f "$config" ]]; then
    FLUTTER_VERSION=$(jq -r '.flutterSdkVersion' "$config")
  else
    warn "No .fvm/fvm_config.json found. Using fallback version."
    FLUTTER_VERSION="3.32.6"
  fi
  log "Using Flutter version: $FLUTTER_VERSION"
}

#############################################
# INSTALL DART & FVM
#############################################
install_dart_fvm() {
  log "Installing Dart..."

  sudo apt install -y apt-transport-https

  wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub |
    gpg --dearmor | sudo tee /usr/share/keyrings/dart.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/dart.gpg] \
https://storage.googleapis.com/download.dartlang.org/linux/debian stable main" |
    sudo tee /etc/apt/sources.list.d/dart_stable.list

  sudo apt update && sudo apt install -y dart

  log "Installing FVM..."

  export PATH="$HOME/.pub-cache/bin:$PATH"
  dart pub global activate fvm

  # Persistent PATH
  if ! grep -q ".pub-cache/bin" ~/.bashrc; then
    echo 'export PATH="$HOME/.pub-cache/bin:$PATH"' >>~/.bashrc
  fi
}

#############################################
# INSTALL FLUTTER (FVM)
#############################################
install_flutter() {
  log "Installing Flutter via FVM..."
  pushd "$PROJECT_DIR" >/dev/null
  fvm install "$FLUTTER_VERSION"
  fvm use "$FLUTTER_VERSION"
  popd >/dev/null

  export PATH="$PROJECT_DIR/.fvm/flutter_sdk/bin:$PATH"

  if ! grep -q ".fvm/flutter_sdk/bin" ~/.bashrc; then
    echo "export PATH=\"$PROJECT_DIR/.fvm/flutter_sdk/bin:\$PATH\"" >>~/.bashrc
  fi
}

#############################################
# ANDROID SDK DETECTION
#############################################
android_sdk_exists() {
  [[ -x "$ANDROID_SDK_ROOT/platform-tools/adb" ]] || return 1

  [[ -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]] && return 0
  [[ -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/cmdline-tools/bin/sdkmanager" ]] && return 0

  return 1
}

#############################################
# INSTALL ANDROID SDK
#############################################
install_android_sdk() {

  if android_sdk_exists; then
    log "Android SDK already installed — skipping."
    return
  fi

  log "Installing Android SDK..."

  mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"

  pushd "$ANDROID_SDK_ROOT/cmdline-tools" >/dev/null
  curl -LO "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  rm -rf temp latest
  mkdir temp
  unzip -q commandlinetools-linux*.zip -d temp
  rm commandlinetools-linux*.zip
  popd >/dev/null

  # Fix folder structure
  if [[ -d "$ANDROID_SDK_ROOT/cmdline-tools/temp/cmdline-tools" ]]; then
    mv "$ANDROID_SDK_ROOT/cmdline-tools/temp/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  elif [[ -d "$ANDROID_SDK_ROOT/cmdline-tools/temp/tools" ]]; then
    mv "$ANDROID_SDK_ROOT/cmdline-tools/temp/tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  else
    error "Unknown Android cmdline-tools ZIP structure."
  fi

  rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/temp"

  export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"

  yes | sdkmanager --licenses || warn "License auto-accept failed"

  sdkmanager --install \
    "platform-tools" \
    "platforms;$ANDROID_PLATFORM" \
    "build-tools;34.0.0" \
    "cmdline-tools;latest" \
    "$SYSTEM_IMAGE"

  log "Android SDK installed."
}

#############################################
# GENERATE DEBUG KEYSTORE
#############################################
generate_debug_keystore() {
  local ks="$HOME/.android/debug.keystore"

  [[ -f "$ks" ]] && return

  mkdir -p "$HOME/.android"
  keytool -genkey -v \
    -keystore "$ks" \
    -alias androiddebugkey \
    -storepass android \
    -keypass android \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"
}

#############################################
# BOOTSTRAP FLUTTER PROJECT
#############################################
bootstrap_flutter() {
  pushd "$PROJECT_DIR" >/dev/null
  fvm flutter pub get
  fvm flutter build apk --debug || warn "Initial debug build failed"
  fvm flutter doctor
  popd >/dev/null
}

#############################################
# MAIN
#############################################
main() {
  log "🚀 Starting Full Flutter + Android Setup"

  install_core_packages
  ensure_swap
  clone_project
  detect_flutter_version
  install_dart_fvm
  install_flutter
  install_android_sdk
  generate_debug_keystore
  bootstrap_flutter

  log "🎉 Setup complete! Ready to develop!"
}

main "$@"
