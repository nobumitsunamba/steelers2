#!/usr/bin/env bash
# =============================================================================
# Function App の Managed Identity を Azure SQL の DB ユーザーとして登録する。
# deploymentScripts(AzureCLI)から SQL 管理者の User-assigned MI で実行される。
#
# 必要な環境変数:
#   SQL_SERVER_FQDN   接続先サーバー (例: xxx.database.windows.net)
#   SQL_DATABASE      対象データベース名
#   FUNCTION_APP_NAME DB ユーザーとして登録する Function App 名(= MI 表示名)
#   AAD_CLIENT_ID     go-sqlcmd が選択する User-assigned MI のクライアント ID
# =============================================================================
set -euo pipefail

echo "Downloading go-sqlcmd..."
curl -sSL -o sqlcmd.tar.bz2 \
  https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.0/sqlcmd-linux-amd64.tar.bz2
tar -xjf sqlcmd.tar.bz2
chmod +x ./sqlcmd

# Function App の Managed Identity を DB ユーザーとして登録する T-SQL。
read -r -d '' TSQL <<SQL || true
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'${FUNCTION_APP_NAME}')
BEGIN
    CREATE USER [${FUNCTION_APP_NAME}] FROM EXTERNAL PROVIDER;
END;
ALTER ROLE db_datareader ADD MEMBER [${FUNCTION_APP_NAME}];
ALTER ROLE db_datawriter ADD MEMBER [${FUNCTION_APP_NAME}];
SQL

# Serverless の Auto-pause 復帰待ちのためリトライ（最大8回 / 30秒間隔）。
attempt=1
max=8
until ./sqlcmd \
        -S "${SQL_SERVER_FQDN}" \
        -d "${SQL_DATABASE}" \
        --authentication-method ActiveDirectoryManagedIdentity \
        -U "${AAD_CLIENT_ID}" \
        -b \
        -Q "${TSQL}"
do
    if [ "${attempt}" -ge "${max}" ]; then
        echo "Failed to provision SQL user after ${attempt} attempts."
        exit 1
    fi
    echo "Attempt ${attempt} failed (DB may be resuming). Retrying in 30s..."
    attempt=$((attempt + 1))
    sleep 30
done

echo "Managed Identity [${FUNCTION_APP_NAME}] provisioned as DB user."
