# Stop on first error
$ErrorActionPreference = 'Stop'

#############################################
# CONFIG
#############################################

$ProjectRepo = if ($env:PROJECT_REPO) { $env:PROJECT_REPO } else { 'git@github.com:ezpartyphdev/ezpartyph-flutter.git' }
$ProjectDir = if ($env:PROJECT_DIR) { $env:PROJECT_DIR } else { (Join-Path (Get-Location).Path 'ezpartyph-flutter') }
$SecretsBaseUrl = if ($env:SECRETS_BASE_URL) { $env:SECRETS_BASE_URL } else { 'https://secrets.example.com/mobile' }
$SecretsToken = if ($env:SECRETS_TOKEN) { $env:SECRETS_TOKEN } else { '' }

$AndroidSdkRoot = Join-Path $env:USERPROFILE "Android\Sdk"
$AndroidPlatform = "android-34"
$SystemImage = "system-images;android-34;google_apis;arm64-v8a"

#############################################
# HELPERS
#############################################

function Log { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Error {
    param($Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

#############################################
# CHOCOLATEY INSTALLATION
#############################################
function Ensure-Chocolatey {
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Log "Chocolatey is already installed."
        return
    }

    Log "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force;
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;
    try {
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    } catch {
        Error "Failed to install Chocolatey. Please check your internet connection and PowerShell permissions."
    }

    $env:Path += ";$env:ProgramData\chocolatey\bin"
}

#############################################
# CORE DEPENDENCIES
#############################################
function Install-CorePackages {
    Log "Installing core system dependencies via Chocolatey..."
    Ensure-Chocolatey

    # Note: Flutter for Windows desktop development requires Visual Studio.
    # This can be installed with: choco install visualstudio2022-workload-nativedesktop -y
    # It is a large download and is omitted here to focus on Android setup.
    choco install -y git jq openjdk17
}

#############################################
# CLONE PROJECT
#############################################
function Clone-Project {
    # Use Join-Path for robust path building
    $gitDir = Join-Path $ProjectDir ".git"

    if (-not (Test-Path -Path $gitDir)) {
        Log "Cloning project..."

        # --- First Attempt ---
        git clone "$ProjectRepo" "$ProjectDir"

        # Check the exit code of the last external command
        if ($LASTEXITCODE -eq 0) {
            Log "Clone successful."
            return 0 # Success
        }

        # --- If we are here, the clone failed ---
        Log "-----------------------------------------------------"
        Error "ERROR: Failed to clone the repository via SSH."
        Log "This might be because your SSH key isn't added to the ssh-agent."

        # Interactive prompt using Read-Host
        $choice = Read-Host -Prompt "Do you want to try adding your key now? [Y/n]"

        # Check if choice is 'Y', 'y', or empty (just pressed Enter)
        if (($choice -match '^[Yy]$') -or ([string]::IsNullOrEmpty($choice))) {

            # Get key filename from user
            $key_file = Read-Host -Prompt "Enter your private key filename (default: id_ed25519)"
            
            # Set default if user pressed Enter
            if ([string]::IsNullOrEmpty($key_file)) {
                $key_file = "id_ed25519"
            }
            
            $key_path = Join-Path $HOME ".ssh" $key_file

            if (-not (Test-Path -Path $key_path -PathType Leaf)) {
                Error "ERROR: File not found: $key_path"
                Log "Please add your key manually and re-run."
                return 1
            }

            Log "Starting ssh-agent..."
            try {
                # Start the agent (requires OpenSSH Client feature to be installed on Windows)
                Start-SshAgent -ErrorAction Stop
            } catch {
                Error "Failed to start ssh-agent. Please ensure the OpenSSH Client is installed."
                return 1
            }

            Log "Adding key: $key_path"
            ssh-add $key_path

            if ($LASTEXITCODE -ne 0) {
                Error "Failed to add key. (Did you enter the correct passphrase?)"
                return 1
            }

            Log "Key added successfully. Retrying clone..."

            # --- Second Attempt ---
            git clone "$ProjectRepo" "$ProjectDir"

            if ($LASTEXITCODE -eq 0) {
                Log "Clone successful on the second attempt!"
            } else {
                Error "ERROR: Clone failed again."
                Log "Please check your repository URL and key permissions."
                return 1
            }

        } else {
            # User pressed 'N' or any other key
            Log "Okay. Please add your SSH key manually and re-run the script."
            Log "1. Start-SshAgent"
            Log "2. ssh-add ~\.ssh\[YOUR_KEY_FILE]"
            return 1 # Return a failure status
        }

    } else {
        Log "Project already exists."
    }
}

#############################################
# DETECT FLUTTER VERSION
#############################################
function Detect-FlutterVersion {
    $configFile = Join-Path $ProjectDir ".fvm/fvm_config.json"
    if (Test-Path $configFile) {
        $config = Get-Content $configFile | ConvertFrom-Json
        $script:FlutterVersion = $config.flutterSdkVersion
    } else {
        Warn "No .fvm/fvm_config.json found. Using fallback version."
        $script:FlutterVersion = "3.32.6"
    }
    Log "Using Flutter version: $script:FlutterVersion"
}

#############################################
# INSTALL DART & FVM
#############################################
function Install-DartFvm {
    Log "Installing Dart..."
    choco install dart-sdk -y

    Log "Installing FVM..."
    $pubCachePath = Join-Path $env:APPDATA "Pub\Cache\bin"
    if ($env:PATH -notlike "*$pubCachePath*") {
        $env:PATH += ";$pubCachePath"
        [System.Environment]::SetEnvironmentVariable('PATH', $env:PATH, [System.EnvironmentVariableTarget]::User)
        Log "Added Pub Cache to your user PATH. Please restart your terminal for it to take effect."
    }

    dart pub global activate fvm
}

#############################################
# INSTALL FLUTTER (FVM)
#############################################
function Install-Flutter {
    Log "Installing Flutter via FVM..."
    Push-Location $ProjectDir
    fvm install $script:FlutterVersion
    fvm use $script:FlutterVersion
    Pop-Location

    $flutterSdkPath = Join-Path $ProjectDir ".fvm\flutter_sdk\bin"
    if ($env:PATH -notlike "*$flutterSdkPath*") {
        $env:PATH += ";$flutterSdkPath"
        [System.Environment]::SetEnvironmentVariable('PATH', $env:PATH, [System.EnvironmentVariableTarget]::User)
        Log "Added Flutter SDK to your user PATH. Please restart your terminal for it to take effect."
    }
}

#############################################
# ANDROID SDK HELPERS
#############################################
function Get-AndroidSdkManagerPath {
    $sdkManagerName = "sdkmanager.bat"
    $path1 = Join-Path $AndroidSdkRoot "cmdline-tools\latest\bin\$sdkManagerName"
    $path2 = Join-Path $AndroidSdkRoot "cmdline-tools\latest\cmdline-tools\bin\$sdkManagerName"

    if (Test-Path $path1) { return $path1 }
    if (Test-Path $path2) { return $path2 }
    return $null
}

function Test-AndroidSdkExists {
    if (-not(Test-Path -Path (Join-Path $AndroidSdkRoot "platform-tools\adb.exe"))) { return $false }
    if ((Get-AndroidSdkManagerPath) -eq $null) { return $false }
    return $true
}

function Add-AndroidSdkToPath {
    $platformTools = Join-Path $AndroidSdkRoot "platform-tools"
    $cmdlineTools = (Get-AndroidSdkManagerPath) | Split-Path

    if ($env:PATH -notlike "*$platformTools*") { $env:PATH += ";$platformTools" }
    if ($env:PATH -notlike "*$cmdlineTools*") { $env:PATH += ";$cmdlineTools" }
}

#############################################
# INSTALL ANDROID SDK
#############################################
function Install-AndroidSdk {
    if (Test-AndroidSdkExists) {
        Log "Android SDK already installed — skipping."
        Add-AndroidSdkToPath
        return
    }

    Log "Installing Android SDK..."
    $cmdlineToolsDir = Join-Path $AndroidSdkRoot "cmdline-tools"
    New-Item -Path $cmdlineToolsDir -ItemType Directory -Force | Out-Null

    $tempDir = Join-Path $cmdlineToolsDir "temp"
    $zipFile = Join-Path $tempDir "tools.zip"
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

    $toolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip"
    Invoke-WebRequest -Uri $toolsUrl -OutFile $zipFile
    Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force
    Remove-Item $zipFile

    $latestDir = Join-Path $cmdlineToolsDir "latest"
    $extractedDir = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
    if ($extractedDir) {
        Move-Item -Path $extractedDir.FullName -Destination $latestDir
    } else {
        Error "Unknown Android cmdline-tools ZIP structure."
    }
    Remove-Item -Path $tempDir -Recurse

    Add-AndroidSdkToPath

    $sdkManager = Get-AndroidSdkManagerPath
    Log "Accepting Android SDK licenses..."
    # Pipe 'y' multiple times to accept all licenses
    (1..10 | ForEach-Object { 'y' }) | & $sdkManager --licenses | Out-Null

    Log "Installing SDK components..."
    & $sdkManager --install "platform-tools" "platforms;$AndroidPlatform" "build-tools;34.0.0" "cmdline-tools;latest" "$SystemImage"

    Log "Android SDK installed."
}

#############################################
# GENERATE DEBUG KEYSTORE
#############################################
function Generate-DebugKeystore {
    $keystore = Join-Path $env:USERPROFILE ".android\debug.keystore"

    if (Test-Path $keystore) { return }

    Log "Generating debug keystore..."
    New-Item -Path (Join-Path $env:USERPROFILE ".android") -ItemType Directory -Force | Out-Null

    $keytoolArgs = @(
        "-genkey", "-v",
        "-keystore", "`"$keystore`"",
        "-alias", "androiddebugkey",
        "-storepass", "android",
        "-keypass", "android",
        "-keyalg", "RSA", "-keysize", "2048",
        "-validity", "10000",
        "-dname", "`"CN=Android Debug,O=Android,C=US`""
    )

    & keytool $keytoolArgs
}

#############################################
# BOOTSTRAP FLUTTER PROJECT
#############################################
function Bootstrap-Flutter {
    Push-Location $ProjectDir
    fvm flutter pub get
    try {
        fvm flutter build apk --debug
    } catch {
        Warn "Initial debug build failed. This can sometimes happen, continuing..."
    }
    fvm flutter doctor
    Pop-Location
}

#############################################
# MAIN
#############################################
function Main {
    Log "🚀 Starting Full Flutter + Android Setup for Windows"

    Install-CorePackages
    Clone-Project
    Detect-FlutterVersion
    Install-DartFvm
    Install-Flutter
    Install-AndroidSdk
    Generate-DebugKeystore
    Bootstrap-Flutter

    Log "🎉 Setup complete! Ready to develop!"
    Warn "Please restart your terminal/shell to ensure all PATH changes are applied."
}

Main
