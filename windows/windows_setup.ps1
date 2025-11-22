# Stop on error generally, but handle specific failures gracefully
# We want to fail fast if something breaks rather than cascading errors.
$ErrorActionPreference = 'Stop'

# ==============================================================================
# 📝 CONFIGURATION (ACTION REQUIRED)
# ==============================================================================
# INSTRUCTIONS:
# 1. Open this file in a text editor (Notepad / VS Code).
# 2. Paste your Git Repository URL inside the quotes below.
#
# OPTIONS:
# A) SSH (Recommended): "git@github.com:ezpartyphdev/ezpartyph-flutter.git"
# B) HTTPS (Token):     "https://<YOUR_TOKEN>@github.com/ezpartyphdev/ezpartyph-flutter.git"
# ==============================================================================

$ProjectRepo = ""

# 1. CHECK: Did the user edit the config?
# Prevent running the script blindly without setting the repo first.
if ([string]::IsNullOrWhiteSpace($ProjectRepo)) {
    Clear-Host
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host " 🛑 STOP: CONFIGURATION MISSING" -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "You must edit this script file before running it." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Right-click this file -> Edit." -ForegroundColor White
    Write-Host "2. Scroll to the top." -ForegroundColor White
    Write-Host "3. Paste your Repo URL into: `$ProjectRepo = `"...`"" -ForegroundColor Green
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    exit 1
}

# Check for Admin rights. We need this for Chocolatey and Environment Variables.
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] You are NOT running as Administrator." -ForegroundColor Red
    Write-Host "Please close this window, right-click PowerShell, and select 'Run as Administrator'." -ForegroundColor Yellow
    exit 1
}

# 2. Best Effort Cleanup
# Try to clean up stale temp files from previous failed runs to avoid "File Locked" errors.
# We wrap this in a try/catch so the script doesn't crash if a file is currently in use.
$chocoTemp = Join-Path $env:TEMP "chocolatey"
if (Test-Path $chocoTemp) {
    try {
        Remove-Item $chocoTemp -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "[WARN] Cleaning temp files skipped (files locked). Proceeding..." -ForegroundColor Yellow
    }
}

#############################################
# CONFIGURATION
#############################################

# Note: The $ProjectRepo variable is set at the very top of the file.

# Defaults for the project structure and Flutter version
$ProjectDir      = if ($env:PROJECT_DIR) { $env:PROJECT_DIR } else { (Join-Path (Get-Location).Path 'ezpartyph-flutter') }
$DefaultFlutter  = "3.32.6"

# Android SDK config - targeted for Android 14 (API 34)
$AndroidSdkRoot  = Join-Path $env:USERPROFILE "Android\Sdk"
$AndroidPlatform = "android-34"
$SystemImage     = "system-images;android-34;google_apis;arm64-v8a"

#############################################
# HELPERS
#############################################

function Log { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Error { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red; exit 1 }

#############################################
# 1. CHOCOLATEY & CORE TOOLS
#############################################

function Ensure-Chocolatey {
    $chocoDir = "$env:ProgramData\chocolatey"
    $chocoExe = "$chocoDir\bin\choco.exe"

    # Corruption Check: If the folder exists but the exe is missing, nuke it and reinstall.
    if ((Test-Path $chocoDir) -and -not (Test-Path $chocoExe)) {
        Warn "Corrupted Chocolatey detected. Removing..."
        Remove-Item $chocoDir -Recurse -Force
    }

    # Install if missing using the official one-liner
    if (-not (Test-Path $chocoExe)) {
        Log "Installing Chocolatey..."
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        try {
            $script = (New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')
            Invoke-Expression $script
        } catch {
            Error "Chocolatey download failed. Check internet connection."
        }
    } else {
        Log "Chocolatey is already installed."
    }

    # Add to PATH immediately so we can use it in the next step
    if ($env:Path -notlike "*$chocoDir\bin*") { $env:Path += ";$chocoDir\bin" }
}

function Install-CorePackages {
    Log "Installing core tools..."
    Ensure-Chocolatey

    # Force use of the full path to avoid path refresh issues
    $choco = if (Test-Path "$env:ProgramData\chocolatey\bin\choco.exe") { "$env:ProgramData\chocolatey\bin\choco.exe" } else { "choco" }
    
    # Install Git, JQ, Java (OpenJDK 17), and Dart
    & $choco install -y git jq openjdk17 dart-sdk
}

#############################################
# 2. CLONE PROJECT
#############################################

function Clone-Project {
    $gitDir = Join-Path $ProjectDir ".git"
    if (Test-Path $gitDir) { Log "Project already cloned."; return }

    # --- FIX: Check if Git is loaded ---
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
        Log "Git installed but not found. Refreshing Environment Variables..."
        
        # Reload the PATH from the Registry
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        
        # Check again
        if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
            # Last ditch effort: Look for default Chocolatey install path
            $gitPath = "C:\Program Files\Git\cmd\git.exe"
            if (Test-Path $gitPath) {
                Set-Alias -Name git -Value $gitPath -Scope Process
                Log "Found Git manually."
            } else {
                Error "Git is installed but PowerShell cannot see it. Please RESTART TERMINAL."
            }
        }
    }

    Log "Cloning project from: $ProjectRepo"
    
    git clone "$ProjectRepo" "$ProjectDir"

    if ($LASTEXITCODE -ne 0) {
        Log "-----------------------------------------------------"
        Warn "Clone failed! Access was denied."
        Write-Host "HOW TO FIX:" -ForegroundColor Cyan
        Write-Host "1. Check the `$ProjectRepo URL at the top of this script." -ForegroundColor White
        Write-Host "2. If using SSH: Ensure key is added (ssh-add)." -ForegroundColor White
        Write-Host "3. If using Token: Ensure the token in the URL is correct." -ForegroundColor White
        Error "Setup stopped."
    }
}


#############################################
# 3. DART & FVM
#############################################

function Install-Fvm {
    Log "Configuring FVM..."

    # Ensure Dart is in Path
    $dartBin = "C:\tools\dart-sdk\bin"
    if ($env:Path -notlike "*$dartBin*") { $env:Path += ";$dartBin" }

    # Soft check: sometimes Windows registry hasn't updated the environment variables yet
    if (-not (Get-Command "dart" -ErrorAction SilentlyContinue)) {
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        if (-not (Get-Command "dart" -ErrorAction SilentlyContinue)) {
             Error "Dart is installed but not visible. Please RESTART TERMINAL and run script again."
        }
    }

    Log "Activating FVM..."
    dart pub global activate fvm

    # Add the Pub Cache (where FVM lives) to the user PATH
    $pubCache = Join-Path $env:LOCALAPPDATA "Pub\Cache\bin"
    if ($env:Path -notlike "*$pubCache*") { 
        $env:Path += ";$pubCache"
        [System.Environment]::SetEnvironmentVariable('PATH', $env:PATH, [System.EnvironmentVariableTarget]::User)
    }
}

#############################################
# 4. FLUTTER INSTALLATION
#############################################

function Install-Flutter {
    Log "Setting up Flutter..."
    
    # Detect Version from the project's config file so everyone is on the same version
    $configPath = Join-Path $ProjectDir ".fvm/fvm_config.json"
    $version = $DefaultFlutter
    
    if (Test-Path $configPath) {
        try {
            $json = Get-Content $configPath | ConvertFrom-Json
            $version = $json.flutterSdkVersion
            Log "Detected Flutter version: $version"
        } catch {
            Warn "Config error. Using default: $version"
        }
    }

    $fvmBat = Join-Path $env:LOCALAPPDATA "Pub\Cache\bin\fvm.bat"
    
    Push-Location $ProjectDir
    & $fvmBat install $version
    & $fvmBat use $version
    Pop-Location
    
    # Add the specific Flutter SDK version to Path
    $flutterSdk = Join-Path $ProjectDir ".fvm\flutter_sdk\bin"
    if ($env:Path -notlike "*$flutterSdk*") {
        $env:Path += ";$flutterSdk"
        [System.Environment]::SetEnvironmentVariable('PATH', $env:PATH, [System.EnvironmentVariableTarget]::User)
    }
}

#############################################
# 5. ANDROID SDK
#############################################

function Install-AndroidSdk {
    # 1. Check if installed
    if (Test-Path (Join-Path $AndroidSdkRoot "platform-tools\adb.exe")) {
        Log "Android SDK installed."
        # Ensure Env Var is set even if already installed (common issue on fresh machines)
        [System.Environment]::SetEnvironmentVariable('ANDROID_HOME', $AndroidSdkRoot, [System.EnvironmentVariableTarget]::User)
        $env:ANDROID_HOME = $AndroidSdkRoot
        return
    }

    Log "Installing Android SDK..."
    $cmdlineTools = Join-Path $AndroidSdkRoot "cmdline-tools"
    $tempDir      = Join-Path $cmdlineTools "temp"
    $zipPath      = Join-Path $tempDir "tools.zip"
    
    # 2. Prep Directories (Clean slate to avoid conflicts)
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

    # 3. Download (Fast Mode)
    # CRITICAL: We disable the progress bar here. PowerShell's progress bar rendering
    # is extremely slow and can increase download time from seconds to minutes.
    Log "Downloading SDK tools (Progress bar hidden for speed)..."
    $url = "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $zipPath
    $ProgressPreference = 'Continue'
    
    # 4. Extract & Organize
    # The Google zip structure is weird, so we extract and move it to the correct "latest" folder.
    Log "Extracting..."
    Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
    
    $inner = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
    $latest = Join-Path $cmdlineTools "latest"
    if (Test-Path $latest) { Remove-Item $latest -Recurse -Force -ErrorAction SilentlyContinue }
    Move-Item -Path $inner.FullName -Destination $latest
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    # 5. Set Paths & Env Vars (CRITICAL FIX)
    $sdkBin = Join-Path $latest "bin"
    $env:Path += ";$sdkBin"
    
    Log "Setting ANDROID_HOME..."
    [System.Environment]::SetEnvironmentVariable('ANDROID_HOME', $AndroidSdkRoot, [System.EnvironmentVariableTarget]::User)
    $env:ANDROID_HOME = $AndroidSdkRoot

    # 6. Install Components
    Log "Accepting Licenses & Installing Components..."
    $sdkManager = Join-Path $sdkBin "sdkmanager.bat"
    
    # Automatically accept licenses (pipes 'y' to the prompt)
    (1..10 | ForEach-Object { 'y' }) | & $sdkManager --licenses | Out-Null

    $sdkArgs = @(
        "--install",
        "platform-tools",
        "platforms;$AndroidPlatform",
        "build-tools;34.0.0",
        "cmdline-tools;latest",
        "$SystemImage"
    )
    & $sdkManager $sdkArgs
}

#############################################
# 6. DEBUG KEYSTORE
#############################################

function Generate-Keystore {
    $keystorePath = Join-Path $env:USERPROFILE ".android\debug.keystore"
    if (Test-Path $keystorePath) { 
        Log "Debug keystore already exists."
        return 
    }

    Log "Generating Keystore..."
    New-Item -Path (Join-Path $env:USERPROFILE ".android") -ItemType Directory -Force | Out-Null

    # PATH FIX: Find Keytool
    # Sometimes Java installs but isn't in the PATH for the current session yet.
    $keytoolExe = "keytool"
    if (-not (Get-Command "keytool" -ErrorAction SilentlyContinue)) {
        Log "Refeshing PATH for Java..."
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    }

    # Fallback search: Look in common install locations if PATH fails
    if (-not (Get-Command "keytool" -ErrorAction SilentlyContinue)) {
        $manualPath = Get-ChildItem "C:\Program Files\Eclipse Adoptium" -Filter "keytool.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
        if ($manualPath) { $keytoolExe = $manualPath } 
        else {
            Warn "Could not find 'keytool'. Skipping keystore generation."
            return
        }
    }

    $keytoolArgs = @(
        "-genkey", "-v", "-keystore", "`"$keystorePath`"",
        "-alias", "androiddebugkey", "-storepass", "android",
        "-keypass", "android", "-keyalg", "RSA", "-keysize", "2048",
        "-validity", "10000", "-dname", "`"CN=Android Debug,O=Android,C=US`""
    )
    & $keytoolExe $keytoolArgs
}

#############################################
# 7. FINAL VERIFICATION
#############################################

function Verify-Setup {
    Log "Finalizing Configuration..."
    Push-Location $ProjectDir
    
    # CRITICAL FIX: Tell Flutter where the Android SDK is explicitly
    Log "Linking Android SDK to Flutter..."
    fvm flutter config --android-sdk $AndroidSdkRoot
    
    # Ensure dependencies are fetched
    fvm flutter pub get
    
    # Run Doctor to give the user a summary
    Log "Running Flutter Doctor..."
    fvm flutter doctor
    
    Pop-Location
}

#############################################
# MAIN
#############################################

function Main {
    Log "🚀 STARTING SETUP"
    
    Install-CorePackages
    Clone-Project
    Install-Fvm
    Install-Flutter
    Install-AndroidSdk
    Generate-Keystore
    Verify-Setup
    
    Log "🎉 SETUP COMPLETE!"
    Warn "Please restart your terminal to ensure all changes stick."
}

Main