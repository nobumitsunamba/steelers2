// =============================================================================
// コベルコ神戸スティーラーズ ファンサイト API インフラ
//
// 構成:
//   - Microsoft.Sql/servers            : Entra ID 認証のみ(SQL認証無効)
//   - Microsoft.Sql/servers/databases  : Serverless (GP_S_Gen5_1, Auto-pause 60分)
//   - Microsoft.Web/sites (Function App): System-assigned Managed Identity 付与
//   - Microsoft.Resources/deploymentScripts:
//       Function App の Managed Identity を DB ユーザーとして自動登録
//       (CREATE USER FROM EXTERNAL PROVIDER + db_datareader / db_datawriter)
//
// 認証方針:
//   SQL 認証は無効化(azureADOnlyAuthentication: true)。
//   サーバー管理者には User-assigned Managed Identity を Entra 管理者として設定し、
//   その ID を使って deploymentScript から Function App の MI を DB ユーザー登録する。
// =============================================================================

@description('リソースを作成するリージョン')
param location string = resourceGroup().location

@description('リソース名のベースとなるプレフィックス')
param namePrefix string = 'steelers'

@description('リソース名の一意性を担保するためのサフィックス')
param nameSuffix string = uniqueString(resourceGroup().id)

var sqlServerName = '${namePrefix}-sql-${nameSuffix}'
var sqlDatabaseName = '${namePrefix}-db'
var functionAppName = '${namePrefix}-func-${nameSuffix}'
var planName = '${namePrefix}-plan-${nameSuffix}'
var storageName = toLower('${namePrefix}st${nameSuffix}')
var logName = '${namePrefix}-logs-${nameSuffix}'
var appInsightsName = '${namePrefix}-ai-${nameSuffix}'
var sqlAdminIdentityName = '${namePrefix}-sqladmin-${nameSuffix}'

// -----------------------------------------------------------------------------
// SQL 管理者となる User-assigned Managed Identity
// deploymentScript はこの ID で sqlcmd を実行し、DB ユーザーを作成する。
// -----------------------------------------------------------------------------
resource sqlAdminIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: sqlAdminIdentityName
  location: location
}

// -----------------------------------------------------------------------------
// Azure SQL Server (Entra ID 認証のみ)
// -----------------------------------------------------------------------------
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sqlAdminIdentity.id}': {}
    }
  }
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    // SQL 認証は使わず、Entra 管理者として User-assigned MI を設定する。
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Application'
      login: sqlAdminIdentity.name
      sid: sqlAdminIdentity.properties.principalId
      tenantId: subscription().tenantId
      // SQL 認証を無効化(Entra ID 認証のみ)。
      azureADOnlyAuthentication: true
    }
  }
}

// deploymentScript(ACI) や Function App から接続できるよう、Azure サービスを許可する。
resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// -----------------------------------------------------------------------------
// Azure SQL Database (Serverless / 自動一時停止)
// -----------------------------------------------------------------------------
resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  sku: {
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    // 60分アイドルで自動一時停止。
    autoPauseDelay: 60
    // 最小 vCore は 0.5（Bicep は小数リテラル非対応のため json() を使用）。
    minCapacity: json('0.5')
    zoneRedundant: false
    maxSizeBytes: 34359738368
  }
}

// -----------------------------------------------------------------------------
// 監視・ストレージ・プラン（Function App の前提リソース）
// -----------------------------------------------------------------------------
resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logWorkspace.id
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  // 従量課金（Consumption）プラン。
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true
  }
}

// -----------------------------------------------------------------------------
// Function App (System-assigned Managed Identity 付与)
// -----------------------------------------------------------------------------
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  // System-assigned Managed Identity を付与。
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Node|20'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~20'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        // DB アクセス設定（接続文字列ではなく Managed Identity 認証）。
        {
          name: 'SQL_SERVER'
          value: sqlServer.properties.fullyQualifiedDomainName
        }
        {
          name: 'SQL_DATABASE'
          value: sqlDatabaseName
        }
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// deploymentScript: Function App の Managed Identity を DB ユーザー登録する
//
// SQL 管理者である User-assigned MI(sqlAdminIdentity)で go-sqlcmd を実行し、
//   CREATE USER [<functionApp>] FROM EXTERNAL PROVIDER;
//   ALTER ROLE db_datareader ADD MEMBER [<functionApp>];
//   ALTER ROLE db_datawriter ADD MEMBER [<functionApp>];
// を流す。Serverless の Auto-pause 復帰待ちのためリトライする。
// -----------------------------------------------------------------------------
resource registerSqlUser 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'register-${functionAppName}-sql-user'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sqlAdminIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.55.0'
    retentionInterval: 'PT1H'
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      {
        name: 'SQL_SERVER_FQDN'
        value: sqlServer.properties.fullyQualifiedDomainName
      }
      {
        name: 'SQL_DATABASE'
        value: sqlDatabaseName
      }
      {
        name: 'FUNCTION_APP_NAME'
        value: functionApp.name
      }
      {
        // go-sqlcmd が User-assigned MI を選択するためのクライアント ID。
        name: 'AAD_CLIENT_ID'
        value: sqlAdminIdentity.properties.clientId
      }
    ]
    // スクリプト本体は別ファイルから読み込む（loadTextContent は ${} を
    // Bicep 補間しないため、bash の変数展開をそのまま記述できる）。
    scriptContent: loadTextContent('register-sql-user.sh')
  }
  dependsOn: [
    allowAzureServices
    sqlDatabase
  ]
}

// -----------------------------------------------------------------------------
// 出力
// -----------------------------------------------------------------------------
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabaseName
output functionAppName string = functionApp.name
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
