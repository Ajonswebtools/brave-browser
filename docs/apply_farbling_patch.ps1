$target = "C:\brave\src\brave\components\brave_shields\core\browser\brave_shields_utils.cc"
$content = Get-Content $target -Raw -Encoding UTF8

if ($content -match "GetSeedOverrideToken") {
  Write-Host "Patch already applied"
  exit 0
}

$includeNeedle = "#include ""base/logging.h"""
if (-not $content.Contains($includeNeedle)) {
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
  throw "Could not find namespace anchor: $namespaceNeedle"
}

$content = $content.Replace(
  $namespaceNeedle,
  $seedFunction + $namespaceNeedle
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

$needle = @'
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return token;
  }
'@

if (-not $content.Contains($needle)) {
  throw "Could not find GetFarblingToken HTTP(S) guard anchor"
}

$content = $content.Replace(
  $needle,
  $needle + $overrideBlock
)

Set-Content $target -Value $content -Encoding UTF8 -NoNewline

if (Get-Content $target -Raw | Select-String "GetSeedOverrideToken") {
  Write-Host "Patch applied successfully"
} else {
  throw "Patch verification failed"
}
