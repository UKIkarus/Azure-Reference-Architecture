#!/usr/bin/env bash
# =============================================================================
# scripts/validate-local.sh
# =============================================================================
# Local CI validation pipeline - mirrors the validate job in
# .github/workflows/bicep-ci.yml.
#
# Steps:
#   0  Prerequisites  - required tools present; missing tools auto-installed
#   1  Secret scan    - betterleaks (auto-installed if missing)
#   2  YAML lint      - python3 yaml.safe_load on all .yml/.yaml files
#   3  Bicep lint     - az bicep lint (bicepconfig.json rules enforced)
#   4  Bicep build    - az bicep build + build-params (schema + type validation)
#   5  Tag sentinel   - no tag value or default may contain the word 'Missing'
#   6  PSRule         - WAF alignment + custom Local.Rule.ps1 rules
#                        (runs against compiled ARM JSON - no Bicep expansion needed)
#
# Usage:
#   cd /path/to/repo-root
#   bash scripts/validate-local.sh                      # validate all modules
#   bash scripts/validate-local.sh 01-Core-Networking   # validate one module
#   bash scripts/validate-local.sh --all                # explicitly validate all
#
# Output per module:
#   reports/<module>/validate-YYYY-MM-DD_HH-MM-SS.log
#   reports/<module>/validate-latest.log   (symlink to most recent run)
#   reports/<module>/main.arm.json         compiled ARM template
#   reports/<module>/main.arm.params.json  compiled ARM parameters
#   reports/<module>/psrule.sarif          PSRule SARIF report
#
# Exit codes:
#   0 - all modules passed
#   1 - one or more modules failed (see report for details)
# =============================================================================
set -uo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
C_BOLD='\033[1m'; C_BLUE='\033[0;34m'; C_GREEN='\033[0;32m'
C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'

# ── Repo-root guard ───────────────────────────────────────────────────────────
if [[ ! -f "bicepconfig.json" ]]; then
    printf '%b\n' "${C_RED}ERROR: Run this script from the repository root (where bicepconfig.json lives).${C_NC}" >&2
    exit 1
fi

# ── Module selection ──────────────────────────────────────────────────────────
ARG="${1:-}"

if [[ -z "$ARG" || "$ARG" == "--all" ]]; then
    mapfile -t MODULES < <(
        find . -name 'main.bicep' -path '*/bicep/main.bicep' \
            | sed 's|/bicep/main.bicep||; s|^\./||' \
            | sort
    )
    if [[ ${#MODULES[@]} -eq 0 ]]; then
        printf '%b\n' "${C_RED}ERROR: No modules with bicep/main.bicep found under the repo root.${C_NC}" >&2
        exit 1
    fi
else
    MODULES=("$ARG")
fi

# ── Global prerequisites (run once before any module loop) ────────────────────
PSRULE_OK=0
BETTERLEAKS_OK=0

install_prerequisites() {
    local PREREQ_FAIL=0

    printf '%b\n' ""
    printf '%b\n' "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"
    printf '%b\n' "${C_BOLD}${C_BLUE}  Installing / Verifying Prerequisites${C_NC}"
    printf '%b\n' "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"

    # az CLI
    if command -v az &>/dev/null; then
        printf '%b\n' "${C_GREEN}  ✓  PASS  ${C_NC} az CLI  v$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo '?')"
        printf '%b\n' "${C_GREEN}  ✓  PASS  ${C_NC} az bicep  $(az bicep version 2>&1 | head -1)"
    else
        printf '%b\n' "${C_RED}  ✗  FAIL  ${C_NC} az CLI not found - required for lint and build"
        PREREQ_FAIL=1
    fi

    # pwsh
    if command -v pwsh &>/dev/null; then
        printf '%b\n' "${C_GREEN}  ✓  PASS  ${C_NC} $(pwsh --version 2>&1)"
    else
        printf '%b\n' "${C_RED}  ✗  FAIL  ${C_NC} pwsh not found - required for PSRule. Install: https://aka.ms/pwsh"
        PREREQ_FAIL=1
    fi

    # python3
    if command -v python3 &>/dev/null; then
        printf '%b\n' "${C_GREEN}  ✓  PASS  ${C_NC} $(python3 --version 2>&1)"
    else
        printf '%b\n' "${C_RED}  ✗  FAIL  ${C_NC} python3 not found - required for YAML lint and tag sentinel"
        PREREQ_FAIL=1
    fi

    if [[ $PREREQ_FAIL -ne 0 ]]; then
        printf '%b\n' "${C_RED}  Aborting - fix missing required tools above and rerun.${C_NC}"
        exit 1
    fi

    # PSRule.Rules.Azure - auto-install if missing
    local PSRULE_INSTALLED
    PSRULE_INSTALLED=$(pwsh -NoProfile -Command \
        "if (Get-Module -ListAvailable PSRule.Rules.Azure -ErrorAction SilentlyContinue) { 'yes' } else { 'no' }" \
        2>/dev/null || echo 'no')
    if [[ "$PSRULE_INSTALLED" == "yes" ]]; then
        local PSRULE_VER
        PSRULE_VER=$(pwsh -NoProfile -Command \
            "(Get-Module -ListAvailable PSRule.Rules.Azure | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()" \
            2>/dev/null || echo '?')
        printf '%b\n' "${C_GREEN}  ✓  PASS  ${C_NC} PSRule.Rules.Azure  v${PSRULE_VER}"
        PSRULE_OK=1
    else
        printf '%b\n' "             PSRule.Rules.Azure not found - installing from PSGallery (~30 s)..."
        local INSTALL_EXIT=0
        pwsh -NoProfile -Command \
            "Install-Module PSRule.Rules.Azure -Repository PSGallery -Force -Scope CurrentUser -AcceptLicense 2>&1" \
            2>&1 && INSTALL_EXIT=0 || INSTALL_EXIT=$?
        if [[ $INSTALL_EXIT -eq 0 ]]; then
            printf '%b\n' "${C_GREEN}  ✓  PASS  ${C_NC} PSRule.Rules.Azure (installed)"
            PSRULE_OK=1
        else
            printf '%b\n' "${C_RED}  ✗  FAIL  ${C_NC} PSRule.Rules.Azure installation failed - Step 6 will fail"
        fi
    fi

    # betterleaks - auto-install if missing
    if command -v betterleaks &>/dev/null; then
        printf '%b\n' "${C_GREEN}  ✓  PASS  ${C_NC} betterleaks  v$(betterleaks version 2>&1 | head -1)"
        BETTERLEAKS_OK=1
    else
        printf '%b\n' "             betterleaks not found - installing latest release from GitHub..."
        local BL_VER BL_URL BL_INSTALL_EXIT=0
        BL_VER=$(curl -s https://api.github.com/repos/betterleaks/betterleaks/releases/latest \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo '')
        if [[ -z "$BL_VER" ]]; then
            printf '%b\n' "${C_RED}  ✗  FAIL  ${C_NC} betterleaks: could not determine latest version (no internet?)"
        else
            local BL_VER_CLEAN="${BL_VER#v}"
            BL_URL="https://github.com/betterleaks/betterleaks/releases/download/${BL_VER}/betterleaks_${BL_VER_CLEAN}_linux_x64.tar.gz"
            (
                cd /tmp
                curl -fsSL "$BL_URL" -o betterleaks_install.tar.gz 2>&1 && \
                tar -xzf betterleaks_install.tar.gz betterleaks 2>&1 && \
                sudo mv betterleaks /usr/local/bin/betterleaks
            ) && BL_INSTALL_EXIT=0 || BL_INSTALL_EXIT=$?
            if [[ $BL_INSTALL_EXIT -eq 0 ]] && command -v betterleaks &>/dev/null; then
                printf '%b\n' "${C_GREEN}  ✓  PASS  ${C_NC} betterleaks  ${BL_VER} (installed)"
                BETTERLEAKS_OK=1
            else
                printf '%b\n' "${C_RED}  ✗  FAIL  ${C_NC} betterleaks installation failed - Step 1 will fail"
            fi
        fi
    fi
}

install_prerequisites

# ── Per-module validation function ───────────────────────────────────────────
validate_module() {
    local MODULE="$1"
    local BICEP_FILE="${MODULE}/bicep/main.bicep"
    local PARAM_FILE="${MODULE}/bicep/main.bicepparam"
    local MODULE_SLUG
    MODULE_SLUG=$(basename "$MODULE")
    local REPORT_DIR="reports/${MODULE_SLUG}"
    local TS
    TS=$(date +"%Y-%m-%d_%H-%M-%S")
    local REPORT_FILE="${REPORT_DIR}/validate-${TS}.log"
    local ARM_OUT="${REPORT_DIR}/main.arm.json"
    local PARAM_OUT="${REPORT_DIR}/main.arm.params.json"
    local SARIF_OUT="${REPORT_DIR}/psrule.sarif"

    local PASS=0 FAIL=0 SKIP=0
    local STEP_FAILS=()

    _log()    {
        printf '%b\n' "$*"
        printf '%b\n' "$*" | sed 's/\x1b\[[0-9;]*[mK]//g' >> "$REPORT_FILE"
    }
    _section() {
        _log ""
        _log "${C_BLUE}${C_BOLD}  $*${C_NC}"
        _log "${C_BLUE}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"
    }
    _pass()   { PASS=$((PASS+1));  _log "${C_GREEN}  ✓  PASS  ${C_NC} $*"; }
    _fail()   { FAIL=$((FAIL+1));  _log "${C_RED}  ✗  FAIL  ${C_NC} $*"; }
    _skip()   { SKIP=$((SKIP+1));  _log "${C_YELLOW}  ○  SKIP  ${C_NC} $*"; }
    _info()   { _log "           $*"; }
    _raw()    { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$REPORT_FILE"; }

    mkdir -p "$REPORT_DIR"
    : > "$REPORT_FILE"
    ln -sf "$(basename "$REPORT_FILE")" "${REPORT_DIR}/validate-latest.log" 2>/dev/null || true

    _log ""
    _log "${C_BOLD}${C_BLUE}╔══════════════════════════════════════════════════════╗${C_NC}"
    _log "${C_BOLD}${C_BLUE}║  Azure Reference Architecture - Validation Pipeline  ║${C_NC}"
    _log "${C_BOLD}${C_BLUE}╚══════════════════════════════════════════════════════╝${C_NC}"
    _log ""
    _log "  Module   : ${MODULE}"
    _log "  Template : ${BICEP_FILE}"
    _log "  Params   : ${PARAM_FILE}"
    _log "  Started  : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    _log "  Commit   : $(git rev-parse --short HEAD 2>/dev/null || echo 'N/A')"
    _log "  Branch   : $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'N/A')"
    _log "  Report   : ${REPORT_FILE}"

    if [[ ! -f "$BICEP_FILE" ]]; then
        _log ""
        _log "${C_YELLOW}  ○  SKIP: No main.bicep found at ${BICEP_FILE} - module not yet implemented.${C_NC}"
        return 0
    fi

    # =========================================================================
    # STEP 0 - Prerequisites (recorded in per-module log)
    # =========================================================================
    _section "Step 0 - Prerequisites"
    local AZ_VER BICEP_VER
    AZ_VER=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo '?')
    BICEP_VER=$(az bicep version 2>&1 | head -1 || echo '?')
    _pass "az CLI  v${AZ_VER}  |  az bicep  ${BICEP_VER}"
    _pass "$(pwsh --version 2>&1)"
    _pass "$(python3 --version 2>&1)"
    if [[ $PSRULE_OK -eq 1 ]]; then
        _pass "PSRule.Rules.Azure  (available)"
    else
        _fail "PSRule.Rules.Azure  not available - Step 6 will fail"
        STEP_FAILS+=("Step 0: PSRule.Rules.Azure missing")
    fi
    if [[ $BETTERLEAKS_OK -eq 1 ]]; then
        _pass "betterleaks  v$(betterleaks version 2>&1 | head -1)"
    else
        _fail "betterleaks  not available - Step 1 will fail"
        STEP_FAILS+=("Step 0: betterleaks missing")
    fi

    # =========================================================================
    # STEP 1 - Secret Scan
    # =========================================================================
    _section "Step 1 - Secret Scan  (betterleaks)"

    if [[ $BETTERLEAKS_OK -eq 1 ]]; then
        local BL_OUT BL_EXIT=0
        BL_OUT=$(betterleaks git . -v 2>&1) && BL_EXIT=0 || BL_EXIT=$?
        _raw "$BL_OUT"
        if [[ $BL_EXIT -ne 0 ]]; then
            _fail "betterleaks: potential secrets detected - review output above"
            STEP_FAILS+=("Step 1: Secret scan (betterleaks)")
        else
            _pass "betterleaks: no secrets detected in git history"
        fi
    else
        _fail "betterleaks not available - secret scan failed (installation was attempted above)"
        STEP_FAILS+=("Step 1: betterleaks not installed")
    fi

    # =========================================================================
    # STEP 2 - YAML Lint
    # =========================================================================
    _section "Step 2 - YAML Lint  (python3 yaml.safe_load)"

    local YAML_STEP_FAIL=0
    while IFS= read -r yf; do
        local ERR PY_EXIT=0
        ERR=$(python3 -c "import yaml; yaml.safe_load(open('$yf'))" 2>&1) && PY_EXIT=0 || PY_EXIT=$?
        if [[ $PY_EXIT -ne 0 ]]; then
            YAML_STEP_FAIL=1
            _fail "$yf"
            _info "$ERR"
        else
            _pass "$yf"
        fi
    done < <(find . \( -name "*.yml" -o -name "*.yaml" \) ! -path "./.git/*" 2>/dev/null | sort)

    if [[ $YAML_STEP_FAIL -ne 0 ]]; then
        STEP_FAILS+=("Step 2: YAML lint")
    fi

    # =========================================================================
    # STEP 3 - Bicep Lint
    # =========================================================================
    _section "Step 3 - Bicep Lint  (az bicep lint + bicepconfig.json)"

    local LINT_OUT LINT_EXIT=0
    LINT_OUT=$(az bicep lint --file "$BICEP_FILE" 2>&1) && LINT_EXIT=0 || LINT_EXIT=$?
    [[ -n "$LINT_OUT" ]] && _raw "$LINT_OUT"

    if [[ $LINT_EXIT -ne 0 ]] || echo "$LINT_OUT" | grep -qiE '\berror\b'; then
        _fail "Bicep lint: errors found in ${BICEP_FILE}"
        STEP_FAILS+=("Step 3: Bicep lint")
    elif [[ -n "$LINT_OUT" ]]; then
        _pass "Bicep lint: warnings present (no errors) - ${BICEP_FILE}"
    else
        _pass "Bicep lint: clean - no diagnostics"
    fi

    # =========================================================================
    # STEP 4 - Bicep Build
    # =========================================================================
    _section "Step 4 - Bicep Build  (az bicep build + build-params)"

    local BUILD_OUT BUILD_EXIT=0
    BUILD_OUT=$(az bicep build --file "$BICEP_FILE" --outfile "$ARM_OUT" 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?
    [[ -n "$BUILD_OUT" ]] && _raw "$BUILD_OUT"

    if [[ $BUILD_EXIT -ne 0 ]] || ! [[ -f "$ARM_OUT" ]]; then
        _fail "main.bicep compilation failed"
        STEP_FAILS+=("Step 4: Bicep build (main.bicep)")
    else
        local ARM_SIZE
        ARM_SIZE=$(wc -c < "$ARM_OUT" 2>/dev/null || echo '?')
        _pass "main.bicep  →  ${ARM_OUT}  (${ARM_SIZE} bytes)"
    fi

    local BUILDP_OUT BUILDP_EXIT=0
    BUILDP_OUT=$(az bicep build-params --file "$PARAM_FILE" --outfile "$PARAM_OUT" 2>&1) && BUILDP_EXIT=0 || BUILDP_EXIT=$?
    [[ -n "$BUILDP_OUT" ]] && _raw "$BUILDP_OUT"

    if [[ $BUILDP_EXIT -ne 0 ]]; then
        _fail "main.bicepparam compilation failed"
        STEP_FAILS+=("Step 4: Bicep build (main.bicepparam)")
    else
        _pass "main.bicepparam  →  ${PARAM_OUT}"
    fi

    # =========================================================================
    # STEP 5 - Tag Sentinel
    # =========================================================================
    _section "Step 5 - Tag Sentinel  (no 'Missing' placeholder tag values)"

    local TAG_STEP_FAIL=0

    # Check the compiled ARM params output - this reflects what would actually be
    # deployed. If a params file wasn't supplied (or has gaps), Bicep falls back to
    # the main.bicep defaults which are intentionally seeded with 'Missing X'.
    # Failing here means: tags won't be set correctly in the real deployment.
    if [[ -f "$PARAM_OUT" ]]; then
        local PARAMS_CHECK
        PARAMS_CHECK=$(python3 - "$PARAM_OUT" <<'PYEOF'
import json, sys, re
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError) as e:
    print(f"SKIP:{e}")
    sys.exit(0)
parameters = data.get('parameters', {})
bad = []
for name, meta in parameters.items():
    if re.match(r'^tag', name, re.IGNORECASE):
        value = meta.get('value', '')
        if isinstance(value, str) and re.search(r'\bMissing\b', value, re.IGNORECASE):
            bad.append(f"{name}='{value}'")
if bad:
    print("FAIL:" + "; ".join(bad))
else:
    print("PASS")
PYEOF
        )
        if [[ "$PARAMS_CHECK" == PASS ]]; then
            _pass "Compiled params: all tag values explicitly set - no 'Missing' placeholders in deployment output"
        elif [[ "$PARAMS_CHECK" == SKIP:* ]]; then
            _skip "Compiled params check: ${PARAMS_CHECK#SKIP:}"
        elif [[ "$PARAMS_CHECK" == FAIL:* ]]; then
            TAG_STEP_FAIL=1
            _fail "Compiled params contain 'Missing' placeholder tag values - deployment would tag resources incorrectly"
            _info "Affected: ${PARAMS_CHECK#FAIL:}"
            _info "Action  : ensure ${PARAM_FILE} supplies explicit values for all tag parameters"
        fi
    else
        _skip "Compiled params check skipped (Step 4 build failed)"
    fi

    if [[ $TAG_STEP_FAIL -ne 0 ]]; then
        STEP_FAILS+=("Step 5: Tag sentinel")
    fi

    # =========================================================================
    # STEP 6 - PSRule for Azure
    # =========================================================================
    _section "Step 6 - PSRule for Azure  (WAF alignment + Local.Rule.ps1)"
    _info "Runs against compiled ARM JSON - no Bicep expansion needed."
    _info "0 results = FAIL: PSRule must evaluate at least one resource."

    if [[ $PSRULE_OK -eq 1 ]] && [[ -f "$ARM_OUT" ]]; then
        _info ""
        _info "Running PSRule - this may take 60–120 s on first run..."
        _info ""

        local PSRULE_OUT PSRULE_EXIT=0
        PSRULE_OUT=$(pwsh -NoProfile -File "scripts/_psrule-run.ps1" \
           -BicepFile "$BICEP_FILE" \
           -SarifOut "$SARIF_OUT" \
            2>&1) && PSRULE_EXIT=0 || PSRULE_EXIT=$?

        while IFS= read -r line; do _raw "$line"; done <<< "$PSRULE_OUT"

        local SUMMARY_LINE SUMMARY_VALS
        SUMMARY_LINE=$(echo "$PSRULE_OUT" | grep "PSRULE_SUMMARY:" | tail -1 || true)
        SUMMARY_VALS="${SUMMARY_LINE#PSRULE_SUMMARY:}"

        if [[ $PSRULE_EXIT -eq 2 ]]; then
            _fail "PSRule execution error - see output above"
            STEP_FAILS+=("Step 6: PSRule (execution error)")
        elif [[ $PSRULE_EXIT -eq 1 ]]; then
            if echo "$PSRULE_OUT" | grep -q "PSRULE_FAILURES:"; then
                _fail "PSRule: rule failures detected  (${SUMMARY_VALS})"
            else
                _fail "PSRule: 0 resources evaluated - Bicep expansion may have failed"
                _info "Check that az bicep is installed and AZURE_BICEP_FILE_EXPANSION is true in .ps-rule/ps-rule.yaml"
            fi
            [[ -f "$SARIF_OUT" ]] && _info "SARIF report: ${SARIF_OUT}"
            STEP_FAILS+=("Step 6: PSRule")
        elif [[ -n "$SUMMARY_LINE" ]]; then
            local TOTAL
            TOTAL=$(echo "$SUMMARY_VALS" | python3 -c \
                "import sys, re; v=sys.stdin.read(); nums=re.findall(r'=(\d+)', v); print(sum(int(x) for x in nums))" \
                2>/dev/null || echo '0')
            if [[ "$TOTAL" -eq 0 ]]; then
                _fail "PSRule: 0 results - no resources were evaluated. Check Bicep expansion is working."
                STEP_FAILS+=("Step 6: PSRule (zero results)")
            else
                _pass "PSRule: all rules passed  (${SUMMARY_VALS})"
                [[ -f "$SARIF_OUT" ]] && _info "SARIF report: ${SARIF_OUT}"
            fi
        else
            _fail "PSRule: no summary line returned - PSRule may have failed silently"
            STEP_FAILS+=("Step 6: PSRule (no output)")
        fi
    elif [[ $PSRULE_OK -eq 0 ]]; then
        _fail "PSRule.Rules.Azure unavailable - WAF validation failed"
        STEP_FAILS+=("Step 6: PSRule (module not installed)")
    else
        _skip "PSRule skipped - ARM template not available (Step 4 build failed)"
    fi

    # =========================================================================
    # Module summary
    # =========================================================================
    _section "Summary - ${MODULE}"
    _log "  Checks passed  : ${C_GREEN}${PASS}${C_NC}"
    _log "  Checks failed  : ${C_RED}${FAIL}${C_NC}"
    _log "  Checks skipped : ${C_YELLOW}${SKIP}${C_NC}"
    _log ""
    _log "  Finished  : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    _log "  Report    : ${REPORT_FILE}"
    _log ""

    if [[ ${#STEP_FAILS[@]} -gt 0 ]]; then
        _log "${C_RED}${C_BOLD}  ✗  VALIDATION FAILED - ${MODULE}${C_NC}"
        for sf in "${STEP_FAILS[@]}"; do
            _log "${C_RED}     ✗  ${sf}${C_NC}"
        done
        _log ""
        return 1
    else
        _log "${C_GREEN}${C_BOLD}  ✓  ALL CHECKS PASSED - ${MODULE}${C_NC}"
        _log ""
        return 0
    fi
}

# ── Run across all selected modules ──────────────────────────────────────────
OVERALL_FAIL=0
FAILED_MODULES=()

if [[ ${#MODULES[@]} -gt 1 ]]; then
    printf '%b\n' ""
    printf '%b\n' "${C_BOLD}${C_BLUE}Validating ${#MODULES[@]} module(s): ${MODULES[*]}${C_NC}"
fi

for MOD in "${MODULES[@]}"; do
    validate_module "$MOD" || {
        OVERALL_FAIL=1
        FAILED_MODULES+=("$MOD")
    }
done

# ── Final multi-module summary ────────────────────────────────────────────────
if [[ ${#MODULES[@]} -gt 1 ]]; then
    printf '%b\n' ""
    printf '%b\n' "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"
    printf '%b\n' "${C_BOLD}${C_BLUE}  Overall Result - ${#MODULES[@]} modules${C_NC}"
    printf '%b\n' "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"
    for MOD in "${MODULES[@]}"; do
        if printf '%s\n' "${FAILED_MODULES[@]+"${FAILED_MODULES[@]}"}" | grep -qx "$MOD"; then
            printf '%b\n' "  ${C_RED}✗  FAIL  ${C_NC} ${MOD}"
        else
            printf '%b\n' "  ${C_GREEN}✓  PASS  ${C_NC} ${MOD}"
        fi
    done
    printf '%b\n' ""
fi

exit $OVERALL_FAIL
