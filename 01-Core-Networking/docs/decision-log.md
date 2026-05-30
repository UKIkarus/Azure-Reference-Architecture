# 01 - Core Networking: Architecture Decision Log

> This document records the key design decisions for the Core Networking module,
> the rationale behind each choice, and the alternatives considered.
> It is intended to evidence principal-level architectural thinking for
> enterprise environments at scale.

---

## ADR-01: Hub-and-Spoke Topology aligned to Azure Landing Zones (ALZ)

**Decision:** Deploy a single hub VNet hosting all shared infrastructure (Firewall, Bastion, ExpressRoute Gateway, DNS Resolver), with spoke VNets peered to the hub rather than to each other.

**Rationale:**
- ALZ hub-and-spoke is the Microsoft-recommended pattern for enterprise tenants. It provides a single egress point for security inspection, centralised policy enforcement, and a clean blast radius boundary between workloads.
- Peering is transitive only via the hub, so workload spokes cannot communicate laterally without traversing the firewall, enforcing east-west inspection by default.
- This model scales linearly: each new workload team deploys their own spoke (`spoke-networking.bicep` is parameterised and reusable) without touching the shared hub.

**Alternatives considered:**
- **Flat VNet with NSGs only**: insufficient for Zero Trust. NSGs are stateful L4 filters; they cannot perform FQDN-based filtering, TLS inspection, or IDPS. Though for demonstration purposes and cost savings this could be used at smaller scales, Rejected.
- **Azure Virtual WAN**: appropriate for 10+ spoke topology or SD-WAN integration. Adds cost and operational complexity not justified for this portfolio stage. Revisit at module 05 for multi-region DR.

---

## ADR-02: Azure Firewall Premium over Standard

**Decision:** Deploy Azure Firewall Premium (`firewallTier = 'Premium'`) as the default tier.

**Rationale:**
- Premium tier enables IDPS (Intrusion Detection and Prevention System), TLS inspection, and URL category-based filtering, all capabilities required for a Zero Trust security posture at enterprise scale.
- In a large multi-user environment, IDPS is a compliance requirement (ISO 27001, NIST CSF), not a nice-to-have. Standard tier cannot satisfy this.
- Cost delta between Standard and Premium is ~£0.35/hour. At enterprise scale this is negligible against the risk of not having east-west and north-south threat detection.
- The `firewallTier` parameter is selectable (`Standard | Premium`) with `'Premium'` as the safe default; operators can choose Standard for dev environments via `.bicepparam` without touching the template.

**Alternatives considered:**
- **NVA (Network Virtual Appliance, e.g. Palo Alto, Fortinet)**: higher throughput ceiling and richer feature set. Appropriate for 100Gbps+ or specific compliance mandates (PCI-DSS). Operationally heavier, not justified here.
- **Azure Firewall Standard**: valid for dev/test. Parameterised so it can be selected per environment.

---

## ADR-03: DNS Private Resolver for Zero Trust hybrid DNS

**Decision:** Deploy an Azure DNS Private Resolver with an inbound endpoint (on-prem → Azure) and an outbound endpoint with forwarding ruleset (Azure → on-prem), rather than relying on Azure Firewall's DNS proxy alone.

**Rationale:**
- Azure Firewall DNS proxy only intercepts DNS queries from VMs that have the firewall as their DNS server. It cannot receive DNS queries from on-premises clients, as it has no inbound endpoint in the hub subnet.
- The DNS Private Resolver inbound endpoint gets a stable private IP in the hub VNet. On-premises clients configure a conditional forwarder to this IP for `*.azure.com`, `*.blob.core.windows.net`, etc., enabling private endpoint name resolution without split-brain DNS.
- The outbound endpoint and forwarding ruleset route queries for `howardlabs.local.` (configurable via `onPremDomain`) to the on-premises DNS server. This removes the requirement for on-prem clients to have public DNS access for internal FQDNs.
- This is the ALZ-recommended pattern for hybrid DNS. It is Zero Trust compliant: no public DNS resolution for any PaaS endpoint, no DNS traffic exiting the private network.

**Subnets:**
- `snet-dnsresolver-inbound` (`10.0.4.0/28`): delegated to `Microsoft.Network/dnsResolvers`, NSG applied (allows port 53 from `VirtualNetwork`, blocks internet inbound).
- `snet-dnsresolver-outbound` (`10.0.5.0/28`): delegated to `Microsoft.Network/dnsResolvers`, no NSG (Azure platform restriction: NSGs on outbound endpoint subnets cause deployment failure).

**Alternatives considered:**
- **Azure Firewall DNS proxy only**: insufficient for inbound on-prem resolution. Rejected for hybrid scenarios.
- **Custom DNS servers (VMs running BIND/Windows DNS)**: valid pre-2022. Replaced by DNS Private Resolver which is managed, zone-redundant, and requires no IaaS maintenance.

---

## ADR-04: Centralised private DNS zones in the hub (ALZ pattern)

**Decision:** Deploy all standard PaaS private DNS zones (`privatelink.blob.core.windows.net`, `privatelink.vaultcore.azure.net`, etc.) centrally in the hub resource group, linked to the hub VNet and all spoke VNets.

**Rationale:**
- In an enterprise ALZ deployment, private DNS zones are owned by the platform team (Connectivity subscription), not individual workload teams. Centralised zones prevent duplicate zone proliferation and conflicting records.
- All spoke VNets are linked to every zone at deployment time via the `spokeVnetResourceIds` parameter. As new spokes are added in later modules, they pass their VNet resource ID to this module to be linked.
- This ensures that any private endpoint deployed in any spoke will resolve to its private IP via Azure DNS, regardless of which spoke it sits in, with no per-spoke zone configuration required.
- The `avm/ptn/network/private-link-private-dns-zones:0.7.2` pattern module handles all 80+ standard PaaS zones and the `{{regionCode}}` placeholder substitution automatically.

**Alternatives considered:**
- **Zones per workload (distributed)**: each team manages their own zones. Creates management overhead, risk of conflicting records, and requires RBAC delegation to workload teams. Rejected for enterprise scale.
- **Azure Private DNS Resolver without zones**: DNS forwarding without centralised zones means PaaS endpoints still resolve via public DNS. Not Zero Trust compliant. Rejected.

---

## ADR-05: Bicep Stacks over stateless `az deployment group create`

**Decision:** All deployments use `az stack group create` with `--deny-settings-mode denyWriteAndDelete` and `--action-on-unmanage deleteResources`.

**Rationale:**
- Bicep Stacks provide lifecycle management equivalent to Terraform state. Resources deleted from the template are automatically removed from Azure on the next stack update, leaving no orphaned resources.
- `denyWriteAndDelete` blocks all writes and deletes to stack-managed resources via the portal or CLI unless you go through the stack. This prevents configuration drift from ad-hoc changes, a critical requirement in a governance-heavy enterprise environment.
- Stateless deployments (`az deployment group create`) have no knowledge of previously deployed resources. Removing a resource from the template leaves it in Azure indefinitely, creating a security risk (forgotten open NSG rules, public IPs, etc.).

**Alternatives considered:**
- **Terraform state in Azure Storage**: equivalent capability, appropriate for the Terraform track. Bicep Stacks is the native equivalent and requires no external state backend.
- **Stateless deployments with manual cleanup**: operationally unsafe at scale. Rejected.

---

## ADR-06: AVM (Azure Verified Modules) for all resource declarations

**Decision:** No native `resource` declarations are permitted where an AVM module exists. All resources are deployed via `br/public:avm/...` modules.

**Rationale:**
- AVM modules are Microsoft-verified: they enforce WAF alignment, apply secure defaults (private endpoints, HTTPS-only, TLS minimums, diagnostic settings), and are regression-tested by the AVM team.
- Using AVM eliminates entire classes of misconfiguration risk. For example, `avm/res/storage/storage-account` sets `allowBlobPublicAccess: false` and `minimumTlsVersion: 'TLS1_2'` by default, meaning a developer would need to explicitly override these to weaken security.
- In an enterprise environment at scale, the operational value of a standardised, well-documented module library cannot be overstated. Custom `resource` declarations diverge between teams; AVM is the common language.

**AVM modules used in this module:**
| Resource | AVM Module | Version |
|---|---|---|
| Hub VNet | `avm/res/network/virtual-network` | `0.9.0` |
| NSG | `avm/res/network/network-security-group` | `0.5.3` |
| Route Table | `avm/res/network/route-table` | `0.5.0` |
| Bastion | `avm/res/network/bastion-host` | `0.8.2` |
| ExpressRoute Gateway | `avm/res/network/virtual-network-gateway` | `0.11.1` |
| Network Watcher | `avm/res/network/network-watcher` | `0.5.1` |
| Firewall Policy | `avm/res/network/firewall-policy` | `0.3.5` |
| Azure Firewall | `avm/res/network/azure-firewall` | `0.10.1` |
| Private DNS Zones | `avm/ptn/network/private-link-private-dns-zones` | `0.7.2` |
| DNS Private Resolver | `avm/res/network/dns-resolver` | `0.5.7` |
| DNS Forwarding Ruleset | `avm/res/network/dns-forwarding-ruleset` | `0.5.4` |
| Log Analytics Workspace | `avm/res/operational-insights/workspace` | `0.15.1` |
| Storage Account | `avm/res/storage/storage-account` | `0.32.1` |

---

## ADR-07: Zone-redundancy for all stateful resources

**Decision:** ExpressRoute Gateway (`ErGw1AZ`), Azure Firewall, and Bastion are deployed zone-redundant across availability zones 1, 2, and 3.

**Rationale:**
- Zone-redundant deployments survive a full datacenter failure within the region. For an 85,000+ user environment, the hub VNet is the single shared infrastructure dependency for all workloads, so its availability directly determines the availability of every application.
- `ErGw1AZ` is the minimum zone-redundant ExpressRoute Gateway SKU, providing up to 1 Gbps aggregate throughput. Scale to `ErGw2AZ`, `ErGw3AZ`, or `ErGwScale` as circuit demand grows. All `Az`-suffixed SKUs distribute across zones 1, 2, and 3.
- Azure Firewall zone-redundancy (`availabilityZones: [1, 2, 3]`) is configured at deployment time and cannot be changed post-deployment without redeployment, so it must be correct from day one.
- Zone-redundancy for the ExpressRoute Gateway is independent of circuit redundancy (dual ER circuits via diverse peering locations is a separate DR concern addressed in module 05).

---

## ADR-08: Bring-your-own or auto-deploy for Log Analytics and Storage

**Decision:** `logAnalyticsWorkspaceId` and `flowLogStorageAccountId` are optional parameters (default `''`). When empty, the module deploys a basic Log Analytics workspace and storage account automatically.

**Rationale:**
- In a full ALZ deployment, these resources are pre-existing in the Management Landing Zone (typically deployed by `04-Observability-Policy`). The module should accept their resource IDs and reuse them rather than creating duplicates.
- For standalone deployment (portfolio demonstration, greenfield lab), requiring pre-existing resources creates a circular dependency, as the user cannot deploy the networking module without first deploying an observability module.
- The "bring your own or we'll create one" pattern resolves this without compromising the ALZ integration path. Pass the resource IDs in `.bicepparam` to wire into an existing management layer; omit them for a self-contained deployment.
- The auto-deployed workspace uses `PerGB2018` (pay-per-GB, no commitment) and 30-day retention, appropriate for lab/dev. Enterprise environments should provide a dedicated workspace with appropriate retention policy (typically 90 days for security investigations).

---

## ADR-09: OIDC federated credentials over client secrets for CI/CD

**Decision:** GitHub Actions uses OIDC federated credentials (`azure/login@v2` with `client-id`, `tenant-id`, `subscription-id`) rather than a `AZURE_CREDENTIALS` client secret.

**Rationale:**
- Client secrets expire (typically 1–2 years), require rotation, and are a long-lived credential that can be exfiltrated from GitHub Secrets if the repository is compromised.
- OIDC tokens are short-lived (15 minutes), scoped to a specific workflow run, and cannot be reused outside the run context. There is no credential to exfiltrate.
- `client-id`, `tenant-id`, and `subscription-id` are non-sensitive IDs stored as GitHub Actions **variables** (not secrets). They are safe to store in plaintext and are intentionally not committed to this repository to avoid linking the portfolio to a specific Azure subscription.
- This approach is aligned with Microsoft's Workload Identity Federation guidance and is the current best practice for all Azure/GitHub integrations.

---

## ADR-10: ExpressRoute over S2S VPN for enterprise hybrid connectivity

**Decision:** The hub VNet uses an ExpressRoute Gateway (`erGatewaySku = 'ErGw1AZ'`) for on-premises connectivity. Site-to-site VPN is not deployed.

**Rationale:**
- S2S VPN tunnels traverse the public internet. Traffic is encrypted but the path is not private, making it subject to internet routing instability, variable latency, and ISP throttling. This is incompatible with enterprise compliance posture (ISO 27001, NIST CSF, and most financial/healthcare regulatory frameworks).
- ExpressRoute provides a dedicated Layer 3 circuit over MPLS or dark fibre, provisioned by a connectivity provider (BT, Equinix, Vodafone, etc.). Traffic never traverses the public internet, giving a private, SLA-backed path between the on-premises edge and the Azure edge router.
- ExpressRoute delivers sub-10 ms round-trip latency (provider-dependent) and throughput from 50 Mbps to 100 Gbps. S2S VPN is practically capped at ~1 Gbps aggregate over IPSec and is susceptible to internet congestion.
- Spoke VNets connect to each other and to on-premises exclusively via **VNet Peering** to the hub, with gateway transit enabled (`allowGatewayTransit: true` on the hub side, `useRemoteGateways: true` on the spoke side). No ER or VPN resources are deployed in spokes; the hub gateway is the single hybrid connectivity point.
- S2S VPN remains a valid **coexistence** option alongside ExpressRoute as a failover path (FastPath or VPN Gateway coexistence), but this is a DR concern addressed in module 05 rather than a primary connectivity pattern.

**Alternatives considered:**
- **S2S VPN as primary**: appropriate only where an ER circuit cannot be provisioned (e.g., temporary lab, SMB, or partner connectivity). Rejected as the primary enterprise connectivity pattern due to public internet traversal and compliance implications.
- **Virtual WAN with ExpressRoute**: valid for 10+ spoke topologies or SD-WAN integration. Revisit at module 05.

---

## Network topology summary

```
On-premises (MPLS / dark fibre)
    │
    │  ExpressRoute (ErGw1AZ - Zone-redundant, dedicated private circuit)
    │  No public internet traversal (ADR-10)
    │
┌───▼────────────────────────────────────────────────────────────┐
│  Hub VNet (10.0.0.0/16)                                    │
│                                                             │
│  GatewaySubnet       (10.0.0.0/27)   - ExpressRoute GW     │
│  AzureBastionSubnet  (10.0.1.0/26)   - Bastion             │
│  AzureFirewallSubnet (10.0.2.0/26)   - Azure Firewall Prem │
│  snet-management     (10.0.3.0/24)   - Jump VMs, mgmt      │
│  snet-dnsresolver-inbound  (10.0.4.0/28) - DNS inbound EP  │
│  snet-dnsresolver-outbound (10.0.5.0/28) - DNS outbound EP │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Azure Firewall Premium (zone-redundant)            │   │
│  │  • IDPS, TLS inspection, URL filtering              │   │
│  │  • DNS proxy enabled                                │   │
│  │  • Auto-learn private ranges (no SNAT on RFC1918)  │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌────────────────────────────────────────────────────┐     │
│  │  DNS Private Resolver                             │     │
│  │  • Inbound: on-prem → Azure private DNS zones    │     │
│  │  • Outbound: Azure → howardlabs.local. (on-prem DNS)   │     │
│  └────────────────────────────────────────────────────┘     │
└────────────────────────┬───────────────────────────────────┘
                         │  VNet Peering (hub ↔ spoke)
            ┌────────────┴────────────┐
            │                         │
┌───────────▼───────────┐   ┌─────────▼──────────────┐
│  App Spoke (10.1.0/16)│   │  (future spokes)       │
│  snet-workload /24    │   │  added via bicepparam  │
│  All egress → Firewall│   │                        │
└───────────────────────┘   └────────────────────────┘
```

---

## Local validation pipeline

Run in order before pushing; this mirrors the GitHub Actions CI pipeline:

```bash
# Automated: run validate-local.sh (mirrors GitHub Actions CI pipeline)
bash scripts/validate-local.sh 01-Core-Networking   # single module
bash scripts/validate-local.sh                      # all modules

# Manual steps (if running individually):

# 1. Lint (applies bicepconfig.json rules - no Azure credentials required)
az bicep lint --file 01-Core-Networking/bicep/main.bicep

# 2. Compile to ARM JSON (catches type errors and BCP diagnostics)
az bicep build --file 01-Core-Networking/bicep/main.bicep --outfile reports/main.arm.json

# 3. Compile parameter file (validates param types against template)
az bicep build-params --file 01-Core-Networking/bicep/main.bicepparam --outfile reports/main.arm.params.json

# 4. Secret scan (install: https://github.com/betterleaks/betterleaks)
betterleaks git . -v

# 5. PSRule for Azure (runs against compiled ARM JSON - not the Bicep file directly)
#    Install: Install-Module -Name PSRule.Rules.Azure -Scope CurrentUser -Force
pwsh -File scripts/_psrule-run.ps1 -ArmFile reports/main.arm.json -SarifOut reports/psrule.sarif

# 6. What-if (requires az login; read-only - no resources created)
az deployment group what-if \
 --resource-group <your-rg> \
 --template-file 01-Core-Networking/bicep/main.bicep \
 --parameters 01-Core-Networking/bicep/main.bicepparam

# 7. Deploy via Bicep Stack (only on explicit request)
az stack group create \
 --name '01-core-networking' \
 --resource-group <your-rg> \
 --template-file 01-Core-Networking/bicep/main.bicep \
 --parameters 01-Core-Networking/bicep/main.bicepparam \
 --deny-settings-mode denyWriteAndDelete \
 --action-on-unmanage deleteResources \
 --yes
```
