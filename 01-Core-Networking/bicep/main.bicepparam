// File: main.bicepparam
// Parameters file for 01-Core-Networking main.bicep.
// Adjust all values to match your environment before deploying.
//
// Validate with:
//   az deployment group what-if \
//    --resource-group <your-rg> \
//    --template-file main.bicep \
//    --parameters main.bicepparam

// Reference the compiled Bicep template
using 'main.bicep'

// Target Azure region for all resources
param location = 'uksouth'

// Environment name; controls naming and tagging
param environment = 'dev'

// ── Hub VNet address space ────────────────────────────────────────────────────
// Hub CIDR; must not overlap spoke VNets or on-prem networks
param hubVnetAddressPrefix = '10.0.0.0/16'

// GatewaySubnet: /27 minimum - 32 IPs
param gatewaySubnetPrefix = '10.0.0.0/27'

// AzureBastionSubnet: /26 minimum - 64 IPs
param bastionSubnetPrefix = '10.0.1.0/26'

// AzureFirewallSubnet: /26 minimum - 64 IPs
param firewallSubnetPrefix = '10.0.2.0/26'

// Management subnet: /24 provides 251 usable IPs
param mgmtSubnetPrefix = '10.0.3.0/24'

// ── App Spoke VNet address space ──────────────────────────────────────────────
// App spoke CIDR; must not overlap hub or other spoke VNets
param appSpokeVnetAddressPrefix = '10.1.0.0/16'

// App spoke workload subnet: first /24 of spoke space
param appSpokeWorkloadSubnetPrefix = '10.1.0.0/24'

// ── Existing resource IDs - OPTIONAL ────────────────────────────────────────
// In a full ALZ deployment, uncomment and provide resource IDs from your Management Landing Zone
// (typically deployed by 04-Observability-Policy). Leave commented out to auto-deploy here.

// param logAnalyticsWorkspaceId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>'
// param flowLogStorageAccountId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>'

// ── Sizing and SKU ────────────────────────────────────────────────────────────
// ExpressRoute Gateway SKU: ErGw1AZ (zone-redundant, 1 Gbps - enterprise minimum)
// S2S VPN is not used: ExpressRoute provides dedicated private connectivity over MPLS/fibre.
param erGatewaySku = 'ErGw1AZ'

// Firewall tier: Premium enables IDPS, TLS inspection, URL filtering
param firewallTier = 'Premium'

// ── DNS Resolver subnets ──────────────────────────────────────────────────────
// DNS resolver inbound: /28 provides 11 usable IPs - more than sufficient
param dnsResolverInboundSubnetPrefix = '10.0.4.0/28'

// DNS resolver outbound: /28 provides 11 usable IPs - dedicated, no NSG
param dnsResolverOutboundSubnetPrefix = '10.0.5.0/28'

// ── Hybrid DNS ────────────────────────────────────────────────────────────────
// On-prem DNS server IP: configure on-prem to forward azure.* to inbound endpoint IP
// Replace with actual on-prem DNS server IP; typically AD-integrated DNS
param onPremDnsServerIp = '192.168.0.1'

// On-prem internal domain forwarded to on-prem DNS (trailing dot required)
param onPremDomain = 'howardlabs.local.'

// ── Resource tags ─────────────────────────────────────────────────────────────
// Tags are applied to the resource group and all deployed resources.
// tagCreatedDate should be set once at initial deployment and not changed on redeployments.
// tagLastReviewed should be updated on each significant configuration review.
param tagOwner        = 'Platform Engineering - Daryl Howard'
param tagCreatedBy    = 'Daryl Howard'
param tagDepartment   = 'Infrastructure Team'
param tagCostCenter   = 'IT-INFRA'
param tagProject      = 'Azure Reference Architecture Portfolio'
param tagCreatedDate  = '30-05-2026'
param tagLastReviewed = '30-05-2026'
