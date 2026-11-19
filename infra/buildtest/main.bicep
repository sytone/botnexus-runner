targetScope = 'resourceGroup'

param location string = resourceGroup().location
param operatorObjectId string
// Source-only provisioning contract. Never use broad provisioning for software updates.
// The separately qualified image must be an immutable registry/repository@sha256 digest.
@minLength(1)
param runnerImageRepository string
@minLength(64)
@maxLength(64)
param runnerImageDigest string
@minLength(1)
param projectConfigPath string
@minLength(64)
@maxLength(64)
param projectConfigSha256 string

var runnerImage = '${runnerImageRepository}@sha256:${runnerImageDigest}'

var tags = {
  workload: 'botnexus-buildtest'
  managedBy: 'bicep'
  authentication: 'managed-identity-only'
}
@minLength(5)
@maxLength(50)
param registryName string
@minLength(3)
@maxLength(24)
param storageAccountName string
@minLength(1)
param identityName string
@minLength(1)
param environmentName string
@minLength(1)
param jobName string
@minLength(1)
param vnetName string
@minLength(1)
param subnetName string
@minLength(1)
param natGatewayName string
@minLength(1)
param publicIpName string
@description('Existing subnet network security group resource ID. Preserve the observed attachment when updating an existing environment.')
param subnetNetworkSecurityGroupId string = ''
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var blobContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: 'Premium'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    policies: {
      retentionPolicy: {
        days: 7
        status: 'enabled'
      }
      azureADAuthenticationAsArmPolicy: {
        status: 'enabled'
      }
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    accessTier: 'Hot'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource sources 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'sources'
  properties: {
    publicAccess: 'None'
  }
}

resource artifacts 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'artifacts'
  properties: {
    publicAccess: 'None'
  }
}

// Network prerequisites: use the same explicit private names in network.bicep.
// Delegation, NAT attachment, non-internal frontend and reserved-range avoidance
// are required. Attaching a subnet may change the frontend IP and is one-way;
// do not infer that an existing environment supports attachment from this template.
// Verify its type, provider restrictions, DNS impact and recovery plan separately.
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
          networkSecurityGroup: empty(subnetNetworkSecurityGroupId) ? null : {
            id: subnetNetworkSecurityGroupId
          }
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

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      internal: false
      infrastructureSubnetId: vnet.properties.subnets[0].id
    }
    // Workload-profile configuration is part of the desired template, not proof
    // of an existing environment's type or permission to attach a subnet in place.
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
      {
        name: 'BuildTestD8'
        workloadProfileType: 'D8'
        // Keep idle cost at zero, but allow five independent manual job executions to receive
        // one full D8 node each. Per-execution parallelism remains one below; this scales PR
        // validation lanes, not duplicate replicas within a single validation.
        minimumCount: 0
        maximumCount: 5
      }
    ]
    zoneRedundant: false
  }
}

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: jobName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'BuildTestD8'
    configuration: {
      triggerType: 'Manual'
      // Preserve the fixed 1200-second platform allowance. Do not extend it to
      // conceal a timeout or failing test; inspect retained execution evidence.
      replicaTimeout: 1200
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: [
        {
          server: registry.properties.loginServer
          identity: identity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'runner'
          image: runnerImage
          resources: {
            // D8 provides 8 vCPU / 32 GiB. Give the runner every core but leave 8 GiB for
            // Container Apps runtime overhead instead of allocating the complete node.
            cpu: json('8.0')
            memory: '24Gi'
          }
          env: [
            {
              name: 'AZURE_CLIENT_ID'
              value: identity.properties.clientId
            }
            {
              name: 'SOURCE_BLOB_URL'
              value: 'https://${storage.name}.blob.${az.environment().suffixes.storage}/sources/source.tar.gz'
            }
            {
              name: 'ARTIFACT_BLOB_URL'
              value: 'https://${storage.name}.blob.${az.environment().suffixes.storage}/artifacts'
            }
            {
              name: 'PROJECT_CONFIG_PATH'
              value: projectConfigPath
            }
            {
              name: 'PROJECT_CONFIG_SHA256'
              value: projectConfigSha256
            }
            {
              name: 'RUNNER_IMAGE'
              value: runnerImage
            }
            {
              name: 'REPLICA_TIMEOUT_SECONDS'
              value: '1200'
            }
          ]
        }
      ]
    }
  }
}

resource runnerAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, acrPullRoleId)
  scope: registry
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

resource runnerBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, blobContributorRoleId)
  scope: storage
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: blobContributorRoleId
  }
}

resource operatorBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, operatorObjectId, blobContributorRoleId)
  scope: storage
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: blobContributorRoleId
  }
}

output acrName string = registry.name
output storageAccountName string = storage.name
output jobName string = job.name
output runnerIdentityId string = identity.id
