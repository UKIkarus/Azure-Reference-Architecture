// File: firewall.bicep
// =============================================================================
// AVM modules used:
//   avm/res/network/firewall-policy:0.3.5   - Firewall Policy (Premium tier)
//   avm/res/network/azure-firewall:0.10.1   - Azure Firewall Standard/Premium
// =============================================================================
// NOTE: This file must be deployed AFTER hub-networking.bicep.
//       The hubVnetResourceId output from hub-networking.bicep is required here.
// =============================================================================

// ── Target scope ─────────────────────────────────────────────────────────────
targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────────────────────

// Azure region must match the hub VNet region
@description('Azure region for all resources.')
param location string = resourceGroup().location

// Environment tag value, e.g. dev, staging, prod
@description('Environment name for tagging.')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

// Resource ID of the hub VNet (output from hub-networking.bicep)
@description('Resource ID of the Hub VNet containing AzureFirewallSubnet.')
param hubVnetResourceId string

// Resource ID of Log Analytics workspace for diagnostics
@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

// Firewall tier; Premium enables IDPS, TLS inspection, and URL filtering
@description('Azure Firewall and Policy tier.')
@allowed(['Standard', 'Premium'])
param firewallTier string = 'Premium'

// ── Variables ─────────────────────────────────────────────────────────────────

// Common enterprise tag set - passed in from main.bicep var commonTags.
// All resources in this module are tagged with this set.
@description('Common tag set applied to every resource in this module. Passed from main.bicep.')
param tags object

// Firewall Policy name follows <env>-hub-afwpolicy convention
var firewallPolicyName = '${environment}-hub-afwpolicy'

// Azure Firewall name follows <env>-hub-afw convention
var firewallName = '${environment}-hub-afw'

// ── Firewall Policy ───────────────────────────────────────────────────────────
// Centralised Firewall Policy - rule collection groups added in child modules
module firewallPolicy 'br/public:avm/res/network/firewall-policy:0.3.5' = {
  name: 'firewall-policy-deploy'
  params: {
    // Firewall policy name scoped to hub environment
    name: firewallPolicyName
    // Deploy in same region as Azure Firewall
    location: location
    // Apply shared tag set to firewall policy resource
    tags: tags
    // Premium tier required for IDPS, TLS inspection, URL categories
    tier: firewallTier
    // Enable DNS proxy so VMs use Firewall as DNS resolver for FQDN rule evaluation
    enableProxy: true
    // Auto-learn private ranges to avoid SNAT on RFC1918 destinations
    snat: {
      // - autoLearnPrivateRanges prevents SNAT for on-prem and spoke traffic
      // - Ensures correct routing back to source for private destinations
      autoLearnPrivateRanges: 'Enabled'
    }
    // Deny threat intelligence - blocks known-malicious IPs/FQDNs curated by Microsoft.
    // 'Deny' actively blocks + logs; 'Alert' only logs. WAF Security pillar requires 'Deny'.
    threatIntelMode: 'Deny'
    // Enable IDPS (Intrusion Detection and Prevention System) - Premium tier only.
    // Alert mode logs detected threats; set to 'Deny' in production to actively block.
    intrusionDetection: {
      mode: 'Alert'
    }
  }
}

// ── Azure Firewall ─────────────────────────────────────────────────────────────
// Zone-redundant Premium Azure Firewall for centralised inspection
module azureFirewall 'br/public:avm/res/network/azure-firewall:0.10.1' = {
  name: 'azure-firewall-deploy'
  params: {
    // Firewall name scoped to hub environment
    name: firewallName
    // Deploy in same region as hub VNet
    location: location
    // Apply shared tag set to Azure Firewall resource
    tags: tags
    // Reference hub VNet containing AzureFirewallSubnet
    virtualNetworkResourceId: hubVnetResourceId
    // Use Firewall Policy instead of classic rule sets
    firewallPolicyId: firewallPolicy.outputs.resourceId
    // Match tier to firewall policy tier (Standard or Premium); azureSkuTier is the AVM property
    azureSkuTier: firewallTier
    // Zone-redundant deployment across all three availability zones
    availabilityZones: [1, 2, 3]
    // Send firewall diagnostic logs to central Log Analytics workspace
    diagnosticSettings: [
      {
        // Diagnostic setting name for firewall rule logs
        name: 'diag-afw'
        // Route all firewall logs to central workspace
        workspaceResourceId: logAnalyticsWorkspaceId
        // Enable all log categories including AzureFirewallApplicationRule
        logCategoriesAndGroups: [
          {
            // Capture all Azure Firewall log categories
            categoryGroup: 'allLogs'
          }
        ]
        // Also send metrics (hit count, throughput) to workspace
        metricCategories: [
          {
            // Capture all available firewall metrics
            category: 'AllMetrics'
          }
        ]
      }
    ]
    // Resource delete lock prevents accidental firewall removal
    lock: {
      // CanNotDelete prevents destroying central security perimeter
      kind: 'CanNotDelete'
      name: 'lock-afw'
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

// Azure Firewall private IP used by UDRs in spoke and hub route tables
output firewallPrivateIp string = azureFirewall.outputs.privateIp

// Azure Firewall resource ID for policy associations and monitoring
output firewallResourceId string = azureFirewall.outputs.resourceId

// Firewall Policy resource ID for child rule collection group deployments
output firewallPolicyResourceId string = firewallPolicy.outputs.resourceId

// Firewall name for cross-module reference and alert rules
output firewallName string = azureFirewall.outputs.name
