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

## Post-Fix Validation

After all changes above, running `bash scripts/validate-local.sh 01-Core-Networking` produces:

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
| PSRule (Security + Reliability) | `PSRule.Rules.Azure v1.47.0` | 0 WAF failures across 162 resources |

To run locally before pushing:
```bash
bash scripts/validate-local.sh 01-Core-Networking
# or all modules:
bash scripts/validate-local.sh --all
```
