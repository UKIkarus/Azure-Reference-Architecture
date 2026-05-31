# PSRule Remediation Report: 01-Core-Networking

> **WAF Baseline:** Security + Reliability pillars (333 of 519 rules)  
> **Tool:** PSRule.Rules.Azure v1.47.0 with `Local.SecurityAndReliability` baseline  
> **Evaluated resources:** 162 unique Azure resources expanded from `main.bicep` via `az bicep`

---

## First-Run Failures

Initial validation against the unmodified Bicep produced **9 failures across 156 resources**.

```
PSRULE_SUMMARY: Pass=738; Fail=9; Error=0; Resources=156

[FAIL] Azure.Firewall.PolicyMode       | dev-hub-afwpolicy
       Path Properties.threatIntelMode: Is set to 'Alert'.

[FAIL] Azure.Log.Replication           | dev-hub-law
       Path properties.replication.enabled: The field 'properties.replication.enabled' does not exist.

[FAIL] Azure.NSG.LateralTraversal      | dev-hub-mgmt-nsg
       A rule to limit lateral traversal was not found.

[FAIL] Azure.NSG.LateralTraversal      | dev-hub-dnsresolver-inbound-nsg
       A rule to limit lateral traversal was not found.

[FAIL] Azure.NSG.LateralTraversal      | dev-app-workload-nsg
       A rule to limit lateral traversal was not found.

[FAIL] Azure.Storage.LocalAuth         | devflwlogs5f3e65afb63bb
       Path properties.allowSharedKeyAccess: Is set to 'True'.

[FAIL] Azure.Storage.UseReplication    | devflwlogs5f3e65afb63bb
       Path sku.name: The field value 'Standard_LRS' was not included in the set.

[FAIL] Azure.VNET.UseNSGs              | dev-hub-vnet
       The subnet (dev-hub-vnet/AzureBastionSubnet) has no NSG associated.
       The subnet (dev-hub-vnet/snet-dnsresolver-outbound) has no NSG associated.

[FAIL] Azure.VNG.MaintenanceConfig     | dev-hub-ergw
       The virtual network gateway 'dev-hub-ergw' should have a customer-controlled maintenance
       configuration associated.
```

---

## Fixes Applied

### 1 · `Azure.Firewall.PolicyMode`: Enable threat intelligence deny mode

**WAF Pillar:** Security  
**Resource:** `dev-hub-afwpolicy` (`firewall.bicep`)

**Root cause:** `threatIntelMode` was set to `'Alert'`, logging detections but not blocking them.  
The WAF Security pillar requires active blocking (`'Deny'`) for known-malicious IPs and FQDNs curated
by Microsoft Threat Intelligence. `'Alert'` mode is insufficient as a hard security gate.

Additionally, `intrusionDetection.mode` (IDPS) was not configured at all, so it must be explicitly set on
Premium-tier firewall policies.

**Fix (`firewall.bicep`):**
```bicep
// Before
threatIntelMode: 'Alert'

// After
threatIntelMode: 'Deny'
intrusionDetection: {
  mode: 'Alert'   // Alert (log) IDPS detections; use 'Deny' in production to block
}
```

**Why:** `'Deny'` for threat intelligence blocks known-bad destinations at the policy level with zero
false-positive risk, as the IP/FQDN feed is curated, not heuristic. IDPS is set to `'Alert'` as a
starting point so pattern-based detections are logged before potentially blocking legitimate traffic in
a dev environment.

---

### 2 · `Azure.NSG.LateralTraversal` × 3: Block lateral SSH/RDP from all subnets

**WAF Pillar:** Security  
**Resources:** `dev-hub-mgmt-nsg`, `dev-hub-dnsresolver-inbound-nsg`, `dev-app-workload-nsg`  
**Files:** `hub-networking.bicep`, `spoke-networking.bicep`

**Root cause:** No NSG contained explicit outbound deny rules for SSH (22) or RDP (3389) to
`VirtualNetwork`. Without these, a compromised VM in any subnet could initiate management sessions
to any other VM in the network, a classic lateral movement attack path.

**Fix (all three NSGs):**
```bicep
{
  name: 'Deny-Outbound-SSH'
  properties: {
    priority: 3000
    protocol: 'Tcp'
    access: 'Deny'
    direction: 'Outbound'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: 'VirtualNetwork'
    destinationPortRange: '22'
    description: 'Block lateral SSH; use Azure Bastion for remote access.'
  }
}
{
  name: 'Deny-Outbound-RDP'
  properties: {
    priority: 3100
    protocol: 'Tcp'
    access: 'Deny'
    direction: 'Outbound'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: 'VirtualNetwork'
    destinationPortRange: '3389'
    description: 'Block lateral RDP; use Azure Bastion for remote access.'
  }
}
```

**Why:** Zero Trust requires that no VM can reach another VM's management port directly. All
SSH/RDP must flow through Azure Bastion, which provides session recording, MFA enforcement, and
JIT access, none of which are possible with direct SSH/RDP.

The management subnet (`snet-management`) is NOT exempt: even jump server VMs should connect
via Bastion, not direct TCP. This prevents privilege escalation via a compromised management host.

---

### 3 · `Azure.Storage.LocalAuth`: Disable shared key authentication

**WAF Pillar:** Security  
**Resource:** `devflwlogs5f3e65afb63bb` (`main.bicep`)

**Root cause:** `allowSharedKeyAccess` defaulted to `true`, permitting authentication via storage
account keys, which are long-lived, non-auditable credentials that cannot be scoped to a principal or
revoked without key rotation.

**Fix (`main.bicep`):**
```bicep
// Added
allowSharedKeyAccess: false
```

**Why:** Shared keys bypass Entra ID RBAC entirely. Any process with the key has full data-plane
access. Disabling forces all clients (Network Watcher flow log service, monitoring pipelines) to
authenticate via managed identity, which is auditable, revocable, and principle-of-least-privilege.

---

### 4 · `Azure.Storage.UseReplication`: Zone-redundant storage for flow logs

**WAF Pillar:** Reliability  
**Resource:** `devflwlogs5f3e65afb63bb` (`main.bicep`)

**Root cause:** `skuName` was `Standard_LRS` (single zone). If the zone hosting the storage account
fails, flow log data for that period is unrecoverable, potentially breaking compliance and forensics
requirements.

**Fix (`main.bicep`):**
```bicep
// Before
skuName: 'Standard_LRS'

// After
skuName: 'Standard_ZRS'
```

**Why:** NSG flow logs are the primary network forensics record. Zone redundancy ensures availability
during AZ failure, which is critical for post-incident investigation. The cost delta between LRS and ZRS for
flow log volume is negligible.

---

### 5 · `Azure.VNET.UseNSGs`: NSG for `AzureBastionSubnet` and DNS outbound subnet

**WAF Pillar:** Security  
**Resource:** `dev-hub-vnet` (`hub-networking.bicep`)

**Root cause:** Two subnets had no Network Security Group:

1. **`AzureBastionSubnet`**: Microsoft mandates a specific NSG on this subnet; without it the
   subnet is uncontrolled and Bastion does not behave deterministically under attack.
2. **`snet-dnsresolver-outbound`**: the code comment incorrectly stated NSGs are unsupported
   on DNS resolver outbound subnets. Azure DNS Private Resolver outbound subnets **do** support
   NSGs. The subnet was left unprotected unnecessarily.

**Fix: new `nsgBastion` module (`hub-networking.bicep`):**
Full Microsoft-mandated rule set for `AzureBastionSubnet`:
- **Inbound:** Allow HTTPS from Internet, Allow GatewayManager on 443, Allow AzureLoadBalancer on 443,
  Allow VirtualNetwork on 8080+5701, Deny all else
- **Outbound:** Allow SSH/RDP to VirtualNetwork (required for Bastion sessions), Allow AzureCloud on 443,
  Allow Internet on 80 (cert validation), Allow VirtualNetwork on 8080+5701

> `Azure.NSG.LateralTraversal` is suppressed for `dev-hub-bastion-nsg`, see the suppressions section below.

**Fix: new `nsgDnsResolverOutbound` module (`hub-networking.bicep`):**
Simple NSG blocking lateral movement since the DNS resolver outbound endpoint has no reason to
initiate SSH or RDP sessions.

---

### 6 · `Azure.VNG.MaintenanceConfig`: ⚠ Suppressed (deferred to Module 04)

**WAF Pillar:** Reliability  
**Resource:** `dev-hub-ergw`

**Suppressed in:** `.ps-rule/ps-rule.yaml`

**Justification:** Customer-controlled maintenance windows for ExpressRoute gateways require a
`Microsoft.Maintenance/maintenanceConfigurations` resource and a `configurationAssignment`, neither
of which are exposed by the AVM `virtual-network-gateway:0.11.1` module. This is an operational
concern that will be implemented in **Module 04: Observability & Policy** alongside Azure Policy
assignments and Azure Monitor alert rules.

```yaml
# .ps-rule/ps-rule.yaml
suppression:
  Azure.VNG.MaintenanceConfig:
   - dev-hub-ergw
```

---

### 7 · `Azure.Log.Replication`: ⚠ Suppressed (deferred to Module 05)

**WAF Pillar:** Reliability  
**Resource:** `dev-hub-law`

**Suppressed in:** `.ps-rule/ps-rule.yaml`

**Justification:** Log Analytics cross-region replication is a disaster recovery feature that requires
a secondary Azure region and a paired workspace. This is out of scope for the core networking bootstrap.
The full DR topology, including workspace replication, geo-redundant storage, and Traffic Manager
failover, will be implemented in **Module 05: Multi-Region DR**.

```yaml
# .ps-rule/ps-rule.yaml
suppression:
  Azure.Log.Replication:
   - dev-hub-law
```

---

## Suppression Register

| Rule | Target | Justification | Resolved in |
|---|---|---|---|
| `Azure.VNG.MaintenanceConfig` | `dev-hub-ergw` | AVM module gap; operational concern | Module 04 |
| `Azure.Log.Replication` | `dev-hub-law` | Requires secondary region topology | Module 05 |
| `Azure.NSG.LateralTraversal` | `dev-hub-bastion-nsg` | Bastion by design initiates SSH/RDP to VMs | N/A (by design) |

---

## Post-Infrastructure-Fix Validation

> **Note:** This was the state after fixing the 9 Azure resource failures above, but *before* we fixed
> the PSRule custom rule pipeline. The resource count and pass count both changed again later - see
> [Custom Tag Rule: The Bug Hunt](#custom-tag-rule-the-bug-hunt) below.

After all changes above, running `bash scripts/validate-local.sh 01-Core-Networking` produced:

```
PSRULE_SUMMARY: Pass=772; Fail=0; Error=0; Resources=162
PSRULE_OK
  ✓  PASS   PSRule: all rules passed  (Pass=772;Fail=0;Error=0;Resources=162)

  Summary - 01-Core-Networking
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Checks passed  : 14
  Checks failed  : 0
  Checks skipped : 0

  ✓  ALL CHECKS PASSED - 01-Core-Networking
```

**16 additional resources evaluated** (156 → 162) due to the two new NSGs and their diagnostic settings.  
**34 additional passing checks** (738 → 772) for the new NSG rules.

---

## Custom Tag Rule: The Bug Hunt

With all the Azure resource failures resolved, the next goal was straightforward: add a custom PSRule
governance rule that catches deployments where someone forgets to fill in the tag parameters in
`main.bicepparam`. The idea was simple - `main.bicep` has sentinel defaults like `'Missing Owner'`
and `'Missing Department'`, so any resource that carries one of those values has leaked param
defaults into a real deployment. The rule should catch that. Write it once, gate it in CI forever.

It took four failed attempts before it worked. Here's what actually happened.

---

### What we were trying to build

A PSRule rule in `.ps-rule/Local.Rule.ps1` that:
- Looks at every resource with a `tags` property
- Checks whether any tag value contains the word `'Missing'`
- FAILS if it finds one, with a message naming exactly which tags are wrong
- PASSES silently if everything looks clean

Simple enough. The test plan: comment out `tagOwner` and `tagDepartment` in `main.bicepparam`,
run validation, confirm 102 FAILS, restore the params, confirm 0 FAILS. Done.

Except PSRule kept coming back `Pass=0;Fail=0` - the rule wasn't firing at all.

---

### Bug 1 - `-Type '*'` is not a wildcard

The original rule was written like this:

```powershell
Rule 'Local.Tags.NoMissingTagValues' -Type '*' {
    ...
}
```

The reasoning was: "I want this to run against every resource type, so I'll use `*` as a wildcard."
That is completely wrong and PSRule gives no warning about it.

In PSRule, `-Type '*'` is a **literal type filter**. It only matches objects whose `.PSObject.TypeNames`
contains the exact string `'*'`. No Azure resource has a type called `'*'`. So the rule evaluated
exactly zero objects, every time, and PSRule counted that as 0 failures - not an error, not a
warning, just silent nothing.

**Fix:** Remove `-Type` entirely. When `-Type` is omitted, PSRule evaluates the rule against every
object it processes. That's the actual "run against everything" behaviour.

```powershell
# Before (silently broken)
Rule 'Local.Tags.NoMissingTagValues' -Type '*' { ... }

# After (actually runs)
Rule 'Local.Tags.NoMissingTagValues' { ... }
```

---

### Bug 2 - The baseline was silently excluding our custom rule

After fixing Bug 1, the rule still didn't fire. The next thing to check was whether the baseline was
filtering it out.

The `Local.SecurityAndReliability` baseline works by requiring rules to carry an `Azure.WAF/pillar`
tag set to `Security` or `Reliability`. Built-in PSRule.Rules.Azure rules all have this tag. Our
custom rule had no tags at all, so the baseline filter excluded it.

```yaml
# Baselines.Rule.yaml - the baseline filter that was excluding us
spec:
  rule:
    tag:
      'Azure.WAF/pillar':
        - Security
        - Reliability
```

Technically PSRule does produce a result for the rule - it marks it as `Skipped`. But in
`_psrule-run.ps1` we invoke PSRule with `-Outcome Fail,Pass,Error`, which explicitly drops
`Skipped` results from the pipeline output. The reasoning was sound: with 246 resources × 533 rules,
roughly 99% of combinations are skips because most rules only apply to specific resource types
(e.g. `Azure.KeyVault.*` doesn't run against a VNet). Showing all of those would drown out the
actual signal.

The side effect: a custom rule that the baseline filters to `Skipped` becomes completely invisible.
The summary shows the exact same numbers as a full pass. There's no `Skip=N` counter, no warning,
nothing. Without knowing to look for it, you'd never suspect the rule wasn't running.

**Fix:** Add the WAF pillar tag to the custom rule:

```powershell
Rule 'Local.Tags.NoMissingTagValues' -Tag @{ 'Azure.WAF/pillar' = 'Reliability' } {
    ...
}
```

`Reliability` was the right choice here - a deployment with unfilled tag placeholders is a
governance/operations failure that degrades your ability to track cost, ownership, and incidents.

---

### Bug 3 - PSRule was ignoring main.bicepparam entirely

After fixing both of the above, the rule ran - but it produced false FAILS even when all tags
were correctly set in `main.bicepparam`. Every resource showed `Owner='Missing Owner'` regardless.

This one took the longest to understand.

When `_psrule-run.ps1` called `Invoke-PSRule -InputPath main.bicep`, PSRule expanded the Bicep
file using only the parameter defaults baked into `main.bicep` itself. It never read
`main.bicepparam`. All five "Missing X" sentinel defaults appeared on every resource because,
from PSRule's perspective, no one had overridden them.

The fix is `AZURE_BICEP_PARAMS_FILE_EXPANSION: true` in `ps-rule.yaml` - which was already set —
but it only activates when PSRule is given a `.bicepparam` file as its input. Pointing it at the
`.bicep` file bypasses the whole thing, a simple error on my part but an easy one to miss!

**Fix:** Detect the paired `.bicepparam` file and use it as `-InputPath`:

```powershell
$ParamFile = [System.IO.Path]::ChangeExtension($BicepFile, '.bicepparam')
$psruleInput = if (Test-Path $ParamFile) {
    Write-Host "[psrule-run] Using bicepparam for full parameter resolution: $ParamFile"
    $ParamFile
} else {
    Write-Host "[psrule-run] No paired .bicepparam found - using bicep file: $BicepFile"
    $BicepFile
}
```

PSRule pairs the `.bicepparam` with its `using 'main.bicep'` reference, resolves all param values,
and the rule now sees the actual tag values from the param file.

This also explains why the resource count jumped from 162 to **246** - when using the `.bicepparam`
as input, PSRule's Bicep expansion resolves nested AVM registry modules more completely, surfacing
additional resources that were previously invisible.

---

### The end-to-end test

With all three bugs fixed, the test finally worked as intended.

**Run 1 - tags missing (tagOwner and tagDepartment commented out in main.bicepparam):**
```
PSRULE_SUMMARY: Pass=916; Fail=102; Error=0; Resources=246

  [FAIL] Local.Tags.NoMissingTagValues  |  dev-hub-vnet
         Resource 'dev-hub-vnet' has tag value(s) containing the placeholder 'Missing'.
         Affected: Owner='Missing Owner'; Department='Missing Department'

  [FAIL] Local.Tags.NoMissingTagValues  |  dev-hub-fw
         ...
  # 100 more like this across all tagged resources
```

**Run 2 - tags restored:**
```
PSRULE_SUMMARY: Pass=1018; Fail=0; Error=0; Resources=246
PSRULE_OK
```

The 102 failures were exactly right: every resource that carries tags got a FAIL when the placeholder
values were present, and every one of those went green when the real values were restored. Critically,
the rule only flagged `Owner` and `Department` - the two params that were commented out - and not
`CostCenter`, `Project`, or `CreatedBy`, which were set correctly throughout. The signal was clean.

---

### Lessons learned

**PSRule `-Type '*'` is an easy mistake to make.** There is nothing in the docs, the error output, or the rule
author experience that warns you this is a literal match. If your custom rule silently evaluates
zero objects and you're not explicitly asserting a minimum result count, you'll never know. Always
omit `-Type` if you genuinely want all objects, and add a sanity check like `$results.Count -gt 0`
in the calling script.

**Baselines filter to `Skipped`, and if you're suppressing skips in your output, that's invisible.**
If your custom rule doesn't carry the right tag to pass the baseline filter, PSRule marks every
evaluation of it as `Skipped` - not as an error, not as a warning. If your invocation uses
`-Outcome Fail,Pass,Error` (which is the right call for keeping output readable), those skips are
dropped entirely. The summary shows the same numbers as a full pass. Always verify a new custom rule
actually appears in the evaluated set by checking
`$results | Where-Object RuleName -eq 'YourRuleName'` before trusting a clean result.

**PSRule input file matters for param resolution.** Using `.bicep` as `-InputPath` means PSRule
expands with Bicep's own defaults. Using `.bicepparam` means PSRule resolves the full deployment
picture - actual param values, all nested modules. If your rules depend on what will actually be
deployed (tags, config values, SKUs), always point PSRule at the `.bicepparam` file.

---

## Final Validation State

After all the infrastructure fixes and PSRule pipeline fixes above, running
`bash scripts/validate-local.sh 01-Core-Networking` now produces:

```
PSRULE_SUMMARY: Pass=1018; Fail=0; Error=0; Resources=246
PSRULE_OK
  ✓  PASS   PSRule: all rules passed  (Pass=1018;Fail=0;Error=0;Resources=246)

  Summary - 01-Core-Networking
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Checks passed  : 14
  Checks failed  : 0
  Checks skipped : 0

  ✓  ALL CHECKS PASSED - 01-Core-Networking
```

**Change summary from initial first-run state:**

| Metric | Initial | Post-infra fixes | Final |
|---|---|---|---|
| Resources evaluated | 156 | 162 | 246 |
| Pass | 738 | 772 | 1018 |
| Fail | 9 | 0 | 0 |
| Custom rule active | ✗ | ✗ | ✅ |

The jump from 162 → 246 resources is due to PSRule now reading `main.bicepparam` as its input
(the bicepparam expansion fix), which resolves nested AVM registry modules more completely than
expanding the `.bicep` file directly.

---

## GitHub Actions Integration

The [`bicep-ci.yml`](../../.github/workflows/bicep-ci.yml) workflow runs this same pipeline on every
pull request and push to `main`. PSRule SARIF output is uploaded as a workflow artifact and annotated
directly on the PR using the `github/codeql-action/upload-sarif` action.

**What gets checked on every PR:**

| Step | Tool | Gate |
|---|---|---|
| Secret scan | `betterleaks` | No credentials in git history |
| YAML lint | `python3 yaml.safe_load` | No malformed workflow/config files |
| Bicep lint | `az bicep lint` | No Bicep errors |
| Bicep build | `az bicep build` | Template compiles cleanly |
| Tag sentinel | Python + compiled params | No `Missing` placeholder tag values |
| PSRule (Security + Reliability) | `PSRule.Rules.Azure v1.47.0` | 0 WAF failures across 246 resources |

To run locally before pushing:
```bash
bash scripts/validate-local.sh 01-Core-Networking
# or all modules:
bash scripts/validate-local.sh --all
```
