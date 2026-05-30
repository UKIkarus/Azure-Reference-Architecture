// File: main.bicep
// =============================================================================
// Orchestration entry point for 01-Core-Networking module.
// Deploys hub networking, Azure Firewall, and one example spoke.
// All child modules use AVM; no native resource declarations in this file.
//
// Deployment order:
//   1. hub-networking.bicep   - Hub VNet, Bastion, VPN Gateway, NSGs, UDRs
//   2. firewall.bicep         - Firewall Policy + Azure Firewall
//   3. spoke-networking.bicep - Spoke VNet with peering + UDR (repeatable)
// =============================================================================

// ── Target scope ─────────────────────────────────────────────────────────────
targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────────────────────

// Azure region for all resources; defaults to resource group location
@description('Azure region for all deployed resources.')
param location string = resourceGroup().location

// Environment name used in resource naming and tagging
@description('Environment name: dev, staging, or prod.')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

// Hub VNet address space; must not overlap spokes or on-prem
@description('Hub VNet CIDR block, e.g. 10.0.0.0/16.')
param hubVnetAddressPrefix string = '10.0.0.0/16'

// GatewaySubnet CIDR; /27 minimum required by Azure
@description('GatewaySubnet CIDR prefix (/27 or larger).')
param gatewaySubnetPrefix string = '10.0.0.0/27'

// AzureBastionSubnet CIDR; /26 minimum required by Azure Bastion
@description('AzureBastionSubnet CIDR prefix (/26 or larger).')
param bastionSubnetPrefix string = '10.0.1.0/26'

// AzureFirewallSubnet CIDR; /26 minimum required by Azure Firewall
@description('AzureFirewallSubnet CIDR prefix (/26 or larger).')
param firewallSubnetPrefix string = '10.0.2.0/26'

// Management subnet CIDR for shared services and jump VMs
@description('Management subnet CIDR prefix within hub VNet.')
param mgmtSubnetPrefix string = '10.0.3.0/24'

// Spoke 1 VNet address space; must not overlap hub or other spokes
@description('App spoke VNet CIDR block, e.g. 10.1.0.0/16.')
param appSpokeVnetAddressPrefix string = '10.1.0.0/16'

// App spoke workload subnet CIDR
@description('App spoke workload subnet CIDR prefix.')
param appSpokeWorkloadSubnetPrefix string = '10.1.0.0/24'

// Resource ID of existing Log Analytics workspace; leave empty to deploy a new workspace
// In an ALZ deployment, pass the Management Landing Zone workspace ID here
@description('Existing Log Analytics workspace resource ID. Omit to deploy a new workspace.')
param logAnalyticsWorkspaceId string = ''

// Resource ID of existing storage account for NSG flow logs; leave empty to deploy a new account
@description('Existing storage account resource ID for flow log retention. Omit to deploy a new account.')
param flowLogStorageAccountId string = ''

// ExpressRoute Gateway SKU - AZ-suffixed SKUs are zone-redundant.
// Enterprise environments mandate ExpressRoute over S2S VPN: dedicated private circuit,
// no public internet traversal, SLA-backed latency (see ADR-10 in decision-log.md).
@description('ExpressRoute Gateway SKU. AZ-suffixed SKUs are zone-redundant.')
@allowed(['ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ', 'ErGwScale'])
param erGatewaySku string = 'ErGw1AZ'

// Azure Firewall and Policy tier; Premium enables IDPS and TLS inspection
@description('Azure Firewall and Firewall Policy tier.')
@allowed(['Standard', 'Premium'])
param firewallTier string = 'Premium'

// DNS resolver inbound subnet CIDR; /28 minimum, dedicated for dnsResolvers delegation
@description('Subnet CIDR for DNS resolver inbound endpoint (/28 or larger).')
param dnsResolverInboundSubnetPrefix string = '10.0.4.0/28'

// DNS resolver outbound subnet CIDR; /28 minimum, dedicated for dnsResolvers delegation
@description('Subnet CIDR for DNS resolver outbound endpoint (/28 or larger).')
param dnsResolverOutboundSubnetPrefix string = '10.0.5.0/28'

// On-prem DNS server IP for hybrid forwarding; update per environment in .bicepparam
@description('On-premises DNS server IP address for hybrid DNS forwarding.')
param onPremDnsServerIp string = '192.168.0.1'

// On-prem internal domain to forward; trailing dot required (FQDN convention)
@description('On-premises domain name to forward (trailing dot required).')
param onPremDomain string = 'howardlabs.local.'

// ── Tagging Parameters ────────────────────────────────────────────────────────
// All tag values are centralised here and built into var commonTags below.
// Set explicit values in main.bicepparam; child modules receive tags as a single param.

@description('Resource owner - name or team responsible for this deployment.')
param tagOwner string = 'Missing Owner'

@description('Created-by identifier - person, team, or automation tool.')
param tagCreatedBy string = 'Bicep Deployment - Missing CreatedBy'

@description('Business unit or department responsible for this resource.')
param tagDepartment string = 'Missing Department'

@description('Internal cost centre or billing code for charge-back.')
param tagCostCenter string = 'Missing CostCenter'

@description('Project or initiative name for grouping related resources.')
param tagProject string = 'Missing Project'

@description('Creation date in DD-MM-YYYY format. Defaults to current UTC date at first deployment.')
param tagCreatedDate string = utcNow('dd-MM-yyyy')

@description('Date this deployment was last reviewed, in DD-MM-YYYY format.')
param tagLastReviewed string = utcNow('dd-MM-yyyy')

// ── Tags Variable ─────────────────────────────────────────────────────────────
// Single source of truth for all resource tags in this module.
// Child modules receive this as `param tags object` and apply it to every resource.
// Spoke-specific tags (e.g. Spoke: app) are merged inside spoke-networking.bicep with union().
var commonTags = {
  Owner:        tagOwner
  CreatedBy:    tagCreatedBy
  Department:   tagDepartment
  CostCenter:   tagCostCenter
  Project:      tagProject
  CreatedDate:  tagCreatedDate
  LastReviewed: tagLastReviewed
  Environment:  environment
  ManagedBy:    'bicep-avm'
  Module:       '01-core-networking'
}

// ── Resource Group Tags ───────────────────────────────────────────────────────
// Apply commonTags to the resource group for cost management and governance.
// No AVM available: Microsoft.Resources/tags is a meta-resource with no AVM coverage.
resource rgTags 'Microsoft.Resources/tags@2024-03-01' = {
  name: 'default'
  properties: {
    tags: commonTags
  }
}

// ── Management Resources ─────────────────────────────────────────────────────
// Log Analytics workspace and flow log storage account.
// In a full ALZ deployment these are pre-existing from the Management Landing Zone.
// Provide resource IDs via params to reuse them; omit to deploy basic resources here.

// Deploy Log Analytics workspace only when no existing workspace resource ID is provided
module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.15.1' = if (empty(logAnalyticsWorkspaceId)) {
  name: 'log-analytics-workspace'
  params: {
    // Name follows <env>-hub-law convention
    name: '${environment}-hub-law'
    // Deploy in same region as hub networking
    location: location
    // Apply common enterprise tag set - defined in var commonTags
    tags: commonTags
    // PerGB2018 is the recommended pay-per-GB SKU; no minimum commitment
    skuName: 'PerGB2018'
    // 30-day default; increase to 90+ days for security investigations or compliance
    dataRetention: 30
    // Prevent accidental deletion of the central diagnostics store
    lock: { kind: 'CanNotDelete', name: 'lock-law' }
  }
}

// Deploy storage account for NSG flow logs only when no existing account resource ID is provided
// Storage account name: lowercase, 3-24 chars; uniqueString ensures global uniqueness per RG
module flowLogStorageAccount 'br/public:avm/res/storage/storage-account:0.32.1' = if (empty(flowLogStorageAccountId)) {
  name: 'flow-log-storage-account'
  params: {
    // Deterministic name scoped to resource group; always recreates the same account on redeploy
    name: toLower(take('${environment}flwlogs${uniqueString(resourceGroup().id)}', 24))
    // Deploy in same region as hub networking
    location: location
    // Apply common enterprise tag set - defined in var commonTags
    tags: commonTags
    // Standard_ZRS provides zone-redundant storage for flow log durability;
    // LRS is insufficient for production observability data (Azure.Storage.UseReplication)
    skuName: 'Standard_ZRS'
    // StorageV2 is the recommended general-purpose account kind
    kind: 'StorageV2'
    // Zero Trust: no anonymous public access to flow log blobs
    allowBlobPublicAccess: false
    // Disable shared key (storage account key) authentication; require Entra ID only.
    // Shared keys are long-lived credentials that can't be scoped or audited per-principal.
    allowSharedKeyAccess: false
    // Enforce TLS 1.2 minimum; 1.0 and 1.1 are deprecated and insecure
    minimumTlsVersion: 'TLS1_2'
    // Reject all plaintext HTTP connections to the storage account
    supportsHttpsTrafficOnly: true
    // Prevent accidental deletion of flow log data
    lock: { kind: 'CanNotDelete', name: 'lock-flowlog-sa' }
  }
}

// Resolve effective resource IDs: use provided pre-existing resources or newly deployed ones
// Conditional module outputs are null when the module is not deployed; ternary selects the live side
// The null-forgiving operator (!) suppresses BCP318 - the condition guarantees the module is deployed
var effectiveWorkspaceId = !empty(logAnalyticsWorkspaceId) ? logAnalyticsWorkspaceId : logAnalyticsWorkspace!.outputs.resourceId
var effectiveStorageId = !empty(flowLogStorageAccountId) ? flowLogStorageAccountId : flowLogStorageAccount!.outputs.resourceId

// ── Hub Networking ────────────────────────────────────────────────────────────
// Deploy hub VNet, Bastion, VPN Gateway, NSGs, UDRs, and Network Watcher
module hubNetworking 'hub-networking.bicep' = {
  name: 'hub-networking'
  params: {
    // Pass region to hub networking module
    location: location
    // Pass environment to hub networking module
    environment: environment
    // Pass hub VNet address space
    hubVnetAddressPrefix: hubVnetAddressPrefix
    // Pass gateway subnet prefix
    gatewaySubnetPrefix: gatewaySubnetPrefix
    // Pass Bastion subnet prefix
    bastionSubnetPrefix: bastionSubnetPrefix
    // Pass firewall subnet prefix
    firewallSubnetPrefix: firewallSubnetPrefix
    // Pass management subnet prefix
    mgmtSubnetPrefix: mgmtSubnetPrefix
    // Pass effective workspace resource ID (provided or auto-deployed)
    logAnalyticsWorkspaceId: effectiveWorkspaceId
    // Pass effective storage account resource ID (provided or auto-deployed)
    flowLogStorageAccountId: effectiveStorageId
    // Pass ExpressRoute gateway SKU selection
    erGatewaySku: erGatewaySku
    // Pass DNS resolver inbound subnet CIDR
    dnsResolverInboundSubnetPrefix: dnsResolverInboundSubnetPrefix
    // Pass DNS resolver outbound subnet CIDR
    dnsResolverOutboundSubnetPrefix: dnsResolverOutboundSubnetPrefix
    // Pass common enterprise tag set to all resources in hub networking module
    tags: commonTags
  }
}

// ── Azure Firewall ─────────────────────────────────────────────────────────────
// Deploy Firewall Policy and Azure Firewall after hub VNet is ready
module firewall 'firewall.bicep' = {
  name: 'firewall'
  params: {
    // Pass region to firewall module
    location: location
    // Pass environment to firewall module
    environment: environment
    // Pass hub VNet resource ID from hub networking output
    hubVnetResourceId: hubNetworking.outputs.hubVnetResourceId
    // Pass effective workspace resource ID (provided or auto-deployed)
    logAnalyticsWorkspaceId: effectiveWorkspaceId
    // Pass firewall tier (Standard or Premium)
    firewallTier: firewallTier
    // Pass common enterprise tag set to all resources in firewall module
    tags: commonTags
  }
}

// ── App Spoke Networking ──────────────────────────────────────────────────────
// Deploy reusable spoke module for the first application spoke
module appSpoke 'spoke-networking.bicep' = {
  name: 'app-spoke-networking'
  params: {
    // Pass region to spoke networking module
    location: location
    // Pass environment to spoke networking module
    environment: environment
    // Identifier for this spoke; used in resource and peering names
    spokeName: 'app'
    // Pass app spoke VNet address space
    spokeVnetAddressPrefix: appSpokeVnetAddressPrefix
    // Pass app spoke workload subnet prefix
    workloadSubnetPrefix: appSpokeWorkloadSubnetPrefix
    // Route spoke egress to Azure Firewall private IP
    firewallPrivateIp: firewall.outputs.firewallPrivateIp
    // Pass hub VNet resource ID for VNet peering
    hubVnetResourceId: hubNetworking.outputs.hubVnetResourceId
    // Pass effective workspace resource ID (provided or auto-deployed)
    logAnalyticsWorkspaceId: effectiveWorkspaceId
    // Pass common enterprise tag set to all resources in spoke networking module
    tags: commonTags
  }
}

// ── Private DNS and Resolver ──────────────────────────────────────────────────
// Deploy centralised private DNS zones + DNS resolver; requires spoke VNet to exist
module privateDns 'private-dns.bicep' = {
  name: 'private-dns'
  params: {
    // Pass region to private DNS module
    location: location
    // Pass environment to private DNS module
    environment: environment
    // Hub VNet resource ID for zone linking and resolver attachment
    hubVnetResourceId: hubNetworking.outputs.hubVnetResourceId
    // Link all standard private DNS zones to the app spoke VNet
    spokeVnetResourceIds: [appSpoke.outputs.spokeVnetResourceId]
    // Inbound resolver subnet resource ID from hub networking outputs
    dnsResolverInboundSubnetResourceId: hubNetworking.outputs.dnsResolverInboundSubnetResourceId
    // Outbound resolver subnet resource ID from hub networking outputs
    dnsResolverOutboundSubnetResourceId: hubNetworking.outputs.dnsResolverOutboundSubnetResourceId
    // On-prem DNS server IP for outbound forwarding rule
    onPremDnsServerIp: onPremDnsServerIp
    // On-prem internal domain to forward (trailing dot required)
    onPremDomain: onPremDomain
    // Pass common enterprise tag set to all resources in private DNS module
    tags: commonTags
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

// Hub VNet resource ID for use by other modules and automation
output hubVnetResourceId string = hubNetworking.outputs.hubVnetResourceId

// DNS resolver resource ID for monitoring and policy references
output dnsResolverResourceId string = privateDns.outputs.dnsResolverResourceId

// DNS forwarding ruleset resource ID for spoke-level extension in later modules
output dnsForwardingRulesetResourceId string = privateDns.outputs.dnsForwardingRulesetResourceId

// Hub VNet name for cross-module reference
output hubVnetName string = hubNetworking.outputs.hubVnetName

// Azure Firewall private IP for UDRs in additional spokes
output firewallPrivateIp string = firewall.outputs.firewallPrivateIp

// Firewall Policy resource ID for adding rule collection groups
output firewallPolicyResourceId string = firewall.outputs.firewallPolicyResourceId

// App spoke VNet resource ID for workload deployments
output appSpokeVnetResourceId string = appSpoke.outputs.spokeVnetResourceId

// ExpressRoute gateway resource ID for circuit connection objects
output erGatewayResourceId string = hubNetworking.outputs.erGatewayResourceId

// Log Analytics workspace resource ID - pass to 04-Observability-Policy and later modules
// Reflects either the provided pre-existing workspace or the newly deployed one
output logAnalyticsWorkspaceResourceId string = effectiveWorkspaceId
