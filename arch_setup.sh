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
  sudo pacman -Syu --noconfirm \
    curl wget unzip zip git jq \
    gnupg \
    base-devel \
    gtk3 clang cmake ninja \
    jdk17-openjdk
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

    # First attempt to clone
    if git clone "$PROJECT_REPO" "$PROJECT_DIR"; then
      log "Clone successful."
      return 0 # Success
    fi

    # --- If we are here, the clone failed ---
    log "-----------------------------------------------------"
    log "ERROR: Failed to clone the repository via SSH."
    log "This might be because your SSH key isn't added to the ssh-agent."

    # Interactive prompt:
    # -p "..." : Displays the prompt text
    # -n 1 : Reads only 1 character
    # -r : Prevents backslash from being an escape character
    # choice : The variable to store the input
    read -p "Do you want to try adding your key now? [Y/n] " -n 1 -r choice
    echo # Move to a new line after the user input

    # Check if the choice is 'Y', 'y', or just Enter (empty)
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then

      # Get key filename from user
      read -p "Enter your private key filename (default: id_ed25519): " key_file
      
      # Set a default if the user just pressed Enter
      key_file=${key_file:-id_ed25519}
      local key_path="$HOME/.ssh/$key_file"

      if [[ ! -f "$key_path" ]]; then
        log "ERROR: File not found: $key_path"
        log "Please add your key manually and re-run."
        return 1
      fi

      log "Starting ssh-agent..."
      eval "$(ssh-agent -s)"

      log "Adding key: $key_path"
      if ! ssh-add "$key_path"; then
        log "Failed to add key. (Did you enter the correct passphrase?)"
        return 1
      fi

      log "Key added successfully. Retrying clone..."
      
      # Second attempt to clone
      if git clone "$PROJECT_REPO" "$PROJECT_DIR"; then
        log "Clone successful on the second attempt!"
      else
        log "ERROR: Clone failed again."
        log "Please check your repository URL and key permissions."
        return 1
      fi

    else
      # User pressed 'N', 'n', or any other key
      log "Okay. Please add your SSH key manually and re-run the script."
      log '1. eval "$(ssh-agent -s)"'
      log '2. ssh-add ~/.ssh/[YOUR_KEY_FILE]'
      return 1 # Return a failure status
    fi

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
  sudo pacman -S --noconfirm --needed dart

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
