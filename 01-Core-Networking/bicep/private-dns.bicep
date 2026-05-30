// File: private-dns.bicep
// =============================================================================
// AVM modules used:
//   avm/ptn/network/private-link-private-dns-zones:0.7.2
//     - All standard PaaS private DNS zones + VNet links; Azure Landing Zone pattern
//   avm/res/network/dns-resolver:0.5.7
//     - DNS Private Resolver; inbound receives on-prem queries; outbound forwards to on-prem
//   avm/res/network/dns-forwarding-ruleset:0.5.4
//     - Forwarding ruleset linked to outbound endpoint; routes on-prem domain to on-prem DNS
// =============================================================================
// Zero-Trust DNS architecture (ALZ-aligned):
//  - All PaaS private DNS zones live centrally in hub - no public DNS resolution for PaaS
//  - Zones linked to hub VNet and every spoke so private endpoints resolve to private IPs
//  - DNS Resolver inbound: on-prem clients query this IP to resolve Azure private DNS
//  - DNS Resolver outbound: Azure forwards on-prem domain queries to on-prem DNS server
// =============================================================================

// ── Target scope ─────────────────────────────────────────────────────────────
targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────────────────────

// Azure region for DNS resources; must match hub VNet region
@description('Azure region for all resources.')
param location string = resourceGroup().location

// Environment tag value, e.g. dev, staging, prod
@description('Environment name for tagging.')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

// Hub VNet resource ID for DNS resolver attachment and zone linking
@description('Resource ID of the Hub VNet.')
param hubVnetResourceId string

// Spoke VNet resource IDs to link to all private DNS zones; typed string array
@description('Resource IDs of spoke VNets to link to private DNS zones.')
param spokeVnetResourceIds string[]

// Inbound subnet resource ID (snet-dnsresolver-inbound, delegated)
@description('Resource ID of the DNS resolver inbound subnet.')
param dnsResolverInboundSubnetResourceId string

// Outbound subnet resource ID (snet-dnsresolver-outbound, delegated)
@description('Resource ID of the DNS resolver outbound subnet.')
param dnsResolverOutboundSubnetResourceId string

// On-prem DNS server IP for hybrid forwarding; set per environment in .bicepparam
@description('On-premises DNS server IP address for hybrid DNS forwarding.')
param onPremDnsServerIp string

// On-prem internal domain to forward; trailing dot is required FQDN format
@description('On-premises domain name to forward (trailing dot required), e.g. howardlabs.local.')
param onPremDomain string = 'howardlabs.local.'

// ── Variables ─────────────────────────────────────────────────────────────────

// Common enterprise tag set - passed in from main.bicep var commonTags.
// All resources in this module are tagged with this set.
@description('Common tag set applied to every resource in this module. Passed from main.bicep.')
param tags object

// DNS resolver name follows <env>-hub-dnsresolver convention
var dnsResolverName = '${environment}-hub-dnsresolver'

// Build per-spoke VNet link objects for zone and ruleset linking
var spokeVnetLinks = [for id in spokeVnetResourceIds: { virtualNetworkResourceId: id }]

// Merge hub VNet link with spoke links; all zones and ruleset linked equally
var allVnetLinks = concat([{ virtualNetworkResourceId: hubVnetResourceId }], spokeVnetLinks)

// Outbound endpoint resource ID; deterministic from resolver ID + endpoint name
// - Required by dns-forwarding-ruleset; constructed to avoid untyped array access
var outboundEndpointResourceId = '${dnsResolver.outputs.resourceId}/outboundEndpoints/${dnsResolverName}-outbound'

// ── Private Link DNS Zones ────────────────────────────────────────────────────
// Deploys all standard PaaS private DNS zones; links hub + every spoke VNet
// - Zero Trust: PaaS endpoints resolve to private IPs, never public IPs
// - Pattern module handles {{regionCode}}/{{regionName}} placeholder replacement automatically
module privateLinkDnsZones 'br/public:avm/ptn/network/private-link-private-dns-zones:0.7.2' = {
  params: {
    // Deploy zones in hub region; region code/name placeholders replaced by module
    location: location
    // Apply shared tag set to all private DNS zone resources
    tags: tags
    // Link every zone to hub VNet and all spoke VNets for private endpoint resolution
    virtualNetworkLinks: allVnetLinks
    // CanNotDelete prevents accidental removal of PaaS DNS zone infrastructure
    lock: {
      kind: 'CanNotDelete'
      name: 'lock-private-dns-zones'
    }
  }
}
// - Why: Centralised private DNS zones in hub is the ALZ-recommended pattern.
// -     Workload modules in later sections deploy private endpoints against these zones.

// ── Azure Private DNS Resolver ─────────────────────────────────────────────────
// Zone-redundant DNS Private Resolver for hybrid DNS; inbound + outbound endpoints
module dnsResolver 'br/public:avm/res/network/dns-resolver:0.5.7' = {
  params: {
    // DNS resolver name scoped to hub environment
    name: dnsResolverName
    // Deploy resolver in same region as hub VNet
    location: location
    // Apply shared tag set to DNS resolver resource
    tags: tags
    // Attach resolver to hub VNet; inbound/outbound subnets must be in same VNet
    virtualNetworkResourceId: hubVnetResourceId
    // Inbound endpoint: on-prem clients send DNS queries to this IP to resolve Azure zones
    inboundEndpoints: [
      {
        // Endpoint name follows resolver naming convention
        name: '${dnsResolverName}-inbound'
        // Dedicated /28 subnet delegated to Microsoft.Network/dnsResolvers
        subnetResourceId: dnsResolverInboundSubnetResourceId
      }
    ]
    // Outbound endpoint: Azure forwards unresolved on-prem domain queries via this endpoint
    outboundEndpoints: [
      {
        // Endpoint name follows resolver naming convention
        name: '${dnsResolverName}-outbound'
        // Dedicated /28 subnet delegated to Microsoft.Network/dnsResolvers
        subnetResourceId: dnsResolverOutboundSubnetResourceId
      }
    ]
    // CanNotDelete prevents breaking hybrid DNS connectivity
    lock: {
      kind: 'CanNotDelete'
      name: 'lock-dnsresolver'
    }
  }
}
// - Why: Inbound endpoint enables Zero Trust - on-prem resolves Azure private DNS zones
// -     without needing public DNS; outbound enables Azure resources to resolve on-prem FQDNs.

// ── DNS Forwarding Ruleset ────────────────────────────────────────────────────
// Routes on-prem domain queries from outbound endpoint to on-prem DNS server
module dnsForwardingRuleset 'br/public:avm/res/network/dns-forwarding-ruleset:0.5.4' = {
  params: {
    // Ruleset name scoped to hub environment
    name: '${environment}-hub-dns-fwdruleset'
    // Deploy in same region as DNS resolver
    location: location
    // Apply shared tag set to forwarding ruleset resource
    tags: tags
    // Reference the outbound endpoint that will process forwarded queries
    dnsForwardingRulesetOutboundEndpointResourceIds: [outboundEndpointResourceId]
    // Link ruleset to hub + all spoke VNets; enables Azure→on-prem resolution everywhere
    virtualNetworkLinks: allVnetLinks
    // Forwarding rules - forward on-prem domain to on-prem DNS server
    forwardingRules: [
      {
        // Rule name identifies the on-prem domain being forwarded
        name: 'rule-forward-onprem-domain'
        // On-prem internal domain; trailing dot is standard FQDN convention
        domainName: onPremDomain
        // Target on-prem DNS server; port 53 is standard DNS
        targetDnsServers: [
          {
            // On-prem DNS IP set per environment in main.bicepparam
            ipAddress: onPremDnsServerIp
            // Standard DNS port; most enterprise resolvers listen on 53
            port: 53
          }
        ]
        // Active rule; set to Disabled in environments without on-prem connectivity
        forwardingRuleState: 'Enabled'
      }
    ]
    // CanNotDelete prevents breaking hybrid DNS resolution
    lock: {
      kind: 'CanNotDelete'
      name: 'lock-dns-fwdruleset'
    }
  }
}
// - Why: Forwarding ruleset provides bidirectional hybrid DNS without split-brain risk.
// -     VNet links ensure all spokes resolve on-prem FQDNs via the outbound endpoint.

// ── Outputs ───────────────────────────────────────────────────────────────────

// DNS resolver resource ID for monitoring, diagnostics, and policy references
output dnsResolverResourceId string = dnsResolver.outputs.resourceId

// Inbound subnet ID output for reference by on-prem DNS server configuration
// - Configure on-prem DNS conditional forwarder to target the inbound endpoint IP
// - IP is dynamically assigned from dnsResolverInboundSubnetPrefix (first available, e.g. .4)
output dnsResolverInboundSubnetResourceId string = dnsResolverInboundSubnetResourceId

// Forwarding ruleset resource ID for spoke-level extension in later modules
output dnsForwardingRulesetResourceId string = dnsForwardingRuleset.outputs.resourceId
