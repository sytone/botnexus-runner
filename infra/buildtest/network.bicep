targetScope = 'resourceGroup'

// Network prerequisites for a separately reviewed existing-environment migration.
// This is not a maintenance entrypoint or evidence that attachment is supported.
// main.bicep also declares these resources; pass the SAME private names to both
// templates to avoid creating or changing a different topology.
// Verify current environment type and provider restrictions before any change.
// A subnet attachment must be reviewed as its own request, not combined with
// unrelated registry, storage, identity, role or job changes from main.bicep.
// Preserve delegation to Microsoft.App/environments, NAT attachment and a
// non-internal frontend. Verify CIDR compatibility with the actual deployment:
// avoid 169.254.0.0/16, 172.30.0.0/16, 172.31.0.0/16, 192.0.2.0/24 and
// workload-profile reservations 100.100.0.0/17, 100.100.128.0/19,
// 100.100.160.0/19 and 100.100.192.0/19. Attachment is one-way; removing
// a subnet later is not a supported rollback. See README-migration.md.

param location string = resourceGroup().location

var tags = {
  workload: 'botnexus-buildtest'
  managedBy: 'bicep'
  authentication: 'managed-identity-only'
}

@minLength(1)
param vnetName string
@minLength(1)
param subnetName string
@minLength(1)
param natGatewayName string
@minLength(1)
param publicIpName string

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = {
  name: natGatewayName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: publicIp.id
      }
    ]
    idleTimeoutInMinutes: 4
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          // Workload-profile environments need at least a /27; /23 leaves headroom for scale-out.
          addressPrefix: '10.0.0.0/23'
          natGateway: {
            id: natGateway.id
          }
          serviceEndpoints: []
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
              type: 'Microsoft.Network/virtualNetworks/subnets/delegations'
            }
          ]
        }
        type: 'Microsoft.Network/virtualNetworks/subnets'
      }
    ]
    virtualNetworkPeerings: []
    enableDdosProtection: false
  }
}

// subnetId identifies the declared subnet for a separately reviewed attachment.
// An output is not proof of deployment or permission to mutate an environment.
output subnetId string = vnet.properties.subnets[0].id
output vnetName string = vnet.name
output subnetName string = subnetName
output natGatewayName string = natGateway.name
output publicIpName string = publicIp.name
output natPublicIpAddress string = publicIp.properties.ipAddress
