'use strict';

const sql = require('mssql');
const { trackException } = require('./telemetry');

// Azure SQL Database (Serverless) への接続を担うモジュール。
// 認証は SQL 認証ではなく Microsoft Entra ID（Azure AD）を使用する。
//   - 本番(Function App): System-assigned Managed Identity
//   - ローカル開発: `az login` で取得した開発者資格情報
// いずれも `azure-active-directory-default` で DefaultAzureCredential により
// 自動的に解決される（@azure/identity が解決を担当する）。
//
// 接続プールはモジュールスコープでシングルトンとして保持し、
// 関数呼び出し間で再利用する（コールドスタート以外では使い回される）。
let poolPromise;

function getConfig() {
  // 例: SQL_SERVER = "my-sql.database.windows.net"
  const server = process.env.SQL_SERVER;
  const database = process.env.SQL_DATABASE;
  if (!server || !database) {
    throw new Error('SQL_SERVER / SQL_DATABASE is not set');
  }

  return {
    server,
    database,
    authentication: {
      // DefaultAzureCredential を利用（Managed Identity / az login 等を自動解決）。
      type: 'azure-active-directory-default',
    },
    options: {
      // Azure SQL は TLS 必須。
      encrypt: true,
      trustServerCertificate: false,
    },
    pool: {
      max: 5,
      min: 0,
      idleTimeoutMillis: 30000,
    },
    // Serverless の Auto-pause からの復帰には時間がかかるため、
    // 接続・リクエストのタイムアウトを長めに設定する。
    connectionTimeout: 30000,
    requestTimeout: 30000,
  };
}

function getPool() {
  if (!poolPromise) {
    const pool = new sql.ConnectionPool(getConfig());
    // プールでエラーが発生したらキャッシュを破棄し、次回再接続できるようにする。
    pool.on('error', () => {
      poolPromise = null;
    });
    poolPromise = pool.connect().catch((err) => {
      // 接続確立に失敗した場合もキャッシュを破棄する。
      poolPromise = null;
      throw err;
    });
  }
  return poolPromise;
}

// Serverless の Auto-pause からの復帰中などに発生する「一時的」エラーかを判定する。
// 復帰中は接続が拒否され、Function 経由では 503 相当として表面化する。
function isTransientError(err) {
  const code = err && (err.number || err.code);
  // 40613      : Database '...' on server '...' is not currently available
  // 42108/42109: serverless データベースの再開処理中
  // 49918-49920: リクエスト処理不可（一時的）
  // 4060/18456 : 復帰直後にログインがまだ確立できないケース
  const transientNumbers = [40613, 42108, 42109, 49918, 49919, 49920, 4060, 18456];
  if (transientNumbers.includes(Number(code))) return true;
  if (['ETIMEOUT', 'ESOCKET', 'ECONNCLOSED', 'ECONNRESET'].includes(code)) return true;

  const msg = String((err && err.message) || '');
  return /not currently available|is paused|resuming|is not currently|timeout/i.test(msg);
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// T-SQL を実行する。`params` は { 名前: 値 } 形式で渡し、@名前 でバインドする。
// Auto-pause 復帰中の一時エラー(503相当)に対しては指数バックオフでリトライする。
async function query(text, params = {}) {
  const maxAttempts = 5;
  let lastErr;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      const pool = await getPool();
      const request = pool.request();
      for (const [name, value] of Object.entries(params)) {
        request.input(name, value);
      }
      return await request.query(text);
    } catch (err) {
      lastErr = err;

      if (isTransientError(err)) {
        // 接続系の一時エラーなのでプールを破棄して次回再接続する。
        poolPromise = null;
        if (attempt < maxAttempts) {
          // 指数バックオフ: 1s, 2s, 4s, 8s（最大15s）。Auto-pause 復帰待ち。
          const backoff = Math.min(1000 * 2 ** (attempt - 1), 15000);
          await delay(backoff);
          continue;
        }
      }

      // 一時エラー以外、またはリトライ上限に達した場合は記録して送出する。
      trackException(err, { kind: 'db_query', query: text, attempt });
      throw err;
    }
  }

  // 理論上ここには到達しないが、保険として最後のエラーを送出する。
  trackException(lastErr, { kind: 'db_query', query: text });
  throw lastErr;
}

module.exports = { sql, getPool, query };
