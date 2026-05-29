param(
    [string]$ConfigPath = "$env:USERPROFILE\.suigit\config.json",
    [string]$File,        # single-file mode: upload this file then capture it
    [switch]$SkipDeploy,  # batch mode only: do not run project:deploy
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) {
    throw "SuiGit config not found at $ConfigPath. Create it with accountId, consumerKey, consumerSecret, tokenId, tokenSecret, restletScriptId, restletDeployId."
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# ---------- helpers ----------

function Get-OAuthHeader {
    param([string]$Method, [string]$Url, $Cfg)

    $nonce = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    $ts    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()

    $oauth = [ordered]@{
        oauth_consumer_key     = $Cfg.consumerKey
        oauth_nonce            = $nonce
        oauth_signature_method = 'HMAC-SHA256'
        oauth_timestamp        = $ts
        oauth_token            = $Cfg.tokenId
        oauth_version          = '1.0'
    }

    $uri = [Uri]$Url
    $queryPairs = @{}
    if ($uri.Query) {
        foreach ($p in $uri.Query.TrimStart('?').Split('&')) {
            $kv = $p.Split('=', 2)
            $queryPairs[[Uri]::UnescapeDataString($kv[0])] = [Uri]::UnescapeDataString($kv[1])
        }
    }

    $all = @{}
    foreach ($k in $oauth.Keys)      { $all[$k] = $oauth[$k] }
    foreach ($k in $queryPairs.Keys) { $all[$k] = $queryPairs[$k] }

    $paramStr = ($all.Keys | Sort-Object | ForEach-Object {
        "$([Uri]::EscapeDataString($_))=$([Uri]::EscapeDataString($all[$_]))"
    }) -join '&'

    $baseUrl = "$($uri.Scheme)://$($uri.Host)$($uri.AbsolutePath)"
    $sigBase = "$($Method.ToUpper())&$([Uri]::EscapeDataString($baseUrl))&$([Uri]::EscapeDataString($paramStr))"
    $key     = "$([Uri]::EscapeDataString($Cfg.consumerSecret))&$([Uri]::EscapeDataString($Cfg.tokenSecret))"

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [Text.Encoding]::UTF8.GetBytes($key)
    $sig = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($sigBase)))
    $oauth.oauth_signature = $sig

    # Realm must match Account ID exactly. Uppercase is the safe convention.
    $realm = $Cfg.accountId.ToUpper()
    $parts = @("realm=`"$realm`"")
    foreach ($k in $oauth.Keys) { $parts += "$k=`"$([Uri]::EscapeDataString($oauth[$k]))`"" }
    return "OAuth " + ($parts -join ',')
}

function Get-FnvHash {
    param([string]$Text)
    $h     = [uint64]2166136261   # FNV offset basis 0x811c9dc5
    $prime = [uint64]16777619     # FNV prime       0x01000193
    $mask  = [uint64]4294967295   # 32-bit mask     0xFFFFFFFF
    if ($Text) {
        foreach ($c in $Text.ToCharArray()) {
            $h = $h -bxor [uint64][int]$c
            $h = ($h * $prime) -band $mask
        }
    }
    return ('{0:x}:{1}' -f [uint32]$h, $Text.Length)
}

function Resolve-SuiteCloudCli {
    # Priority: global PATH, npm-global, VS Code extension bundle (newest version)
    $cli = Get-Command suitecloud -ErrorAction SilentlyContinue
    if ($cli) { return @{ Path = $cli.Source; UseNode = $false } }

    foreach ($c in @("$env:APPDATA\npm\suitecloud.cmd", "$env:APPDATA\npm\suitecloud.ps1")) {
        if (Test-Path $c) { return @{ Path = $c; UseNode = $false } }
    }

    $extGlob = "$env:USERPROFILE\.vscode\extensions\oracle.suitecloud-vscode-extension-*\node_modules\@oracle\suitecloud-cli\src\suitecloud.js"
    $bundled = Get-ChildItem $extGlob -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($bundled) { return @{ Path = $bundled.FullName; UseNode = $true } }

    return $null
}

function Invoke-SuiteCloud {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $cli = Resolve-SuiteCloudCli
    if (-not $cli) {
        throw "SuiteCloud CLI not found (checked PATH, %APPDATA%\npm, and VS Code extension bundle). Install globally with 'npm install -g @oracle/suitecloud-cli' or ensure the Oracle SuiteCloud VS Code extension is installed."
    }
    if ($cli.UseNode) {
        Write-Host "  CLI: node $($cli.Path) $($Arguments -join ' ')"
        & node $cli.Path @Arguments
    } else {
        Write-Host "  CLI: $($cli.Path) $($Arguments -join ' ')"
        & $cli.Path @Arguments
    }
    if ($LASTEXITCODE -ne 0) { throw "SuiteCloud CLI command failed (exit $LASTEXITCODE)" }
}

function Get-FileCabinetPath {
    param([Parameter(Mandatory)][string]$AbsolutePath)
    $workspace = (Get-Location).Path
    $fileCabinetRoot = Join-Path $workspace "src\FileCabinet"
    $absResolved = (Resolve-Path $AbsolutePath).Path
    if (-not $absResolved.StartsWith($fileCabinetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "File is not under src/FileCabinet/: $AbsolutePath"
    }
    $rel = $absResolved.Substring($fileCabinetRoot.Length).TrimStart('\','/').Replace('\','/')
    return '/' + $rel
}

function Send-ToRestlet {
    param([Parameter(Mandatory)][array]$Files, [string]$Author, [string]$Commit)

    $payload = @{
        files  = $Files
        author = $Author
        commit = $Commit
        source = 'vscode_push'
    } | ConvertTo-Json -Depth 5

    $accountHost = $cfg.accountId.ToLower().Replace('_','-')
    $base = "https://$accountHost.restlets.api.netsuite.com/app/site/hosting/restlet.nl"
    $url  = "${base}?script=$($cfg.restletScriptId)&deploy=$($cfg.restletDeployId)"

    if ($DryRun) {
        Write-Host "DRY RUN - would POST to $url"
        Write-Host $payload
        return
    }

    $auth = Get-OAuthHeader -Method POST -Url $url -Cfg $cfg

    Write-Host "POSTing $($Files.Count) file(s) to SuiGit RESTlet..."
    Write-Host "  URL: $url"
    try {
        $resp = Invoke-RestMethod -Method POST -Uri $url `
            -Headers @{ Authorization = $auth } `
            -ContentType 'application/json' `
            -Body $payload
        $resp | ConvertTo-Json -Depth 5
    } catch {
        $we = $_.Exception
        Write-Host "REQUEST FAILED" -ForegroundColor Red
        Write-Host "  HTTP status: $($we.Response.StatusCode.value__) $($we.Response.StatusDescription)"
        Write-Host "  WWW-Authenticate: $($we.Response.Headers['WWW-Authenticate'])"
        if ($we.Response) {
            $reader = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
            $respBody = $reader.ReadToEnd()
            $reader.Close()
            Write-Host "  Response body:"
            Write-Host $respBody
        }
        throw
    }
}

function Build-FilePayload {
    param([Parameter(Mandatory)][string]$AbsolutePath, [Parameter(Mandatory)][string]$LogicalPath)
    $body = Get-Content $AbsolutePath -Raw -Encoding UTF8
    if ($null -eq $body) { $body = '' }
    return @{
        path    = $LogicalPath
        content = $body
        hash    = Get-FnvHash $body
        size    = $body.Length
    }
}

# ---------- main ----------

$commit = (git rev-parse --short HEAD 2>$null)
if (-not $commit) { $commit = '' } else { $commit = $commit.Trim() }
$author = (git config user.email 2>$null)
if (-not $author) { $author = $env:USERNAME } else { $author = $author.Trim() }

# =====================================================================
# SINGLE-FILE MODE: upload one file via CLI (synchronous), then capture
# =====================================================================
if ($File) {
    if (-not (Test-Path $File)) { throw "File not found: $File" }

    $fcPath  = Get-FileCabinetPath $File
    $logical = $fcPath.TrimStart('/')
    Write-Host "SuiGit single-file push: $fcPath"

    # Step 1: upload via CLI, blocks until complete
    Invoke-SuiteCloud -Arguments @('file:upload', '--paths', $fcPath)

    # Step 2: capture (file is now guaranteed to be in NetSuite)
    $payload = @(Build-FilePayload -AbsolutePath $File -LogicalPath $logical)
    Send-ToRestlet -Files $payload -Author $author -Commit $commit
    exit 0
}

# =====================================================================
# BATCH MODE: detect changed files, optionally deploy, capture all
# =====================================================================

# 1. find changed files in src/FileCabinet/
$changed = @()
$statusLines = git status --porcelain 'src/FileCabinet/'
foreach ($line in $statusLines) {
    if (-not $line) { continue }
    $p = $line.Substring(3).Trim() -replace '^"|"$', ''
    if ($p -match ' -> ') { $p = ($p -split ' -> ', 2)[1] }
    if ($p) { $changed += $p }
}
if ($changed.Count -eq 0) {
    $commitCount = git rev-list --count HEAD
    if ($LASTEXITCODE -eq 0 -and [int]$commitCount -gt 1) {
        $changed = @(git diff --name-only 'HEAD~1' 'HEAD' -- 'src/FileCabinet/')
    }
}
if ($changed.Count -eq 0) {
    Write-Host "No FileCabinet changes detected."
    exit 0
}

# 2. optional project:deploy
if (-not $SkipDeploy) {
    $cli = Resolve-SuiteCloudCli
    if ($cli) {
        Write-Host "Running suitecloud project:deploy..."
        Invoke-SuiteCloud -Arguments @('project:deploy')
    } else {
        Write-Warning "SuiteCloud CLI not found. Skipping SDF deploy (capture-only mode). Deploy via the VS Code extension's 'Deploy Project' before running this task. Pass -SkipDeploy to silence this warning."
    }
}

# 3. build batch payload
$files = @()
foreach ($rel in $changed) {
    if (-not $rel) { continue }
    if ($rel -match '/\.attributes/' -or $rel -match '\\\.attributes\\' -or $rel -match '/\.attributes/?$') { continue }

    $fullPath = Join-Path (Get-Location) $rel
    $deleted  = -not (Test-Path $fullPath)
    $logical  = $rel -replace '^src/FileCabinet/', ''

    if ($deleted) {
        $files += @{ path = $logical; deleted = $true }
        continue
    }
    if (Test-Path $fullPath -PathType Container) {
        Write-Host "  skipping directory: $rel"
        continue
    }
    $files += (Build-FilePayload -AbsolutePath $fullPath -LogicalPath $logical)
}

if ($files.Count -eq 0) {
    Write-Host "Nothing to capture after filtering. Done."
    exit 0
}

Send-ToRestlet -Files $files -Author $author -Commit $commit
