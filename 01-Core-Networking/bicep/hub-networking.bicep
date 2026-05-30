// File: hub-networking.bicep
// =============================================================================
// AVM modules used:
//   avm/res/network/virtual-network:0.9.0         - Hub VNet with subnets
//   avm/res/network/network-security-group:0.5.3  - NSG per subnet
//   avm/res/network/route-table:0.5.0             - UDR forcing egress via AFW
//   avm/res/network/bastion-host:0.8.2            - Standard Bastion (no public mgmt)
//   avm/res/network/virtual-network-gateway:0.11.1 - Zone-redundant ExpressRoute gateway
//   avm/res/network/network-watcher:0.5.1         - Flow log + connection monitor
// =============================================================================

// ── Target scope ─────────────────────────────────────────────────────────────
targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────────────────────

// Azure region for all resources in this file
@description('Azure region for all resources.')
param location string = resourceGroup().location

// Environment tag value, e.g. dev, staging, prod
@description('Environment name for tagging.')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

// Hub VNet address space; must not overlap spokes or on-prem
@description('Hub VNet address prefix, e.g. 10.0.0.0/16.')
param hubVnetAddressPrefix string = '10.0.0.0/16'

// GatewaySubnet CIDR; must be /27 or larger per Azure requirement
@description('Subnet CIDR for GatewaySubnet (/27 or larger).')
param gatewaySubnetPrefix string = '10.0.0.0/27'

// AzureBastionSubnet CIDR; must be /26 or larger per Azure requirement
@description('Subnet CIDR for AzureBastionSubnet (/26 or larger).')
param bastionSubnetPrefix string = '10.0.1.0/26'

// AzureFirewallSubnet CIDR; must be /26 or larger per Azure requirement
@description('Subnet CIDR for AzureFirewallSubnet (/26 or larger).')
param firewallSubnetPrefix string = '10.0.2.0/26'

// Management subnet for shared services and jump VMs
@description('Subnet CIDR for management/shared services subnet.')
param mgmtSubnetPrefix string = '10.0.3.0/24'

// Resource ID of Log Analytics workspace for diagnostics
@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

// Resource ID of storage account for NSG flow logs
@description('Storage account resource ID for NSG flow log retention.')
param flowLogStorageAccountId string

// ExpressRoute gateway SKU - AZ-suffixed SKUs are zone-redundant.
// Enterprise environments mandate ExpressRoute: dedicated private circuit over MPLS/fibre,
// no public internet traversal. S2S VPN is not appropriate at enterprise scale (see ADR-10).
@description('ExpressRoute Gateway SKU. AZ-suffixed SKUs are zone-redundant.')
@allowed(['ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ', 'ErGwScale'])
param erGatewaySku string = 'ErGw1AZ'

// DNS resolver inbound subnet CIDR; /28 minimum, dedicated, delegated to dnsResolvers
@description('Subnet CIDR for DNS resolver inbound endpoint (/28 or larger).')
param dnsResolverInboundSubnetPrefix string = '10.0.4.0/28'

// DNS resolver outbound subnet CIDR; /28 minimum, dedicated, delegated to dnsResolvers
@description('Subnet CIDR for DNS resolver outbound endpoint (/28 or larger).')
param dnsResolverOutboundSubnetPrefix string = '10.0.5.0/28'

// ── Variables ─────────────────────────────────────────────────────────────────

// Common enterprise tag set - passed in from main.bicep var commonTags.
// All resources in this module are tagged with this set.
@description('Common tag set applied to every resource in this module. Passed from main.bicep.')
param tags object

// Hub VNet name follows <env>-hub-vnet convention
var hubVnetName = '${environment}-hub-vnet'

// Bastion name follows <env>-hub-bastion convention
var bastionName = '${environment}-hub-bastion'

// ExpressRoute gateway name follows <env>-hub-ergw convention
var erGatewayName = '${environment}-hub-ergw'

// Network Watcher name follows Azure default naming convention
var networkWatcherName = 'NetworkWatcher_${location}'

// ── NSG - Management Subnet ───────────────────────────────────────────────────
// NSG protecting the management/shared services subnet inbound rules
module nsgMgmt 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-mgmt-deploy'
  params: {
    // NSG name scoped to management subnet
    name: '${environment}-hub-mgmt-nsg'
    // Deploy in same region as VNet
    location: location
    // Apply shared tag set to NSG resource
    tags: tags
    // NSG flow logs sent to Log Analytics via diagnostic settings
    diagnosticSettings: [
      {
        // Diagnostic setting name for Log Analytics integration
        name: 'diag-nsg-mgmt'
        // Route all NSG logs to central workspace
        workspaceResourceId: logAnalyticsWorkspaceId
        // Enable all log categories for full visibility
        logCategoriesAndGroups: [
          {
            // Collect all available log groups
            categoryGroup: 'allLogs'
          }
        ]
      }
    ]
    // Inbound security rules for management subnet
    securityRules: [
      {
        // Deny all inbound internet traffic explicitly
        name: 'Deny-Inbound-Internet'
        properties: {
          // Block ingress from public internet
          priority: 4000
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Block all inbound internet traffic to management subnet.'
        }
      }
      {
        // Deny outbound SSH - prevent lateral traversal from management subnet.
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
          description: 'Block lateral SSH from management subnet; use Azure Bastion for remote access.'
        }
      }
      {
        // Deny outbound RDP - prevent lateral traversal from management subnet.
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
          description: 'Block lateral RDP from management subnet; use Azure Bastion for remote access.'
        }
      }
    ]
  }
}

// ── NSG - DNS Resolver Inbound Subnet ────────────────────────────────────────
// NSG protecting the inbound endpoint subnet; outbound subnet cannot have an NSG
module nsgDnsResolverInbound 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-dnsresolver-inbound-deploy'
  params: {
    // NSG name scoped to DNS resolver inbound subnet
    name: '${environment}-hub-dnsresolver-inbound-nsg'
    // Deploy in same region as hub VNet
    location: location
    // Apply shared tag set to NSG resource
    tags: tags
    // Diagnostics send NSG logs to central Log Analytics workspace
    diagnosticSettings: [
      {
        // Diagnostic setting name for DNS resolver inbound NSG
        name: 'diag-nsg-dnsresolver-inbound'
        // Route all NSG logs to central workspace
        workspaceResourceId: logAnalyticsWorkspaceId
        // Enable all log categories for full visibility
        logCategoriesAndGroups: [
          {
            // Capture all available NSG log groups
            categoryGroup: 'allLogs'
          }
        ]
      }
    ]
    // Security rules for DNS resolver inbound subnet
    securityRules: [
      {
        // Allow DNS queries inbound from VNet and ExpressRoute-connected on-prem
        name: 'Allow-DNS-Inbound-VirtualNetwork'
        properties: {
          // Highest priority; DNS queries must reach inbound endpoint
          priority: 100
          // DNS uses both UDP (standard) and TCP (large responses/zone transfer)
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          // VirtualNetwork tag covers peered spokes and VPN-connected on-prem
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          // Port 53 is standard DNS; resolver listens on both UDP and TCP
          destinationPortRange: '53'
          description: 'Allow DNS from VNet and connected on-prem networks.'
        }
      }
      {
        // Allow Azure health probe; required for resolver service health checks
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          // Health probe must succeed before AzureLoadBalancer tag
          priority: 200
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          // AzureLoadBalancer tag covers all Azure infrastructure health probes
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Allow Azure health probe traffic for DNS resolver.'
        }
      }
      {
        // Deny all inbound internet traffic to DNS resolver subnet
        name: 'Deny-Inbound-Internet'
        properties: {
          // Lowest priority catch-all; blocks all internet-sourced traffic
          priority: 4000
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          // Block all internet-sourced inbound traffic
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Block all inbound internet traffic to DNS resolver subnet.'
        }
      }
      {
        // Deny outbound SSH - DNS resolver inbound endpoint has no reason to initiate SSH.
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
          description: 'Block lateral SSH from DNS resolver inbound subnet.'
        }
      }
      {
        // Deny outbound RDP - DNS resolver inbound endpoint has no reason to initiate RDP.
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
          description: 'Block lateral RDP from DNS resolver inbound subnet.'
        }
      }
    ]
  }
}

// ── NSG - Bastion Subnet ──────────────────────────────────────────────────────
// AzureBastionSubnet requires a specific NSG with rules mandated by Microsoft.
// Reference: https://learn.microsoft.com/en-us/azure/bastion/bastion-nsg
module nsgBastion 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-bastion-deploy'
  params: {
    name: '${environment}-hub-bastion-nsg'
    location: location
    tags: tags
    diagnosticSettings: [
      {
        name: 'diag-nsg-bastion'
        workspaceResourceId: logAnalyticsWorkspaceId
        logCategoriesAndGroups: [{ categoryGroup: 'allLogs' }]
      }
    ]
    securityRules: [
      // ── Inbound - required by Azure Bastion ──────────────────────────────────
      {
        name: 'Allow-Inbound-HTTPS-Internet'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
          description: 'Allow HTTPS from Internet so users can open the Bastion portal.'
        }
      }
      {
        name: 'Allow-Inbound-GatewayManager'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
          description: 'Allow Bastion control-plane traffic from GatewayManager service tag.'
        }
      }
      {
        name: 'Allow-Inbound-AzureLoadBalancer'
        properties: {
          priority: 120
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
          description: 'Allow Azure Load Balancer health probes to Bastion.'
        }
      }
      {
        name: 'Allow-Inbound-BastionHostComms-8080'
        properties: {
          priority: 130
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '8080'
          description: 'Allow inter-node communication between Bastion instances (port 8080).'
        }
      }
      {
        name: 'Allow-Inbound-BastionHostComms-5701'
        properties: {
          priority: 131
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '5701'
          description: 'Allow inter-node communication between Bastion instances (port 5701).'
        }
      }
      {
        name: 'Deny-Inbound-All'
        properties: {
          priority: 4000
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny all inbound traffic not explicitly permitted above.'
        }
      }
      // ── Outbound - required by Azure Bastion ─────────────────────────────────
      {
        // Bastion must initiate SSH/RDP to target VMs - this is its primary function.
        // Azure.NSG.LateralTraversal is suppressed for this NSG in ps-rule.yaml.
        name: 'Allow-Outbound-SSH'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '22'
          description: 'Allow Bastion to initiate SSH sessions to target VMs.'
        }
      }
      {
        name: 'Allow-Outbound-RDP'
        properties: {
          priority: 101
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3389'
          description: 'Allow Bastion to initiate RDP sessions to target VMs.'
        }
      }
      {
        name: 'Allow-Outbound-AzureCloud'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
          description: 'Allow Bastion management-plane communication with Azure.'
        }
      }
      {
        name: 'Allow-Outbound-CertValidation'
        properties: {
          priority: 120
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
          description: 'Allow HTTP for certificate revocation (OCSP/CRL) checks.'
        }
      }
      {
        name: 'Allow-Outbound-BastionHostComms-8080'
        properties: {
          priority: 130
          protocol: '*'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '8080'
          description: 'Allow inter-node Bastion communication (port 8080).'
        }
      }
      {
        name: 'Allow-Outbound-BastionHostComms-5701'
        properties: {
          priority: 131
          protocol: '*'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '5701'
          description: 'Allow inter-node Bastion communication (port 5701).'
        }
      }
    ]
  }
}

// ── NSG - DNS Resolver Outbound Subnet ───────────────────────────────────────
// Azure DNS Private Resolver outbound endpoint subnets support NSGs.
// This NSG blocks lateral movement while leaving DNS forwarding unaffected.
module nsgDnsResolverOutbound 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-dnsresolver-outbound-deploy'
  params: {
    name: '${environment}-hub-dnsresolver-outbound-nsg'
    location: location
    tags: tags
    diagnosticSettings: [
      {
        name: 'diag-nsg-dnsresolver-outbound'
        workspaceResourceId: logAnalyticsWorkspaceId
        logCategoriesAndGroups: [{ categoryGroup: 'allLogs' }]
      }
    ]
    securityRules: [
      {
        // DNS resolver outbound has no reason to initiate SSH; block lateral movement.
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
          description: 'Block lateral SSH from DNS resolver outbound subnet.'
        }
      }
      {
        // DNS resolver outbound has no reason to initiate RDP; block lateral movement.
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
          description: 'Block lateral RDP from DNS resolver outbound subnet.'
        }
      }
    ]
  }
}

// ── Route Table - Management Subnet ───────────────────────────────────────────
// UDR forcing all egress through Azure Firewall private IP
module udrMgmt 'br/public:avm/res/network/route-table:0.5.0' = {
  name: 'udr-mgmt-deploy'
  params: {
    // Route table name scoped to management subnet
    name: '${environment}-hub-mgmt-udr'
    // Deploy in same region as VNet
    location: location
    // Apply shared tag set to route table
    tags: tags
    // Disable BGP propagation; all routes must be explicit UDRs
    disableBgpRoutePropagation: true
    // Routes directing traffic through Azure Firewall
    routes: [
      {
        // Route all RFC1918 traffic through Azure Firewall
        name: 'route-to-firewall-default'
        properties: {
          // Default route captures all egress traffic
          addressPrefix: '0.0.0.0/0'
          // Next hop is Azure Firewall private IP (update per environment)
          nextHopType: 'VirtualAppliance'
          // - Replace with actual Azure Firewall private IP after AFW deploy
          // - This UDR enforces centralized inspection for all outbound traffic
          nextHopIpAddress: '10.0.2.4'
        }
      }
    ]
  }
}

// ── Hub Virtual Network ───────────────────────────────────────────────────────
// Hub VNet with GatewaySubnet, AzureBastionSubnet, AzureFirewallSubnet, mgmt
module hubVnet 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'hub-vnet-deploy'
  params: {
    // Hub VNet name derived from environment variable
    name: hubVnetName
    // Deploy VNet in target region
    location: location
    // Apply shared tag set to VNet
    tags: tags
    // Hub address space; must not overlap with spokes or on-prem
    addressPrefixes: [hubVnetAddressPrefix]
    // Subnets within the hub VNet
    subnets: [
      {
        // GatewaySubnet required by VPN/ExpressRoute gateways
        name: 'GatewaySubnet'
        // Must be /27 or larger; no NSG allowed on GatewaySubnet
        addressPrefix: gatewaySubnetPrefix
      }
      {
        // AzureBastionSubnet required by Azure Bastion service
        name: 'AzureBastionSubnet'
        // Must be /26 or larger; NSG is mandatory with specific rules per Microsoft docs
        addressPrefix: bastionSubnetPrefix
        // Associate mandatory Bastion NSG (inbound HTTPS + GatewayManager; outbound SSH/RDP to VNet)
        networkSecurityGroupResourceId: nsgBastion.outputs.resourceId
      }
      {
        // AzureFirewallSubnet required for Azure Firewall deployment
        name: 'AzureFirewallSubnet'
        // Must be /26 or larger; no NSG or UDR on firewall subnet
        addressPrefix: firewallSubnetPrefix
      }
      {
        // Management subnet for shared services, jump VMs, and tooling
        name: 'snet-management'
        // /24 provides up to 251 usable IPs for management workloads
        addressPrefix: mgmtSubnetPrefix
        // Associate management NSG deployed above
        networkSecurityGroupResourceId: nsgMgmt.outputs.resourceId
        // Associate management UDR deployed above
        routeTableResourceId: udrMgmt.outputs.resourceId
      }
      {
        // DNS resolver inbound endpoint subnet; dedicated /28, no other resources
        name: 'snet-dnsresolver-inbound'
        // /28 minimum required by Azure DNS Private Resolver inbound endpoints
        addressPrefix: dnsResolverInboundSubnetPrefix
        // NSG restricts inbound to DNS (53) from VNet + AzureLoadBalancer only
        networkSecurityGroupResourceId: nsgDnsResolverInbound.outputs.resourceId
        // Delegate subnet to DNS resolver service; no other resources permitted
        delegation: 'Microsoft.Network/dnsResolvers'
      }
      {
        // DNS resolver outbound endpoint subnet; dedicated /28, NSG blocks lateral movement
        name: 'snet-dnsresolver-outbound'
        // /28 minimum required by Azure DNS Private Resolver outbound endpoints
        addressPrefix: dnsResolverOutboundSubnetPrefix
        // NSG blocks lateral SSH/RDP; Azure DNS Private Resolver outbound subnets support NSGs
        networkSecurityGroupResourceId: nsgDnsResolverOutbound.outputs.resourceId
        // Delegate subnet to DNS resolver service; no other resources permitted
        delegation: 'Microsoft.Network/dnsResolvers'
      }
    ]
    // Send VNet diagnostic logs to central workspace
    diagnosticSettings: [
      {
        // Diagnostic setting name for VNet flow analysis
        name: 'diag-hub-vnet'
        // Route logs to central Log Analytics workspace
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// ── Azure Bastion ─────────────────────────────────────────────────────────────
// Standard SKU Bastion for RDP/SSH over HTTPS without public IPs on VMs
module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = {
  name: 'bastion-deploy'
  params: {
    // Bastion name scoped to hub environment
    name: bastionName
    // Deploy Bastion in same region as hub VNet
    location: location
    // Apply shared tag set to Bastion resource
    tags: tags
    // Reference the hub VNet where AzureBastionSubnet was created
    virtualNetworkResourceId: hubVnet.outputs.resourceId
    // Standard SKU enables file copy, tunneling, and native client
    skuName: 'Standard'
    // Zone-redundant Bastion deployment across all three zones
    availabilityZones: [1, 2, 3]
    // Enable file copy for Standard and above SKUs
    enableFileCopy: true
    // Send Bastion audit logs to central Log Analytics workspace
    diagnosticSettings: [
      {
        // Diagnostic setting name for Bastion session logs
        name: 'diag-bastion'
        // Route all Bastion logs to central workspace
        workspaceResourceId: logAnalyticsWorkspaceId
        // Enable all log categories (BastionAuditLogs etc.)
        logCategoriesAndGroups: [
          {
            // Capture all Bastion audit activity
            categoryGroup: 'allLogs'
          }
        ]
      }
    ]
    // Resource delete lock prevents accidental hub Bastion removal
    lock: {
      // CanNotDelete prevents accidental deletion of Bastion
      kind: 'CanNotDelete'
      name: 'lock-bastion'
    }
  }
}

// ── ExpressRoute Gateway ──────────────────────────────────────────────────────
// Zone-redundant ExpressRoute gateway providing dedicated private connectivity to on-premises.
// S2S VPN is NOT used - it traverses the public internet and is unsuitable for enterprise.
// ExpressRoute delivers sub-10 ms dedicated latency over MPLS/fibre with SLA (ADR-10).
module erGateway 'br/public:avm/res/network/virtual-network-gateway:0.11.1' = {
  name: 'ergw-deploy'
  params: {
    // ExpressRoute gateway name scoped to hub environment
    name: erGatewayName
    // Deploy gateway in same region as hub VNet
    location: location
    // Apply shared tag set to gateway resource
    tags: tags
    // ExpressRoute type - private dedicated circuit, not S2S VPN over public internet
    gatewayType: 'ExpressRoute'
    // Reference the hub VNet containing GatewaySubnet
    virtualNetworkResourceId: hubVnet.outputs.resourceId
    // ErGw1AZ: zone-redundant minimum (1 Gbps); scale to ErGw2AZ/ErGw3AZ/ErGwScale
    skuName: erGatewaySku
    // Active-passive mode with no BGP - standard for ExpressRoute gateways
    // ExpressRoute HA is provided by the circuit redundancy, not gateway clustering
    clusterSettings: {
      clusterMode: 'activePassiveNoBgp'
    }
    // Zone-redundant public IP for the gateway endpoint
    publicIpAvailabilityZones: [1, 2, 3]
    // Send gateway diagnostic logs to central workspace
    diagnosticSettings: [
      {
        // Diagnostic setting name for ExpressRoute gateway logs
        name: 'diag-ergw'
        // Route all gateway logs to central Log Analytics workspace
        workspaceResourceId: logAnalyticsWorkspaceId
        // Enable all log categories for circuit and connectivity diagnostics
        logCategoriesAndGroups: [
          {
            // Capture all ExpressRoute gateway log groups
            categoryGroup: 'allLogs'
          }
        ]
      }
    ]
    // Resource delete lock prevents accidental gateway removal
    lock: {
      // CanNotDelete prevents destroying dedicated hybrid connectivity
      kind: 'CanNotDelete'
      name: 'lock-ergw'
    }
  }
}

// ── Network Watcher ───────────────────────────────────────────────────────────
// Network Watcher with NSG flow logs for management subnet
module networkWatcher 'br/public:avm/res/network/network-watcher:0.5.1' = {
  name: 'network-watcher-deploy'
  params: {
    // Network Watcher name follows Azure auto-provisioned naming convention
    name: networkWatcherName
    // Deploy watcher in same region as all hub resources
    location: location
    // Apply shared tag set to Network Watcher
    tags: tags
    // NSG flow logs for management subnet NSG
    flowLogs: [
      {
        // Flow log name scoped to management NSG
        name: '${environment}-mgmt-nsg-flowlog'
        // Target NSG is the management subnet NSG deployed above
        targetResourceId: nsgMgmt.outputs.resourceId
        // Store flow logs in designated storage account
        storageResourceId: flowLogStorageAccountId
        // Enable flow log collection
        enabled: true
        // Retain flow logs for 90 days for compliance and forensics
        retentionInDays: 90
        // Format version 2 includes bytes and packets per flow
        formatVersion: 2
        // Route traffic analytics to central Log Analytics workspace
        workspaceResourceId: logAnalyticsWorkspaceId
        // Run traffic analytics every 10 minutes so as to not fill up workspace with too-frequent updates and costing us; adjust as needed
        trafficAnalyticsInterval: 10
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

// Hub VNet resource ID used by spoke peering and other modules
output hubVnetResourceId string = hubVnet.outputs.resourceId

// Hub VNet name for reference in peering and spoke deployments
output hubVnetName string = hubVnet.outputs.name

// Management NSG resource ID used by spoke modules and flow logs
output mgmtNsgResourceId string = nsgMgmt.outputs.resourceId

// ExpressRoute gateway resource ID for circuit connection objects
output erGatewayResourceId string = erGateway.outputs.resourceId

// Bastion resource ID for audit and access log correlation
output bastionResourceId string = bastion.outputs.resourceId

// DNS resolver inbound subnet resource ID for private-dns.bicep DNS resolver deployment
output dnsResolverInboundSubnetResourceId string = '${hubVnet.outputs.resourceId}/subnets/snet-dnsresolver-inbound'

// DNS resolver outbound subnet resource ID for private-dns.bicep DNS resolver deployment
output dnsResolverOutboundSubnetResourceId string = '${hubVnet.outputs.resourceId}/subnets/snet-dnsresolver-outbound'
