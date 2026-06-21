// =============================================================================
// コベルコ神戸スティーラーズ ファンサイト API インフラ
//
// 構成:
//   - Microsoft.Sql/servers            : SQL 認証（管理者ログイン/パスワード）
//   - Microsoft.Sql/servers/databases  : Serverless (GP_S_Gen5_1, Auto-pause 60分)
//   - Microsoft.Web/sites (Function App): mssql から SQL 認証で接続
//
// 認証方針:
//   アプリ(Functions)は SQL 認証(SQL_USER / SQL_PASSWORD)で接続する。
//   管理者パスワードは平文でコミットせず、@secure() パラメータとして
//   デプロイ時に Azure CLI の --parameters や GitHub Actions Secrets から渡す。
// =============================================================================

@description('リソースを作成するリージョン')
param location string = resourceGroup().location

@description('リソース名のベースとなるプレフィックス')
param namePrefix string = 'steelers'

@description('リソース名の一意性を担保するためのサフィックス')
param nameSuffix string = uniqueString(resourceGroup().id)

@description('SQL Server の管理者ログイン名（アプリの SQL_USER に利用）')
param sqlAdminLogin string = 'steelersadmin'

@description('SQL Server の管理者パスワード。平文でコミットせず、デプロイ時に安全に渡すこと。')
@secure()
@minLength(12)
param sqlAdminPassword string

var sqlServerName = '${namePrefix}-sql-${nameSuffix}'
var sqlDatabaseName = '${namePrefix}-db'
var functionAppName = '${namePrefix}-func-${nameSuffix}'
var planName = '${namePrefix}-plan-${nameSuffix}'
var storageName = toLower('${namePrefix}st${nameSuffix}')
var logName = '${namePrefix}-logs-${nameSuffix}'
var appInsightsName = '${namePrefix}-ai-${nameSuffix}'

// -----------------------------------------------------------------------------
// Azure SQL Server (SQL 認証)
// -----------------------------------------------------------------------------
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    // SQL 認証の管理者。パスワードは @secure() パラメータから渡す。
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
  }
}

// Function App など Azure サービスから接続できるよう許可する。
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
// Function App (mssql から SQL 認証で接続)
// -----------------------------------------------------------------------------
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
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
        // DB アクセス設定（SQL 認証）。SQL_PASSWORD は @secure() パラメータ由来。
        {
          name: 'SQL_SERVER'
          value: sqlServer.properties.fullyQualifiedDomainName
        }
        {
          name: 'SQL_DATABASE'
          value: sqlDatabaseName
        }
        {
          name: 'SQL_USER'
          value: sqlAdminLogin
        }
        {
          name: 'SQL_PASSWORD'
          value: sqlAdminPassword
        }
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// 出力
// -----------------------------------------------------------------------------
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabaseName
output functionAppName string = functionApp.name
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
