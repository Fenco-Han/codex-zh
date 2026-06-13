param(
  [string]$Root = "",
  [switch]$NoLaunch,
  [switch]$SelfTest,
  [switch]$PrintResult,
  [switch]$Configure
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Split-Path -Parent $PSScriptRoot
}

$CodexExe = Join-Path $Root "app\Codex.exe"
$CodexCliExe = Join-Path $Root "app\resources\codex.exe"
$NodeExe = Join-Path $Root "app\resources\node.exe"
$ConfigHome = Join-Path $env:USERPROFILE ".codex"
$CapabilitiesFile = Join-Path $ConfigHome "codex-zh\capabilities.json"
$ProfileStore = Join-Path $ConfigHome "codex-zh\profiles.json"
$GlobalStateFile = Join-Path $ConfigHome ".codex-global-state.json"
$LocalAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
$RoamingAppData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $env:USERPROFILE "AppData\Roaming" }
$ElectronUserData = Join-Path $RoamingAppData "Codex"
$ElectronCacheRoots = @(
  (Join-Path $RoamingAppData "Codex"),
  (Join-Path $LocalAppData "Codex"),
  (Join-Path $LocalAppData "Codex-ZH\electron-user-data")
)
$SourceMarketplace = Join-Path $Root "app\resources\plugins\openai-bundled"
$RuntimeMarketplace = Join-Path $ConfigHome ".tmp\bundled-marketplaces\openai-bundled"
$ElectronRendererCacheDirs = @(
  "Cache",
  "Code Cache",
  "GPUCache",
  "DawnGraphiteCache",
  "DawnWebGPUCache",
  "Service Worker"
)

function New-Result {
  param(
    [string]$Status,
    [string]$Reason = "",
    [bool]$Launched = $false
  )
  return [ordered]@{
    codexExe = $CodexExe
    codexHome = $ConfigHome
    electronUserData = $ElectronUserData
    launched = $Launched
    profileStore = $ProfileStore
    reason = $Reason
    status = $Status
  }
}

function Write-Utf8NoBom {
  param([string]$Path, [string]$Value)
  [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function ZH {
  param([string]$Base64)
  return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64))
}

function Test-ValidJsonText {
  param([string]$Value)
  try {
    $null = $Value | ConvertFrom-Json
    return $true
  } catch {
    return $false
  }
}

function Backup-InvalidGlobalState {
  param([string]$Path)
  if (!(Test-Path $Path)) {
    return
  }
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  Copy-Item -Force $Path "$Path.invalid-json-$stamp.bak"
}

function New-CodexDefaultGlobalStateJson {
  $state = [ordered]@{
    "electron-persisted-atom-state" = [ordered]@{
      "seen-model-upgrade-list" = @("gpt-5.5")
      "electron:onboarding-hide-first-new-thread-promos" = $true
    }
  }
  return (($state | ConvertTo-Json -Depth 20 -Compress) + "`n")
}

function Save-CodexDesktopDefaults {
  [System.IO.Directory]::CreateDirectory($ConfigHome) | Out-Null

  if (!(Test-Path $GlobalStateFile)) {
    Write-Utf8NoBom -Path $GlobalStateFile -Value (New-CodexDefaultGlobalStateJson)
    return
  }

  $text = [System.IO.File]::ReadAllText($GlobalStateFile, [System.Text.Encoding]::UTF8)
  if (!(Test-ValidJsonText -Value $text)) {
    Backup-InvalidGlobalState -Path $GlobalStateFile
    Write-Utf8NoBom -Path $GlobalStateFile -Value (New-CodexDefaultGlobalStateJson)
    return
  }

  try {
    $state = $text | ConvertFrom-Json
    if ($null -eq $state.PSObject.Properties["electron-persisted-atom-state"]) {
      $state | Add-Member -NotePropertyName "electron-persisted-atom-state" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $atom = $state."electron-persisted-atom-state"
    $atom | Add-Member -NotePropertyName "seen-model-upgrade-list" -NotePropertyValue @("gpt-5.5") -Force
    $atom | Add-Member -NotePropertyName "electron:onboarding-hide-first-new-thread-promos" -NotePropertyValue $true -Force
    Write-Utf8NoBom -Path $GlobalStateFile -Value (($state | ConvertTo-Json -Depth 50 -Compress) + "`n")
  } catch {
    Backup-InvalidGlobalState -Path $GlobalStateFile
    Write-Utf8NoBom -Path $GlobalStateFile -Value (New-CodexDefaultGlobalStateJson)
  }
}

function ConvertTo-TomlLiteralString {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Ensure-BundledMarketplace {
  if (!(Test-Path $SourceMarketplace)) {
    return [ordered]@{
      browser = $false
      chrome = $false
      computerUse = $false
      marketplace = [ordered]@{ runtime = $RuntimeMarketplace; source = $SourceMarketplace; plugins = @() }
      network = $true
      source = "codex-zh-bundled"
      version = 1
    }
  }

  $runtimePlugins = Join-Path $RuntimeMarketplace "plugins"
  [System.IO.Directory]::CreateDirectory($runtimePlugins) | Out-Null
  [System.IO.Directory]::CreateDirectory((Join-Path $RuntimeMarketplace ".agents\plugins")) | Out-Null

  $sourcePlugins = Join-Path $SourceMarketplace "plugins"
  if (Test-Path $sourcePlugins) {
    Get-ChildItem -LiteralPath $sourcePlugins -Directory -Force | ForEach-Object {
      $target = Join-Path $runtimePlugins $_.Name
      if (Test-Path $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
      }
      Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
    }
  }

  $sourceMarketplaceFile = Join-Path $SourceMarketplace ".agents\plugins\marketplace.json"
  $runtimeMarketplaceFile = Join-Path $RuntimeMarketplace ".agents\plugins\marketplace.json"
  if (Test-Path $sourceMarketplaceFile) {
    $marketplaceText = [System.IO.File]::ReadAllText($sourceMarketplaceFile, [System.Text.Encoding]::UTF8)
    $marketplaceText = $marketplaceText.TrimStart([char]0xFEFF)
    Write-Utf8NoBom -Path $runtimeMarketplaceFile -Value $marketplaceText
  }

  $plugins = @()
  if (Test-Path $runtimePlugins) {
    $plugins = @(Get-ChildItem -LiteralPath $runtimePlugins -Directory -Force | Select-Object -ExpandProperty Name | Sort-Object)
  }
  $capabilities = [ordered]@{
    authMode = "codex-zh-profile"
    browser = $plugins -contains "browser"
    chrome = $plugins -contains "chrome"
    computerUse = ($plugins -contains "computer-use") -or ($plugins -contains "computer_use")
    marketplace = [ordered]@{
      plugins = $plugins
      runtime = $RuntimeMarketplace
      source = $SourceMarketplace
    }
    network = $true
    source = "codex-zh-bundled"
    version = 1
  }
  Write-Utf8NoBom -Path $CapabilitiesFile -Value (($capabilities | ConvertTo-Json -Depth 20) + "`n")
  return $capabilities
}

function Ensure-MarketplaceConfig {
  [System.IO.Directory]::CreateDirectory($ConfigHome) | Out-Null
  $configPath = Join-Path $ConfigHome "config.toml"
  $section = @(
    "[marketplaces.openai-bundled]",
    ('last_updated = "' + (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") + '"'),
    'source_type = "local"',
    ('source = ' + (ConvertTo-TomlLiteralString -Value $RuntimeMarketplace)),
    ""
  ) -join "`n"

  if (!(Test-Path $configPath)) {
    Write-Utf8NoBom -Path $configPath -Value $section
    return
  }

  $existing = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  $pattern = "(?ms)^\[marketplaces\.openai-bundled\]\s*.*?(?=^\[|\z)"
  if ([regex]::IsMatch($existing, $pattern)) {
    $next = [regex]::Replace($existing, $pattern, $section.TrimEnd() + "`n`n", 1)
  } else {
    $next = $existing.TrimEnd() + "`n`n" + $section
  }
  Write-Utf8NoBom -Path $configPath -Value $next
}

function Test-ComputerUsePluginConfigured {
  $configPath = Join-Path $ConfigHome "config.toml"
  if (!(Test-Path $configPath)) {
    return $false
  }
  $config = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  return [regex]::IsMatch($config, '(?ms)^\[plugins\."computer-use@openai-bundled"\]\s*.*?^\s*enabled\s*=\s*true\s*$', "Multiline")
}

function Get-ComputerUsePluginVersion {
  $manifestPath = Join-Path $RuntimeMarketplace "plugins\computer-use\.codex-plugin\plugin.json"
  if (!(Test-Path $manifestPath)) {
    return ""
  }
  try {
    $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    return [string]$manifest.version
  } catch {
    return ""
  }
}

function Test-ComputerUsePluginCached {
  $version = Get-ComputerUsePluginVersion
  if ([string]::IsNullOrWhiteSpace($version)) {
    return $false
  }
  $cachePath = Join-Path $ConfigHome "plugins\cache\openai-bundled\computer-use\$version"
  return (Test-Path (Join-Path $cachePath ".codex-plugin\plugin.json")) -and (Test-Path (Join-Path $cachePath "bin\open-computer-use.exe"))
}

function Copy-PluginTreeBestEffort {
  param([string]$Source, [string]$Destination)

  [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
  Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
    $target = Join-Path $Destination $_.Name
    if ($_.PSIsContainer) {
      Copy-PluginTreeBestEffort -Source $_.FullName -Destination $target
    } elseif (!(Test-Path -LiteralPath $target)) {
      Copy-Item -LiteralPath $_.FullName -Destination $target -Force
    } else {
      try {
        $sourceFile = Get-Item -LiteralPath $_.FullName
        $targetFile = Get-Item -LiteralPath $target
        if ($sourceFile.Length -ne $targetFile.Length) {
          Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
      } catch {
        # If an existing executable is in use, keep it and continue copying metadata.
      }
    }
  }
}

function Ensure-ComputerUsePluginCache {
  $source = Join-Path $RuntimeMarketplace "plugins\computer-use"
  if (!(Test-Path $source)) {
    return $false
  }
  $version = Get-ComputerUsePluginVersion
  if ([string]::IsNullOrWhiteSpace($version)) {
    return $false
  }

  $target = Join-Path $ConfigHome "plugins\cache\openai-bundled\computer-use\$version"
  if (Test-ComputerUsePluginCached) {
    return $true
  }

  Copy-PluginTreeBestEffort -Source $source -Destination $target
  return (Test-ComputerUsePluginCached)
}

function Ensure-ComputerUsePluginConfig {
  [System.IO.Directory]::CreateDirectory($ConfigHome) | Out-Null
  $configPath = Join-Path $ConfigHome "config.toml"
  $section = @(
    '[plugins."computer-use@openai-bundled"]',
    'enabled = true',
    ''
  ) -join "`n"

  if (!(Test-Path $configPath)) {
    Write-Utf8NoBom -Path $configPath -Value $section
    return
  }

  $existing = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  $pattern = '(?ms)^\[plugins\."computer-use@openai-bundled"\]\s*.*?(?=^\[|\z)'
  if ([regex]::IsMatch($existing, $pattern)) {
    $next = [regex]::Replace($existing, $pattern, $section.TrimEnd() + "`n`n", 1)
  } else {
    $next = $existing.TrimEnd() + "`n`n" + $section
  }
  Write-Utf8NoBom -Path $configPath -Value $next
}

function Ensure-ComputerUsePluginInstalled {
  if (!(Test-Path (Join-Path $RuntimeMarketplace "plugins\computer-use"))) {
    return
  }
  if ((Test-ComputerUsePluginConfigured) -and (Test-ComputerUsePluginCached)) {
    return
  }

  if (Test-Path $CodexCliExe) {
    $stdout = Join-Path $env:TEMP "codex-zh-computer-use-plugin-add.out"
    $stderr = Join-Path $env:TEMP "codex-zh-computer-use-plugin-add.err"
    $install = Start-Process `
      -FilePath $CodexCliExe `
      -ArgumentList @("plugin", "add", "computer-use", "--marketplace", "openai-bundled") `
      -RedirectStandardOutput $stdout `
      -RedirectStandardError $stderr `
      -WindowStyle Hidden `
      -Wait `
      -PassThru
    if ($install.ExitCode -eq 0) {
      return
    }
  }

  if (!(Ensure-ComputerUsePluginCache)) {
    throw "Failed to install bundled computer-use plugin cache."
  }
  Ensure-ComputerUsePluginConfig
}

function Clear-ElectronRendererCache {
  foreach ($root in $ElectronCacheRoots) {
    foreach ($name in $ElectronRendererCacheDirs) {
      $cachePath = Join-Path $root $name
      if (Test-Path -LiteralPath $cachePath) {
        Remove-Item -LiteralPath $cachePath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Initialize-CodexZhRuntime {
  Save-CodexDesktopDefaults
  $null = Ensure-BundledMarketplace
  Ensure-MarketplaceConfig
  Ensure-ComputerUsePluginInstalled
  Clear-ElectronRendererCache
}

function ConvertTo-TomlString {
  param([string]$Value)
  $escaped = [string]$Value
  $escaped = $escaped.Replace("\", "\\")
  $escaped = $escaped.Replace('"', '\"')
  $escaped = $escaped.Replace("`r", "\r")
  $escaped = $escaped.Replace("`n", "\n")
  $escaped = $escaped.Replace("`t", "\t")
  return '"' + $escaped + '"'
}

function Get-ConfigPath {
  return (Join-Path $ConfigHome "config.toml")
}

function Get-TomlValue {
  param([string]$Text, [string]$Section, [string]$Key)
  $escapedKey = [regex]::Escape($Key)
  if ([string]::IsNullOrWhiteSpace($Section)) {
    $match = [regex]::Match($Text, "(?m)^\s*$escapedKey\s*=\s*`"([^`"]*)`"")
    if ($match.Success) { return $match.Groups[1].Value }
    return ""
  }
  $escapedSection = [regex]::Escape($Section)
  $sectionMatch = [regex]::Match($Text, "(?ms)^\[$escapedSection\]\s*(.*?)(?=^\[|\z)")
  if (!$sectionMatch.Success) { return "" }
  $match = [regex]::Match($sectionMatch.Groups[1].Value, "(?m)^\s*$escapedKey\s*=\s*`"([^`"]*)`"")
  if ($match.Success) { return $match.Groups[1].Value }
  return ""
}

function Get-ProviderIdsFromConfig {
  $configPath = Get-ConfigPath
  if (!(Test-Path $configPath)) { return @() }
  $text = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  return @([regex]::Matches($text, '(?m)^\[model_providers\.([A-Za-z0-9_-]+)\]') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Get-CurrentRouterConfig {
  $configPath = Get-ConfigPath
  $text = ""
  if (Test-Path $configPath) {
    $text = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  }
  $provider = Get-TomlValue -Text $text -Section "" -Key "model_provider"
  if ([string]::IsNullOrWhiteSpace($provider)) { $provider = "custom" }
  $section = "model_providers.$provider"
  return [ordered]@{
    provider = $provider
    providerName = Get-TomlValue -Text $text -Section $section -Key "name"
    baseUrl = Get-TomlValue -Text $text -Section $section -Key "base_url"
    model = Get-TomlValue -Text $text -Section "" -Key "model"
    wireApi = Get-TomlValue -Text $text -Section $section -Key "wire_api"
    apiKey = Get-TomlValue -Text $text -Section $section -Key "experimental_bearer_token"
    requiresOpenaiAuth = ((Get-TomlValue -Text $text -Section $section -Key "requires_openai_auth") -eq "true")
  }
}

function Get-RouterConfigForProvider {
  param([string]$Provider)
  $configPath = Get-ConfigPath
  $text = ""
  if (Test-Path $configPath) {
    $text = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  }
  if ([string]::IsNullOrWhiteSpace($Provider)) { $Provider = "custom" }
  $section = "model_providers.$Provider"
  return [ordered]@{
    provider = $Provider
    providerName = Get-TomlValue -Text $text -Section $section -Key "name"
    baseUrl = Get-TomlValue -Text $text -Section $section -Key "base_url"
    model = Get-TomlValue -Text $text -Section "" -Key "model"
    wireApi = Get-TomlValue -Text $text -Section $section -Key "wire_api"
    apiKey = Get-TomlValue -Text $text -Section $section -Key "experimental_bearer_token"
    requiresOpenaiAuth = ((Get-TomlValue -Text $text -Section $section -Key "requires_openai_auth") -eq "true")
  }
}

function Load-SavedRouterProfiles {
  if (!(Test-Path $ProfileStore)) { return @() }
  try {
    $storeText = [System.IO.File]::ReadAllText($ProfileStore, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($storeText)) { return @() }
    $store = $storeText | ConvertFrom-Json
    $profiles = @($store.profiles)
    $items = New-Object System.Collections.ArrayList
    foreach ($profile in $profiles) {
      if ($null -eq $profile) { continue }
      $provider = [string]$profile.provider
      if ([string]::IsNullOrWhiteSpace($provider)) { $provider = [string]$profile.id }
      if ([string]::IsNullOrWhiteSpace($provider)) { continue }
      $config = Get-RouterConfigForProvider -Provider $provider
      [void]$items.Add([ordered]@{
        id = if ($profile.id) { [string]$profile.id } else { $provider }
        name = if ($profile.name) { [string]$profile.name } else { $provider }
        provider = $provider
        baseUrl = if ($profile.baseUrl) { [string]$profile.baseUrl } else { [string]$config.baseUrl }
        model = if ($profile.model) { [string]$profile.model } else { [string]$config.model }
        wireApi = Normalize-WireApi -WireApi ([string]$profile.wireApi)
        apiKey = [string]$config.apiKey
      })
    }
    return @($items)
  } catch {
    return @()
  }
}

function Test-ActiveRouterConfig {
  $current = Get-CurrentRouterConfig
  $hasApiKey = ![string]::IsNullOrWhiteSpace($current.apiKey)
  return !([string]::IsNullOrWhiteSpace($current.provider) -or
    [string]::IsNullOrWhiteSpace($current.baseUrl) -or
    [string]::IsNullOrWhiteSpace($current.model)) -and
    ($hasApiKey -or $current.requiresOpenaiAuth) -and
    (Normalize-WireApi -WireApi $current.wireApi) -eq "responses"
}

function Normalize-WireApi {
  param([string]$WireApi)
  if ([string]::IsNullOrWhiteSpace($WireApi)) { return "responses" }
  if ($WireApi -eq "responses") { return "responses" }
  return "responses"
}

function Repair-ActiveRouterConfigWireApi {
  $current = Get-CurrentRouterConfig
  if ([string]::IsNullOrWhiteSpace($current.provider) -or
    [string]::IsNullOrWhiteSpace($current.providerName) -or
    [string]::IsNullOrWhiteSpace($current.baseUrl) -or
    [string]::IsNullOrWhiteSpace($current.model) -or
    [string]::IsNullOrWhiteSpace($current.apiKey)) {
    return
  }
  if ($current.wireApi -eq "responses") {
    return
  }
  Save-RouterProfile -Provider $current.provider -ProviderName $current.providerName -BaseUrl $current.baseUrl -Model $current.model -WireApi "responses" -ApiKey $current.apiKey -LastTestOk $false
}

function Get-ProviderPresetMap {
  # Wokey includes an intentional public test key for first-run validation.
  $presets = [ordered]@{
    "wokey" = [ordered]@{ provider = "wokey"; providerName = "Wokey"; baseUrl = "https://api.wokey.ai"; model = "auto"; wireApi = "responses"; apiKey = "sk-3d6c1264227a52f75af4028bcc3c217b" }
    "custom" = [ordered]@{ provider = "custom"; providerName = (ZH "6Ieq5a6a5LmJ5Lit6L2s56uZ"); baseUrl = ""; model = ""; wireApi = "responses"; apiKey = "" }
    "openrouter" = [ordered]@{ provider = "openrouter"; providerName = "OpenRouter"; baseUrl = "https://openrouter.ai/api/v1"; model = "openai/gpt-4.1"; wireApi = "responses"; apiKey = "" }
  }
  foreach ($profile in (Load-SavedRouterProfiles)) {
    if ([string]::IsNullOrWhiteSpace($profile.provider)) { continue }
    $id = [string]$profile.id
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$profile.provider }
    $entry = [ordered]@{
      provider = [string]$profile.provider
      providerName = if ($profile.name) { [string]$profile.name } else { [string]$profile.provider }
      baseUrl = [string]$profile.baseUrl
      model = [string]$profile.model
      wireApi = Normalize-WireApi -WireApi ([string]$profile.wireApi)
      apiKey = [string]$profile.apiKey
    }
    if ($presets.Contains($id)) {
      $presets[$id] = $entry
    } else {
      $presets[$id] = $entry
    }
  }
  return $presets
}

function New-CodexRouterConfigText {
  param(
    [string]$Provider,
    [string]$ProviderName,
    [string]$BaseUrl,
    [string]$Model,
    [string]$WireApi,
    [string]$ApiKey,
    [bool]$RequiresOpenaiAuth = $false
  )
  $providerLines = @(
    "name = $(ConvertTo-TomlString $ProviderName)",
    "base_url = $(ConvertTo-TomlString $BaseUrl)",
    "wire_api = $(ConvertTo-TomlString $WireApi)",
    $(if ($RequiresOpenaiAuth) { 'requires_openai_auth = true' } else { "experimental_bearer_token = $(ConvertTo-TomlString $ApiKey)" })
  )
  return @(
    "model = $(ConvertTo-TomlString $Model)",
    "model_provider = $(ConvertTo-TomlString $Provider)",
    'model_reasoning_effort = "medium"',
    "",
    "[model_providers.$Provider]",
    $providerLines,
    "",
    "[desktop]",
    'conversationDetailMode = "STEPS_COMMANDS"',
    ""
  ) -join "`n"
}

function Get-TomlKey {
  param([string]$Line)
  $match = [regex]::Match($Line, '^\s*([A-Za-z0-9_-]+)\s*=')
  if ($match.Success) { return $match.Groups[1].Value }
  return ""
}

function Get-OwnedKeysForTomlSection {
  param([string]$Section)
  if ([string]::IsNullOrWhiteSpace($Section)) { return @("model", "model_provider", "model_reasoning_effort") }
  if ($Section -eq "desktop") { return @("conversationDetailMode") }
  if ($Section -match '^model_providers\.[A-Za-z0-9_-]+$') { return @("base_url", "experimental_bearer_token", "name", "wire_api", "requires_openai_auth") }
  return @()
}

function Split-TomlSections {
  param([string]$Text)
  $sections = New-Object System.Collections.ArrayList
  $current = [ordered]@{ name = ""; header = ""; lines = New-Object System.Collections.ArrayList }
  [void]$sections.Add($current)
  foreach ($line in ([string]$Text -split "`r?`n")) {
    $match = [regex]::Match($line, '^\s*\[([^\]]+)\]\s*(?:#.*)?$')
    if ($match.Success) {
      $current = [ordered]@{ name = $match.Groups[1].Value.Trim(); header = $line.TrimEnd(); lines = New-Object System.Collections.ArrayList }
      [void]$sections.Add($current)
    } else {
      [void]$current.lines.Add($line)
    }
  }
  return @($sections)
}

function Merge-CodexRouterConfig {
  param([string]$Existing, [string]$Desired)

  $desiredSections = Split-TomlSections -Text $Desired
  $desiredOwned = @{}
  foreach ($section in $desiredSections) {
    $keys = @(Get-OwnedKeysForTomlSection -Section $section.name)
    if (!$keys.Count) { continue }
    $values = [ordered]@{}
    foreach ($line in $section.lines) {
      $key = Get-TomlKey -Line $line
      if ($key -and ($keys -contains $key)) {
        $values[$key] = $line.TrimEnd()
      }
    }
    if ($values.Count) {
      $desiredOwned[$section.name] = [ordered]@{ header = $section.header; values = $values }
    }
  }

  $existingSections = Split-TomlSections -Text $Existing
  $existingSectionList = New-Object System.Collections.ArrayList
  foreach ($section in $existingSections) { [void]$existingSectionList.Add($section) }
  $existingNames = @{}
  foreach ($section in $existingSectionList) { $existingNames[$section.name] = $true }
  foreach ($section in $desiredSections) {
    if ($desiredOwned.ContainsKey($section.name) -and !$existingNames.ContainsKey($section.name)) {
      $newSection = [ordered]@{ name = $section.name; header = $section.header; lines = New-Object System.Collections.ArrayList }
      foreach ($line in $desiredOwned[$section.name].values.Values) { [void]$newSection.lines.Add($line) }
      [void]$existingSectionList.Add($newSection)
      $existingNames[$section.name] = $true
    }
  }

  $parts = New-Object System.Collections.ArrayList
  foreach ($section in $existingSectionList) {
    $lines = New-Object System.Collections.ArrayList
    $remaining = [ordered]@{}
    if ($desiredOwned.ContainsKey($section.name)) {
      foreach ($key in $desiredOwned[$section.name].values.Keys) {
        $remaining[$key] = $desiredOwned[$section.name].values[$key]
      }
    }
    $seen = @{}
    foreach ($line in $section.lines) {
      $key = Get-TomlKey -Line $line
      if (!$key -or !$remaining.Contains($key)) {
        [void]$lines.Add($line)
        continue
      }
      if (!$seen.ContainsKey($key)) {
        [void]$lines.Add($remaining[$key])
        $seen[$key] = $true
      }
      $remaining.Remove($key)
    }
    foreach ($line in $remaining.Values) { [void]$lines.Add($line) }
    $body = (@($lines) -join "`n").TrimEnd()
    if ([string]::IsNullOrWhiteSpace($section.name)) {
      if ($body) { [void]$parts.Add($body) }
    } else {
      if ($body) { [void]$parts.Add($section.header + "`n" + $body) } else { [void]$parts.Add($section.header) }
    }
  }

  return ((@($parts) -join "`n`n").TrimEnd() + "`n")
}

function Save-RouterProfile {
  param(
    [string]$Provider,
    [string]$ProviderName,
    [string]$BaseUrl,
    [string]$Model,
    [string]$WireApi,
    [string]$ApiKey,
    [bool]$RequiresOpenaiAuth = $false,
    [bool]$LastTestOk = $false
  )

  [System.IO.Directory]::CreateDirectory($ConfigHome) | Out-Null
  $WireApi = Normalize-WireApi -WireApi $WireApi
  $configPath = Get-ConfigPath
  $desired = New-CodexRouterConfigText -Provider $Provider -ProviderName $ProviderName -BaseUrl $BaseUrl -Model $Model -WireApi $WireApi -ApiKey $ApiKey -RequiresOpenaiAuth $RequiresOpenaiAuth
  $existing = ""
  if (Test-Path $configPath) {
    $existing = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
    if ($existing) {
      $backup = "$configPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
      Copy-Item -LiteralPath $configPath -Destination $backup -Force
    }
  }
  Write-Utf8NoBom -Path $configPath -Value (Merge-CodexRouterConfig -Existing $existing -Desired $desired)

  $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $profiles = @()
  if (Test-Path $ProfileStore) {
    try {
      $storeText = [System.IO.File]::ReadAllText($ProfileStore, [System.Text.Encoding]::UTF8)
      if (![string]::IsNullOrWhiteSpace($storeText)) {
        $loaded = $storeText | ConvertFrom-Json
        $profiles = @($loaded.profiles | Where-Object { $_.id -ne $Provider })
      }
    } catch {
      $profiles = @()
    }
  }
  $profiles += [ordered]@{
    id = $Provider
    name = $ProviderName
    provider = $Provider
    baseUrl = $BaseUrl
    model = $Model
    wireApi = $WireApi
    apiKeySource = "config"
    lastTest = [ordered]@{
      ok = $LastTestOk
      testedAt = $now
    }
    updatedAt = $now
  }
  $store = [ordered]@{
    activeProfileId = $Provider
    profiles = @($profiles | Sort-Object { [string]$_.id })
  }
  Write-Utf8NoBom -Path $ProfileStore -Value (($store | ConvertTo-Json -Depth 20) + "`n")
}

function Test-RouterProviderConnection {
  param([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$WireApi)

  $base = ([string]$BaseUrl).TrimEnd("/")
  $headers = @{ Authorization = "Bearer $ApiKey"; "Content-Type" = "application/json" }
  $WireApi = Normalize-WireApi -WireApi $WireApi
  $uri = "$base/responses"
  $body = @{
    model = $Model
    input = @(
      @{
        role = "user"
        content = @(
          @{ type = "input_text"; text = "Reply with OK." }
        )
      }
    )
    stream = $false
  } | ConvertTo-Json -Depth 8 -Compress
  try {
    $null = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -TimeoutSec 30
    return [ordered]@{ ok = $true; message = (ZH "6L+e5o6l5rWL6K+V6YCa6L+H44CC") }
  } catch {
    $message = [string]$_.Exception.Message
    if (![string]::IsNullOrWhiteSpace($ApiKey)) {
      $message = $message.Replace($ApiKey, "API Key")
    }
    return [ordered]@{ ok = $false; message = ((ZH "6L+e5o6l5rWL6K+V5aSx6LSl77ya") + $message) }
  }
}

function Show-RouterConfigWindow {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $current = Get-CurrentRouterConfig
  $presets = Get-ProviderPresetMap
  if ((Test-ActiveRouterConfig) -and ![string]::IsNullOrWhiteSpace($current.provider) -and !$presets.Contains($current.provider)) {
    $presets[$current.provider] = [ordered]@{
      provider = $current.provider
      providerName = if ($current.providerName) { $current.providerName } else { $current.provider }
      baseUrl = $current.baseUrl
      model = $current.model
      wireApi = Normalize-WireApi -WireApi $current.wireApi
      apiKey = $current.apiKey
    }
  }

  # -- Owner-drawn button for flat modern style --
  Add-Type @"
using System;
using System.Drawing;
using System.Windows.Forms;
public class FlatCfgBtn : Button {
  public Color FlatBg = Color.FromArgb(240,240,240);
  public Color FlatFg = Color.FromArgb(51,51,51);
  public FlatCfgBtn() { FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 1; FlatAppearance.BorderColor = Color.FromArgb(218,220,224); BackColor = Color.White; Cursor = Cursors.Hand; Font = new Font("Microsoft YaHei UI", 9F); }
  protected override void OnPaint(PaintEventArgs e) {
    e.Graphics.Clear(Parent != null ? Parent.BackColor : Color.White);
    Color bg = FlatBg;
    if (ContainsFocus) bg = Color.FromArgb(Math.Max(FlatBg.R-18,0),Math.Max(FlatBg.G-18,0),Math.Max(FlatBg.B-18,0));
    else if (ClientRectangle.Contains(PointToClient(Cursor.Position))) bg = Color.FromArgb(Math.Max(FlatBg.R-10,0),Math.Max(FlatBg.G-10,0),Math.Max(FlatBg.B-10,0));
    using (var br = new SolidBrush(bg)) {
      var r = new Rectangle(1,1,Width-3,Height-3);
      int d = Math.Min(6, Math.Min(r.Width, r.Height)/2);
      e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
      e.Graphics.FillRectangle(br, r.X+d,r.Y,r.Width-2*d,r.Height);
      e.Graphics.FillRectangle(br, r.X,r.Y+d,r.Width,r.Height-2*d);
      e.Graphics.FillPie(br, r.X,r.Y,2*d,2*d, 180,90);
      e.Graphics.FillPie(br, r.Right-2*d,r.Y,2*d,2*d, 270,90);
      e.Graphics.FillPie(br, r.X,r.Bottom-2*d,2*d,2*d, 90,90);
      e.Graphics.FillPie(br, r.Right-2*d,r.Bottom-2*d,2*d,2*d, 0,90);
    }
    TextRenderer.DrawText(e.Graphics, Text, Font, r, FlatFg, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
  }
}
"@ -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Drawing.Common | Out-Null

  $form = New-Object System.Windows.Forms.Form
  $form.Text = ZH "Q29kZXgtWkgg5Lit6L2s56uZ6K6+572u"
  $form.StartPosition = "CenterScreen"
  $form.ClientSize = New-Object System.Drawing.Size(580, 460)
  $form.FormBorderStyle = "FixedDialog"
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.BackColor = [System.Drawing.Color]::FromArgb(249,250,251)
  $form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)

  # Card panels (painted via OnPaint)
  $basicCard = New-Object System.Windows.Forms.Panel
  $basicCard.Location = New-Object System.Drawing.Point(16, 88)
  $basicCard.Size = New-Object System.Drawing.Size(548, 188)
  $basicCard.BackColor = [System.Drawing.Color]::White
  $form.Controls.Add($basicCard)

  $advancedCard = New-Object System.Windows.Forms.Panel
  $advancedCard.Location = New-Object System.Drawing.Point(16, 320)
  $advancedCard.Size = New-Object System.Drawing.Size(548, 136)
  $advancedCard.BackColor = [System.Drawing.Color]::White
  $form.Controls.Add($advancedCard)

  $form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    foreach ($card in @($basicCard, $advancedCard)) {
      if (!$card.Visible) { continue }
      $cRect = $card.RectangleToScreen($card.ClientRectangle)
      $r = $form.RectangleToClient($cRect)
      $borderColor = [System.Drawing.Color]::FromArgb(229,231,235)
      $pen = New-Object System.Drawing.Pen($borderColor, 1)
      $d = 8
      $path = New-Object System.Drawing.Drawing2D.GraphicsPath
      $path.AddArc($r.X, $r.Y, $d*2, $d*2, 180, 90)
      $path.AddArc($r.Right-$d*2, $r.Y, $d*2, $d*2, 270, 90)
      $path.AddArc($r.Right-$d*2, $r.Bottom-$d*2, $d*2, $d*2, 0, 90)
      $path.AddArc($r.X, $r.Bottom-$d*2, $d*2, $d*2, 90, 90)
      $path.CloseFigure()
      $g.DrawPath($pen, $path)
      $pen.Dispose(); $path.Dispose()
    }
  })

  # -- Helper: create a field label --
  $labelFont = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
  function Add-FieldLabel([string]$Text, [int]$X, [int]$Y, [System.Windows.Forms.Control]$Parent) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Font = $labelFont
    $l.ForeColor = [System.Drawing.Color]::FromArgb(107,114,128)
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size(80, 22)
    $l.TextAlign = "TopLeft"
    $Parent.Controls.Add($l)
    return $l
  }

  # -- Helper: create a styled input --
  function Add-FieldInput([int]$X, [int]$Y, [System.Windows.Forms.Control]$Parent, [bool]$Password = $false) {
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point($X, $Y)
    $tb.Size = New-Object System.Drawing.Size(410, 26)
    $tb.BorderStyle = "FixedSingle"
    $tb.BackColor = [System.Drawing.Color]::White
    if ($Password) { $tb.UseSystemPasswordChar = $true }
    $Parent.Controls.Add($tb)
    return $tb
  }

  # ================================================================
  # Header
  # ================================================================
  $title = New-Object System.Windows.Forms.Label
  $title.Text = ZH "6YCJ5oup5Lit6L2s56uZ"
  $title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
  $title.ForeColor = [System.Drawing.Color]::FromArgb(31,41,55)
  $title.Location = New-Object System.Drawing.Point(16, 16)
  $title.Size = New-Object System.Drawing.Size(500, 40)
  $form.Controls.Add($title)

  $subtitle = New-Object System.Windows.Forms.Label
  $subtitle.Text = ZH "5Lit6L2s56uZ5Y6f55Sf5o6l"
  $subtitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
  $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(156,163,175)
  $subtitle.Location = New-Object System.Drawing.Point(16, 58)
  $subtitle.Size = New-Object System.Drawing.Size(500, 22)
  $form.Controls.Add($subtitle)

  # ================================================================
  # Basic card — Provider / Base URL / API Key / Model
  # ================================================================
  $LY = 12; $LW = 80; $IX = 100; $IW = 410; $ROW = 42

  Add-FieldLabel (ZH "5Lit6L2s56uZ") 16 $LY $basicCard | Out-Null
  $presetBox = New-Object System.Windows.Forms.ComboBox
  $presetBox.DropDownStyle = "DropDownList"
  $presetBox.Location = New-Object System.Drawing.Point($IX, $LY - 2)
  $presetBox.Size = New-Object System.Drawing.Size($IW, 26)
  @($presets.Keys) | ForEach-Object { [void]$presetBox.Items.Add($_) }
  $presetBox.SelectedItem = "wokey"
  $basicCard.Controls.Add($presetBox)

  $LY += $ROW
  Add-FieldLabel (ZH "5o6l5Y+j5Zyw5Z2A") 16 $LY $basicCard | Out-Null
  $baseUrlBox = Add-FieldInput $IX $LY $basicCard

  $LY += $ROW
  Add-FieldLabel "API Key" 16 $LY $basicCard | Out-Null
  $apiKeyBox = Add-FieldInput $IX $LY $basicCard

  $LY += 30
  $useSystemAuthBox = New-Object System.Windows.Forms.CheckBox
  $useSystemAuthBox.Text = ZH "5L+d5a2Y57O75YiX6K6v5Y+v6KeG57O75YiX"
  $useSystemAuthBox.Font = $labelFont
  $useSystemAuthBox.ForeColor = [System.Drawing.Color]::FromArgb(107,114,128)
  $useSystemAuthBox.Location = New-Object System.Drawing.Point($IX, $LY)
  $useSystemAuthBox.Size = New-Object System.Drawing.Size($IW, 22)
  $useSystemAuthBox.Add_CheckedChanged({
    if ($useSystemAuthBox.Checked) { $apiKeyBox.Text = ""; $apiKeyBox.Enabled = $false }
    else { $apiKeyBox.Enabled = $true }
  })
  $basicCard.Controls.Add($useSystemAuthBox)

  $LY += $ROW
  Add-FieldLabel (ZH "5qih5Z6L") 16 $LY $basicCard | Out-Null
  $modelBox = Add-FieldInput $IX $LY $basicCard

  # ================================================================
  # Advanced toggle (below basic card)
  # ================================================================
  $advancedToggle = New-Object System.Windows.Forms.CheckBox
  $advancedToggle.Text = ZH "6auY57qn6K6+572u"
  $advancedToggle.Font = $labelFont
  $advancedToggle.ForeColor = [System.Drawing.Color]::FromArgb(107,114,128)
  $advancedToggle.Location = New-Object System.Drawing.Point(16, 288)
  $advancedToggle.Size = New-Object System.Drawing.Size(200, 24)
  $form.Controls.Add($advancedToggle)

  # ================================================================
  # Advanced card — Provider ID / Name / Wire API
  # ================================================================
  $aLY = 12
  Add-FieldLabel "Provider ID" 16 $aLY $advancedCard | Out-Null
  $providerBox = Add-FieldInput $IX $aLY $advancedCard

  $aLY += $ROW
  Add-FieldLabel (ZH "5pi+56S65ZCN56ew") 16 $aLY $advancedCard | Out-Null
  $nameBox = Add-FieldInput $IX $aLY $advancedCard

  $aLY += $ROW
  Add-FieldLabel (ZH "5o6l5Y+j57G75Z6L") 16 $aLY $advancedCard | Out-Null
  $wireBox = New-Object System.Windows.Forms.ComboBox
  $wireBox.DropDownStyle = "DropDownList"
  $wireBox.Location = New-Object System.Drawing.Point($IX, $aLY)
  $wireBox.Size = New-Object System.Drawing.Size($IW, 26)
  [void]$wireBox.Items.Add("responses")
  $advancedCard.Controls.Add($wireBox)

  # ================================================================
  # Hint label (repositioned dynamically)
  # ================================================================
  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = ZH "5L+d5a2Y5ZCO5Lya5pu05pawIENvZGV4IOmFjee9ru+8jEFQSSBLZXkg5LuF5L+d5a2Y5Zyo5pys5py6IGNvbmZpZy50b21s44CC"
  $hint.Font = $labelFont
  $hint.ForeColor = [System.Drawing.Color]::FromArgb(156,163,175)
  $hint.Size = New-Object System.Drawing.Size(548, 20)
  $form.Controls.Add($hint)

  # ================================================================
  # Status label
  # ================================================================
  $status = New-Object System.Windows.Forms.Label
  $status.Text = ""
  $status.Size = New-Object System.Drawing.Size(548, 22)
  $form.Controls.Add($status)

  # ================================================================
  # Action buttons (owner-drawn flat style)
  # ================================================================
  $BTN_W = 88; $BTN_H = 36; $BTN_GAP = 10

  $testButton = New-Object FlatCfgBtn
  $testButton.Text = ZH "5rWL6K+V6L+e5o6l"
  $testButton.Size = New-Object System.Drawing.Size($BTN_W, $BTN_H)

  $cancelButton = New-Object FlatCfgBtn
  $cancelButton.Text = ZH "5Y+W5raI"
  $cancelButton.Size = New-Object System.Drawing.Size($BTN_W, $BTN_H)

  $saveButton = New-Object FlatCfgBtn
  $saveButton.Text = ZH "5L+d5a2Y"
  $saveButton.Size = New-Object System.Drawing.Size($BTN_W, $BTN_H)

  $saveLaunchButton = New-Object FlatCfgBtn
  $saveLaunchButton.Text = ZH "5L+d5a2Y5bm25ZCv5Yqo"
  $saveLaunchButton.Size = New-Object System.Drawing.Size(120, $BTN_H)
  $saveLaunchButton.FlatBg = [System.Drawing.Color]::FromArgb(37,99,235)
  $saveLaunchButton.FlatFg = [System.Drawing.Color]::White

  foreach ($btn in @($testButton, $cancelButton, $saveButton, $saveLaunchButton)) { $form.Controls.Add($btn) }

  # ================================================================
  # Layout recalculation on advanced toggle
  # ================================================================
  $advancedControls = @($providerBox, $nameBox, $wireBox)
  function Set-AdvancedVisible {
    param([bool]$Visible)
    $advancedCard.Visible = $Visible
    $advancedToggle.Checked = $Visible
    if ($Visible) {
      $form.ClientSize = New-Object System.Drawing.Size(580, 520)
      $hint.Location  = New-Object System.Drawing.Point(16, 468)
      $status.Location = New-Object System.Drawing.Point(16, 490)
      $btnY = 520 - $BTN_H - 16
      $testButton.Location     = New-Object System.Drawing.Point(16, $btnY)
      $cancelButton.Location   = New-Object System.Drawing.Point(580 - 16 - $BTN_W, $btnY)
      $saveButton.Location     = New-Object System.Drawing.Point(580 - 16 - $BTN_W*2 - $BTN_GAP, $btnY)
      $saveLaunchButton.Location = New-Object System.Drawing.Point(580 - 16 - $BTN_W*2 - $BTN_GAP*2 - 120, $btnY)
    } else {
      $form.ClientSize = New-Object System.Drawing.Size(580, 460)
      $hint.Location  = New-Object System.Drawing.Point(16, 298)
      $status.Location = New-Object System.Drawing.Point(16, 320)
      $btnY = 460 - $BTN_H - 16
      $testButton.Location     = New-Object System.Drawing.Point(16, $btnY)
      $cancelButton.Location   = New-Object System.Drawing.Point(580 - 16 - $BTN_W, $btnY)
      $saveButton.Location     = New-Object System.Drawing.Point(580 - 16 - $BTN_W*2 - $BTN_GAP, $btnY)
      $saveLaunchButton.Location = New-Object System.Drawing.Point(580 - 16 - $BTN_W*2 - $BTN_GAP*2 - 120, $btnY)
    }
  }
  $advancedToggle.Add_CheckedChanged({ Set-AdvancedVisible $advancedToggle.Checked })
  Set-AdvancedVisible $false

  # ================================================================
  # Business logic (unchanged)
  # ================================================================
  function Apply-Preset {
    param([string]$PresetName)
    $preset = $presets[$PresetName]
    if ($preset) {
      $providerBox.Text = $preset.provider
      $nameBox.Text = $preset.providerName
      $baseUrlBox.Text = $preset.baseUrl
      $modelBox.Text = $preset.model
      $wireBox.SelectedItem = $preset.wireApi
      $apiKeyBox.Text = if ($preset.apiKey) { $preset.apiKey } else { "" }
    }
  }

  function Fill-Current {
    if (Test-ActiveRouterConfig) {
      $providerBox.Text = if ($current.provider) { $current.provider } else { "custom" }
      $nameBox.Text = if ($current.providerName) { $current.providerName } else { $providerBox.Text }
      $baseUrlBox.Text = $current.baseUrl
      $modelBox.Text = $current.model
      $wireBox.SelectedItem = Normalize-WireApi -WireApi $current.wireApi
      $useSystemAuthBox.Checked = $current.requiresOpenaiAuth
      if ($current.requiresOpenaiAuth) {
        $apiKeyBox.Text = ""; $apiKeyBox.Enabled = $false
      } else {
        $apiKeyBox.Text = $current.apiKey; $apiKeyBox.Enabled = $true
      }
      if ($presets.Contains($current.provider)) { $presetBox.SelectedItem = $current.provider }
      return
    }
    $presetBox.SelectedItem = "wokey"
    Apply-Preset "wokey"
  }
  Fill-Current

  $presetBox.Add_SelectedIndexChanged({ Apply-Preset ([string]$presetBox.SelectedItem) })

  function Read-FormInput {
    $provider = $providerBox.Text.Trim()
    $name = $nameBox.Text.Trim()
    $baseUrl = $baseUrlBox.Text.Trim().TrimEnd("/")
    $model = $modelBox.Text.Trim()
    $wire = [string]$wireBox.SelectedItem
    $apiKey = $apiKeyBox.Text.Trim()
    $requiresOpenaiAuth = $useSystemAuthBox.Checked
    $existing = Get-RouterConfigForProvider -Provider $provider
    if ([string]::IsNullOrWhiteSpace($apiKey) -and $existing.provider -eq $provider) {
      $apiKey = $existing.apiKey
    }
    if ($provider -notmatch '^[A-Za-z0-9_-]+$') { throw (ZH "UHJvdmlkZXIgSUQg5Y+q6IO95YyF5ZCr5a2X5q+N44CB5pWw5a2X44CB5LiL5YiS57q/5ZKM5Lit5YiS57q/44CC") }
    if ([string]::IsNullOrWhiteSpace($name)) { throw (ZH "5pi+56S65ZCN56ew5LiN6IO95Li656m644CC") }
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { throw (ZH "5o6l5Y+j5Zyw5Z2A5LiN6IO95Li656m644CC") }
    if ([string]::IsNullOrWhiteSpace($model)) { throw (ZH "5qih5Z6L5LiN6IO95Li656m644CC") }
    if (!$requiresOpenaiAuth -and [string]::IsNullOrWhiteSpace($apiKey)) { throw (ZH "QVBJIEtleSDkuI3og73kuLrnqbrjgII=") }
    try { $null = [Uri]$baseUrl } catch { throw (ZH "5o6l5Y+j5Zyw5Z2A5LiN5piv5pyJ5pWIIFVSTOOAgg==") }
    $wire = Normalize-WireApi -WireApi $wire
    return [ordered]@{ provider = $provider; providerName = $name; baseUrl = $baseUrl; model = $model; wireApi = $wire; apiKey = $apiKey; requiresOpenaiAuth = $requiresOpenaiAuth }
  }

  function Run-Test {
    try {
      $input = Read-FormInput
      $status.ForeColor = [System.Drawing.Color]::FromArgb(156,163,175)
      $status.Text = ZH "5q2j5Zyo5rWL6K+V6L+e5o6lLi4u"
      $form.Refresh()
      $result = Test-RouterProviderConnection -BaseUrl $input.baseUrl -ApiKey $input.apiKey -Model $input.model -WireApi $input.wireApi
      if ($result.ok) { $status.ForeColor = [System.Drawing.Color]::FromArgb(22,163,74) } else { $status.ForeColor = [System.Drawing.Color]::FromArgb(220,38,38) }
      $status.Text = $result.message
      return $result.ok
    } catch {
      $status.ForeColor = [System.Drawing.Color]::FromArgb(220,38,38)
      $status.Text = $_.Exception.Message
      return $false
    }
  }

  $testButton.Add_Click({ [void](Run-Test) })

  $cancelButton.Add_Click({ $form.Tag = "cancel"; $form.Close() })

  $saveButton.Add_Click({
    try {
      $input = Read-FormInput
      Save-RouterProfile -Provider $input.provider -ProviderName $input.providerName -BaseUrl $input.baseUrl -Model $input.model -WireApi $input.wireApi -ApiKey $input.apiKey -RequiresOpenaiAuth $input.requiresOpenaiAuth -LastTestOk $false
      $status.ForeColor = [System.Drawing.Color]::FromArgb(22,163,74)
      $status.Text = ZH "5bey5L+d5a2Y6YWN572u44CC"
      $form.Tag = "saved"; $form.Close()
    } catch {
      $status.ForeColor = [System.Drawing.Color]::FromArgb(220,38,38)
      $status.Text = $_.Exception.Message
    }
  })

  $saveLaunchButton.Add_Click({
    if (Run-Test) {
      try {
        $input = Read-FormInput
        Save-RouterProfile -Provider $input.provider -ProviderName $input.providerName -BaseUrl $input.baseUrl -Model $input.model -WireApi $input.wireApi -ApiKey $input.apiKey -RequiresOpenaiAuth $input.requiresOpenaiAuth -LastTestOk $true
        $form.Tag = "launch"; $form.Close()
      } catch {
        $status.ForeColor = [System.Drawing.Color]::FromArgb(220,38,38)
        $status.Text = $_.Exception.Message
      }
    }
  })

  [void]$form.ShowDialog()
  return [string]$form.Tag
}

if ($SelfTest) {
  if (!(Test-Path $CodexExe)) {
    $result = New-Result -Status "error" -Reason "codex_exe_missing"
  } elseif (!(Test-Path $CodexCliExe)) {
    $result = New-Result -Status "error" -Reason "codex_cli_missing"
  } else {
    $result = New-Result -Status "ok"
  }

  if ($PrintResult) {
    $result | ConvertTo-Json -Compress
  }
  if ($result.status -ne "ok") {
    exit 1
  }
  exit 0
}

if (!(Test-Path $CodexExe)) {
  throw "Codex.exe not found: $CodexExe"
}

if ($NoLaunch) {
  Initialize-CodexZhRuntime
  Repair-ActiveRouterConfigWireApi
  $result = New-Result -Status "ready" -Reason "no_launch"
  if ($PrintResult) {
    $result | ConvertTo-Json -Compress
  }
  exit 0
}

if ($Configure -or !(Test-ActiveRouterConfig)) {
  $configureResult = Show-RouterConfigWindow
  if ($configureResult -ne "launch") {
    $result = New-Result -Status "ready" -Reason "configured"
    if ($PrintResult) {
      $result | ConvertTo-Json -Compress
    }
    exit 0
  }
}

Initialize-CodexZhRuntime
Repair-ActiveRouterConfigWireApi

$env:CODEX_HOME = $ConfigHome
Remove-Item Env:\CODEX_ELECTRON_USER_DATA_PATH -ErrorAction SilentlyContinue
Start-Process -FilePath $CodexExe -WorkingDirectory (Split-Path -Parent $CodexExe)

$result = New-Result -Status "launched" -Launched $true
if ($PrintResult) {
  $result | ConvertTo-Json -Compress
}
