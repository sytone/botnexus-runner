targetScope = 'resourceGroup'

param location string = resourceGroup().location
@minLength(5)
@maxLength(50)
param registryName string

// First deployment only: create the registry before building/publishing the image.
// Matches main.bicep so the subsequent infrastructure deployment retains this registry.
resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: location
  tags: {
    workload: 'botnexus-buildtest'
    managedBy: 'bicep'
    authentication: 'managed-identity-only'
  }
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

output acrName string = registry.name
output loginServer string = registry.properties.loginServer
output registryId string = registry.id
