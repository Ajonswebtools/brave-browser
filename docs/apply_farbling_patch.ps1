$target = if ($env:DMASK_FARBLING_PATCH_TARGET) {
  $env:DMASK_FARBLING_PATCH_TARGET
} else {
  "C:\brave\src\brave\components\brave_shields\core\browser\brave_shields_utils.cc"
}

function Show-NearbyMatches {
  param(
    [string[]]$Lines,
    [string]$Pattern,
    [string]$Label
  )

  Write-Host "=== Nearby lines for $Label ==="
  $found = $false
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($Lines[$i] -match $Pattern) {
      $found = $true
      $start = [Math]::Max(0, $i - 2)
      $end = [Math]::Min($Lines.Count - 1, $i + 2)
      for ($j = $start; $j -le $end; $j++) {
        Write-Host "$($j + 1): $($Lines[$j])"
      }
      Write-Host "---"
    }
  }

  if (-not $found) {
    Write-Host "No matches for pattern: $Pattern"
  }
}

Write-Host "=== DMask farbling patch target ==="
Write-Host $target

if (-not (Test-Path -LiteralPath $target)) {
  throw "Target file does not exist: $target"
}

$rawContent = Get-Content $target -Raw -Encoding UTF8
$content = $rawContent -replace "`r`n", "`n"
$lines = $content -split "`n"

$hasGetFarblingToken = $content.Contains("GetFarblingToken(")
$httpGuardPattern = 'if \(!url\.SchemeIsHTTPOrHTTPS\(\)\) \{\n\s+return token;\n\s+\}'
$hasHttpGuard = [regex]::IsMatch($content, $httpGuardPattern)
$alreadyApplied = $content.Contains("GetSeedOverrideToken")

Write-Host "=== Patch preflight ==="
Write-Host "GetFarblingToken found: $hasGetFarblingToken"
Write-Host "HTTP/HTTPS guard anchor found: $hasHttpGuard"
Write-Host "Patch already applied: $alreadyApplied"

if (-not $hasGetFarblingToken) {
  Show-NearbyMatches -Lines $lines -Pattern "GetFarblingToken|FarblingToken" -Label "GetFarblingToken"
  throw "Could not find GetFarblingToken in $target"
}

if ($alreadyApplied) {
  Write-Host "Patch already applied"
  exit 0
}

$includeNeedle = "#include ""base/logging.h"""
if (-not $content.Contains($includeNeedle)) {
  Show-NearbyMatches -Lines $lines -Pattern '^#include|logging\.h' -Label "include anchor"
  throw "Could not find include anchor: $includeNeedle"
}

$content = $content.Replace(
  $includeNeedle,
  $includeNeedle + "`n" +
  "#include <cstring>" + "`n" +
  "#include <vector>" + "`n" +
  "#include ""base/command_line.h""" + "`n" +
  "#include ""base/strings/string_number_conversions.h"""
)

$seedFunction = @'
static base::Token GetSeedOverrideToken(const GURL& url) {
  const base::CommandLine* cmd = base::CommandLine::ForCurrentProcess();
  if (!cmd->HasSwitch("brave-farbling-seed")) {
    return base::Token();
  }
  std::string hex = cmd->GetSwitchValueASCII("brave-farbling-seed");
  std::vector<uint8_t> bytes;
  if (hex.size() != 32 || !base::HexStringToBytes(hex, &bytes)) {
    LOG(WARNING) << "[DMask] --brave-farbling-seed is malformed, "
                    "must be 32 hex characters. Falling back to random.";
    return base::Token();
  }
  uint64_t high;
  uint64_t low;
  memcpy(&high, bytes.data(), 8);
  memcpy(&low, bytes.data() + 8, 8);
  const std::string origin = url.GetOrigin().spec();
  const uint64_t origin_hash = base::PersistentHash(origin);
  return base::Token(high ^ origin_hash, low ^ origin_hash);
}

'@

$namespaceNeedle = "}  // namespace"
if (-not $content.Contains($namespaceNeedle)) {
  $updatedLines = $content -split "`n"
  Show-NearbyMatches -Lines $updatedLines -Pattern 'namespace' -Label "namespace anchor"
  throw "Could not find namespace anchor: $namespaceNeedle"
}

$content = [regex]::Replace(
  $content,
  '(?m)^}  // namespace$',
  {
    param($match)
    $seedFunction + $match.Value
  },
  1
)

$overrideBlock = @'
  // DMask deterministic seed override.
  {
    base::Token override_token = GetSeedOverrideToken(url);
    if (!override_token.is_zero()) {
      if (additional_entropy.empty()) {
        return override_token;
      }
      const uint64_t high =
          override_token.high() ^ PersistentHashU64(additional_entropy);
      const uint64_t low =
          override_token.low() ^ PersistentHashU64(base::byte_span_from_ref(high));
      return base::Token(high, low);
    }
  }

'@

$functionPattern = '(?s)(base::Token GetFarblingToken\(HostContentSettingsMap\* map,.*?if \(!url\.SchemeIsHTTPOrHTTPS\(\)\) \{\n\s+return token;\n\s+\})'
if (-not [regex]::IsMatch($content, $functionPattern)) {
  $updatedLines = $content -split "`n"
  Show-NearbyMatches -Lines $updatedLines -Pattern 'GetFarblingToken|SchemeIsHTTPOrHTTPS|farbling_token' -Label "GetFarblingToken HTTP(S) guard anchor"
  throw "Could not find GetFarblingToken HTTP(S) guard anchor"
}

$content = [regex]::Replace(
  $content,
  $functionPattern,
  {
    param($match)
    $match.Value + "`n" + $overrideBlock.TrimEnd("`n")
  },
  1
)

[System.IO.File]::WriteAllText($target, $content, [System.Text.UTF8Encoding]::new($false))

$finalContent = (Get-Content $target -Raw -Encoding UTF8) -replace "`r`n", "`n"
if ($finalContent.Contains("GetSeedOverrideToken")) {
  Write-Host "Patch applied successfully"
} else {
  throw "Patch verification failed"
}
