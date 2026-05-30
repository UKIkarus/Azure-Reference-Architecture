# scripts/_psrule-run.ps1
# =============================================================================
# Internal helper - called by scripts/validate-local.sh.
# Runs PSRule.Rules.Azure against a Bicep module.
#
# PSRule uses its own Bicep expansion (via az bicep, per .ps-rule/ps-rule.yaml:
#   AZURE_BICEP_FILE_EXPANSION: true
#   AZURE_BICEP_USE_AZURE_CLI: true
#   AZURE_BICEP_PARAMS_FILE_EXPANSION: true)
# This correctly expands all AVM nested deployments and resolves param values.
#
# -Path '.' loads .ps-rule/ps-rule.yaml (az bicep config) and
# .ps-rule/Local.Rule.ps1 (custom tag rules).
#
# Output protocol (parsed by validate-local.sh):
#   PSRULE_SUMMARY:Pass=N;Fail=N;Error=N;Skip=N
#   PSRULE_FAILURES:                           (only when Fail > 0)
#     [FAIL] RuleName | TargetName
#          Reason text
#   PSRULE_OK                                  (only when all pass)
#
# Exit codes:
#   0 - all rules passed
#   1 - one or more rules failed
#   2 - PSRule execution error (module missing, compile error, etc.)
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BicepFile,
    [string]$SarifOut = 'reports/psrule.sarif'
)

$ErrorActionPreference = 'Stop'

# ── Auto-install PSRule.Rules.Azure if not present ────────────────────────────
if (-not (Get-Module -ListAvailable PSRule.Rules.Azure -ErrorAction SilentlyContinue)) {
    Write-Host '[psrule-run] PSRule.Rules.Azure not found - installing from PSGallery...'
    try {
        Install-Module PSRule.Rules.Azure `
           -Repository PSGallery `
           -Force `
           -Scope CurrentUser `
           -AcceptLicense `
           -ErrorAction Stop
        Write-Host '[psrule-run] PSRule.Rules.Azure installed successfully.'
    }
    catch {
        Write-Host "[psrule-run] ERROR: Failed to install PSRule.Rules.Azure: $_"
        exit 2
    }
}

try {
    Import-Module PSRule.Rules.Azure -ErrorAction Stop
}
catch {
    Write-Host "[psrule-run] ERROR: Failed to import PSRule.Rules.Azure: $_"
    exit 2
}

# ── Ensure report output directory exists ────────────────────────────────────
$sarifDir = Split-Path $SarifOut -Parent
if ($sarifDir -and -not (Test-Path $sarifDir)) {
    $null = New-Item -ItemType Directory -Force -Path $sarifDir
}

# ── Run PSRule ────────────────────────────────────────────────────────────────
# -InputPath: the .bicep source file - PSRule expands it using az bicep
#   (AZURE_BICEP_FILE_EXPANSION: true + AZURE_BICEP_USE_AZURE_CLI: true in ps-rule.yaml)
# -Path '.': loads .ps-rule/ps-rule.yaml (az bicep config) and
#   .ps-rule/Local.Rule.ps1 (custom tag sentinel rules)
# This correctly expands all AVM nested deployments and resolves parameter
# values from the paired .bicepparam file (AZURE_BICEP_PARAMS_FILE_EXPANSION: true).
Write-Host "[psrule-run] Invoking PSRule.Rules.Azure against: $BicepFile"

# Resolve the bicep binary path for PSRule.
# Priority: standalone binary on PATH (present in CI at /usr/local/bin/bicep)
#       then: az bicep install location (~/.azure/bin/bicep, present locally)
# PSRULE_AZURE_BICEP_PATH is used when AZURE_BICEP_USE_AZURE_CLI is false (ps-rule.yaml).
$bicepFromPath = (Get-Command bicep -ErrorAction SilentlyContinue)?.Source
$bicepFromAz   = "$env:HOME/.azure/bin/bicep"
$resolvedBicep = if ($bicepFromPath -and (Test-Path $bicepFromPath)) {
    $bicepFromPath
} elseif (Test-Path $bicepFromAz) {
    $bicepFromAz
} else {
    $null
}
if ($resolvedBicep) {
    $env:PSRULE_AZURE_BICEP_PATH = $resolvedBicep
    Write-Host "[psrule-run] Using bicep at: $resolvedBicep"
} else {
    Write-Host "[psrule-run] WARN: bicep binary not found in PATH or at $bicepFromAz. Bicep expansion may fail."
}

if (-not (Test-Path $BicepFile)) {
    Write-Host "[psrule-run] ERROR: Bicep file not found: $BicepFile"
    exit 2
}

# Load PSRule options explicitly - PSRule auto-discovers ./ps-rule.yaml (CWD root)
# but NOT ./.ps-rule/ps-rule.yaml (the directory form needs explicit -Path).
# Without this, AZURE_BICEP_FILE_EXPANSION stays false and Bicep expansion never fires.
$optsPath = '.ps-rule/ps-rule.yaml'
$opts = if (Test-Path $optsPath) {
    New-PSRuleOption -Path $optsPath -ErrorAction Stop
} else {
    Write-Host "[psrule-run] WARN: $optsPath not found - using PSRule defaults (expansion disabled)"
    New-PSRuleOption
}

$results = @()
try {
    # Run PSRule - do NOT use -OutputFormat Sarif here; specifying -OutputPath with
    # a non-default format suppresses pipeline output (PSRule writes to file only),
    # which would leave $results empty and report 0 evaluated resources.
    # RuleRecord objects are captured in $results for pass/fail counting below.
    # -Outcome Fail,Pass,Error excludes the type-mismatch Skips (rule didn't apply
    # to this resource type).  Those are expected - each rule targets specific types
    # so with 241 resources × 533 rules, ~99% of combinations would be Skips.
    # Using Fail,Pass,Error keeps $results to only actionable rule evaluations.
    $results = @(
        Invoke-PSRule `
           -InputPath $BicepFile `
           -Module 'PSRule.Rules.Azure' `
           -Option $opts `
           -Baseline 'Local.AzureNetworking' `
           -Path '.' `
           -Outcome Fail,Pass,Error `
           -WarningAction SilentlyContinue `
           -ErrorAction Continue
    )
}
catch {
    Write-Host "[psrule-run] ERROR: Invoke-PSRule threw an exception: $_"
    exit 2
}

# ── Export SARIF (separate pass - -OutputPath suppresses pipeline output if combined) ─
try {
    $null = Invoke-PSRule `
       -InputPath $BicepFile `
       -Module 'PSRule.Rules.Azure' `
       -Option $opts `
       -Baseline 'Local.AzureNetworking' `
       -Path '.' `
       -Outcome Fail,Pass,Error `
       -OutputFormat Sarif `
       -OutputPath $SarifOut `
       -WarningAction SilentlyContinue `
       -ErrorAction SilentlyContinue
}
catch {
    Write-Host "[psrule-run] WARN: SARIF export failed (non-fatal): $_"
}

# ── Summarise results ─────────────────────────────────────────────────────────
$passed    = @($results | Where-Object { $_.Outcome -eq 'Pass'  }).Count
$failed    = @($results | Where-Object { $_.Outcome -eq 'Fail'  }).Count
$errored   = @($results | Where-Object { $_.Outcome -eq 'Error' }).Count
$resources = @($results | Select-Object -ExpandProperty TargetName -Unique).Count

Write-Host "PSRULE_SUMMARY:Pass=$passed;Fail=$failed;Error=$errored;Resources=$resources"

if ($results.Count -eq 0) {
    Write-Host 'PSRULE_SUMMARY:Pass=0;Fail=0;Error=0;Skip=0'
    Write-Host '[psrule-run] ERROR: 0 resources evaluated - Bicep expansion may have failed.'
    Write-Host '[psrule-run] Ensure PSRULE_AZURE_BICEP_PATH is valid and AZURE_BICEP_FILE_EXPANSION is true in ps-rule.yaml.'
    exit 1
}

if ($failed -gt 0 -or $errored -gt 0) {
    Write-Host 'PSRULE_FAILURES:'
    $results |
        Where-Object { $_.Outcome -in 'Fail', 'Error' } |
        Sort-Object RuleName |
        ForEach-Object {
            Write-Host "  [$($_.Outcome.ToString().ToUpper())] $($_.RuleName)  |  $($_.TargetName)"
            if ($_.Reason) {
                $_.Reason | ForEach-Object { Write-Host "        $_ " }
            }
        }
    exit 1
}

Write-Host 'PSRULE_OK'
exit 0
