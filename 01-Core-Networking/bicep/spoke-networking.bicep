// File: spoke-networking.bicep
// =============================================================================
// AVM modules used:
//   avm/res/network/virtual-network:0.9.0         - Spoke VNet with subnets
//   avm/res/network/network-security-group:0.5.3  - NSG per spoke subnet
//   avm/res/network/route-table:0.5.0             - UDR forcing egress via AFW
// =============================================================================
// NOTE: This file is parameterized and reusable for any spoke.
//       Call it once per spoke with different parameter values.
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

// Spoke identifier, e.g. app1, shared, dmz
@description('Short identifier for this spoke, used in resource names.')
@minLength(2)
@maxLength(12)
param spokeName string

// Spoke VNet address space; must not overlap hub or other spokes
@description('Spoke VNet address prefix, e.g. 10.1.0.0/16.')
param spokeVnetAddressPrefix string

// Default subnet CIDR for main workload subnet in this spoke
@description('Default workload subnet CIDR within the spoke VNet.')
param workloadSubnetPrefix string

// Private IP of Azure Firewall in hub VNet (from firewall.bicep output)
@description('Azure Firewall private IP address for UDR next-hop.')
param firewallPrivateIp string

// Resource ID of hub VNet for VNet peering
@description('Resource ID of the Hub VNet to peer with.')
param hubVnetResourceId string

// Resource ID of Log Analytics workspace for diagnostics
@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

// ── Variables ─────────────────────────────────────────────────────────────────

// Common enterprise tag set - passed in from main.bicep var commonTags.
// Merged with spoke identifier below; use effectiveTags on all resources in this module.
@description('Common tag set applied to every resource in this module. Passed from main.bicep.')
param tags object

// Merge the spoke identifier into the common tag set.
// union() adds the Spoke tag without modifying the base commonTags from main.bicep.
var effectiveTags = union(tags, { Spoke: spokeName })

// Spoke VNet name follows <env>-<spoke>-vnet convention
var spokeVnetName = '${environment}-${spokeName}-vnet'

// ── NSG - Workload Subnet ─────────────────────────────────────────────────────
// NSG protecting the default workload subnet; restrict inbound as needed
module nsgWorkload 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-${spokeName}-workload-deploy'
  params: {
    // NSG name scoped to spoke and subnet
    name: '${environment}-${spokeName}-workload-nsg'
    // Deploy NSG in same region as spoke VNet
    location: location
    // Apply effective tag set (common + Spoke identifier) to NSG
    tags: effectiveTags
    // Diagnostic settings send NSG logs to central workspace
    diagnosticSettings: [
      {
        // Diagnostic setting name for this spoke NSG
        name: 'diag-nsg-${spokeName}'
        // Route all NSG logs to central Log Analytics workspace
        workspaceResourceId: logAnalyticsWorkspaceId
        // Enable all log categories for full audit trail
        logCategoriesAndGroups: [
          {
            // Capture all available log groups for this NSG
            categoryGroup: 'allLogs'
          }
        ]
      }
    ]
    // Security rules restrict inbound to VNet and hub only
    securityRules: [
      {
        // Allow inbound from hub VNet for management and firewall health
        name: 'Allow-Inbound-Hub'
        properties: {
          // Higher priority than deny-internet rule below
          priority: 200
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          // Allow only traffic originating from hub address space
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Allow inbound from hub VNet for connectivity.'
        }
      }
      {
        // Deny all inbound internet traffic; everything must go through AFW
        name: 'Deny-Inbound-Internet'
        properties: {
          // Low priority catch-all after all allow rules
          priority: 4000
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          // Block all internet-sourced inbound traffic
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Block all inbound internet traffic to workload subnet.'
        }
      }
      {
        // Deny outbound SSH - prevent lateral traversal from workload VMs.
        // All remote access must go through Azure Bastion; direct SSH is blocked.
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
          description: 'Block lateral SSH from workload subnet; use Azure Bastion for remote access.'
        }
      }
      {
        // Deny outbound RDP - prevent lateral traversal from workload VMs.
        // All remote access must go through Azure Bastion; direct RDP is blocked.
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
          description: 'Block lateral RDP from workload subnet; use Azure Bastion for remote access.'
        }
      }
    ]
  }
}

// ── Route Table - Workload Subnet ─────────────────────────────────────────────
// UDR forces all egress through Azure Firewall for centralised inspection
module udrWorkload 'br/public:avm/res/network/route-table:0.5.0' = {
  name: 'udr-${spokeName}-workload-deploy'
  params: {
    // Route table name scoped to spoke and subnet
    name: '${environment}-${spokeName}-workload-udr'
    // Deploy route table in same region as spoke VNet
    location: location
    // Apply effective tag set (common + Spoke identifier) to route table
    tags: effectiveTags
    // Disable BGP propagation; all routes must be explicit UDRs
    disableBgpRoutePropagation: true
    // Default route directing all traffic to Azure Firewall
    routes: [
      {
        // Default route sends all egress to Azure Firewall
        name: 'route-to-firewall-default'
        properties: {
          // 0.0.0.0/0 captures all outbound traffic
          addressPrefix: '0.0.0.0/0'
          // Route through Azure Firewall as virtual appliance
          nextHopType: 'VirtualAppliance'
          // Use firewall private IP from hub (param from firewall.bicep output)
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

// ── Spoke Virtual Network ─────────────────────────────────────────────────────
// Spoke VNet peered to hub; all egress forced through Azure Firewall via UDR
module spokeVnet 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'spoke-${spokeName}-vnet-deploy'
  params: {
    // Spoke VNet name derived from spoke identifier and environment
    name: spokeVnetName
    // Deploy VNet in target region
    location: location
    // Apply effective tag set (common + Spoke identifier) to spoke VNet
    tags: effectiveTags
    // Spoke address space; must not overlap hub or other spokes
    addressPrefixes: [spokeVnetAddressPrefix]
    // Default workload subnet with NSG and UDR attached
    subnets: [
      {
        // Default workload subnet for spoke application resources
        name: 'snet-workload'
        // CIDR from parameter; must be within spoke address space
        addressPrefix: workloadSubnetPrefix
        // Attach workload NSG to restrict inbound access
        networkSecurityGroupResourceId: nsgWorkload.outputs.resourceId
        // Attach UDR to force egress through Azure Firewall
        routeTableResourceId: udrWorkload.outputs.resourceId
      }
    ]
    // VNet peering to hub - enables spoke-to-hub and spoke-to-spoke via AFW
    peerings: [
      {
        // Peering name identifies local-to-remote relationship
        name: '${spokeVnetName}-to-hub'
        // Reference hub VNet resource ID for peering target
        remotePeeringName: 'hub-to-${spokeVnetName}'
        // Resource ID of hub VNet to peer with
        remoteVirtualNetworkResourceId: hubVnetResourceId
        // Allow traffic forwarding (required for transitive routing via AFW)
        allowForwardedTraffic: true
        // Allow VNet access so peered resources communicate
        allowVirtualNetworkAccess: true
        // Use hub remote gateway for on-prem connectivity via VPN gateway
        useRemoteGateways: true
        // Create the peering on the hub side in the same deployment
        remotePeeringEnabled: true
        // Allow forwarded traffic on hub side too
        remotePeeringAllowForwardedTraffic: true
        // Hub must allow gateway transit for spoke to use VPN gateway
        remotePeeringAllowGatewayTransit: true
        // Spoke uses hub gateway; hub does not use spoke gateway
        remotePeeringUseRemoteGateways: false
      }
    ]
    // Send spoke VNet diagnostic logs to central workspace
    diagnosticSettings: [
      {
        // Diagnostic setting name for spoke VNet logs
        name: 'diag-${spokeName}-vnet'
        // Route all spoke VNet logs to central Log Analytics workspace
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

// Spoke VNet resource ID for workload modules and additional peerings
output spokeVnetResourceId string = spokeVnet.outputs.resourceId

// Spoke VNet name for cross-module references and monitoring rules
output spokeVnetName string = spokeVnet.outputs.name

// Workload NSG resource ID for security policy references
output workloadNsgResourceId string = nsgWorkload.outputs.resourceId
