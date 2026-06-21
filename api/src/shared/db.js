'use strict';

const sql = require('mssql');
const { trackException } = require('./telemetry');

// Azure SQL Database (Serverless) への接続を担うモジュール。
// 接続設定は環境変数から読み込む（SQL 認証）。
//   SQL_SERVER   : 例 "my-sql.database.windows.net"
//   SQL_DATABASE : データベース名
//   SQL_USER     : SQL 認証ユーザー
//   SQL_PASSWORD : SQL 認証パスワード
//
// 接続プールはモジュールスコープでシングルトンとして保持し、
// Functions の呼び出しごとに新規接続せず使い回す（コールドスタート時のみ確立）。
let poolPromise;

function getConfig() {
  const server = process.env.SQL_SERVER;
  const database = process.env.SQL_DATABASE;
  const user = process.env.SQL_USER;
  const password = process.env.SQL_PASSWORD;

  if (!server || !database || !user || !password) {
    throw new Error('SQL_SERVER / SQL_DATABASE / SQL_USER / SQL_PASSWORD is not set');
  }

  return {
    server,
    database,
    user,
    password,
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

// 接続プール(シングルトン)を取得する。未確立なら一度だけ確立する。
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

// キャッシュしているプールを破棄し、次回 getPool() で再接続させる。
function resetPool() {
  const current = poolPromise;
  poolPromise = null;
  // 後始末（クローズ）はベストエフォート。失敗しても握りつぶす。
  Promise.resolve(current)
    .then((pool) => pool && pool.close())
    .catch(() => {});
}

// Serverless DB の Auto-pause 復帰待ちエラーかどうかを判定する。
// 復帰中は「40613 / Database '...' is not currently available」が返る。
function isAutoPauseResumeError(err) {
  if (!err) return false;
  const code = err.number || err.code;
  if (Number(code) === 40613) return true;
  return /is not currently available/i.test(String(err.message || ''));
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// プールからリクエストを生成して T-SQL を実行する。
// `params` は { 名前: 値 } 形式で渡し、@名前 でバインドする。
async function execute(text, params) {
  const pool = await getPool();
  const request = pool.request();
  for (const [name, value] of Object.entries(params)) {
    request.input(name, value);
  }
  return request.query(text);
}

// T-SQL を実行する。
// Serverless の Auto-pause 復帰待ち(40613 / is not currently available)の場合のみ、
// プールを破棄して 1 回だけ自動リトライする。
async function query(text, params = {}) {
  try {
    return await execute(text, params);
  } catch (err) {
    if (isAutoPauseResumeError(err)) {
      // 復帰待ち: プールを破棄し、少し待ってから 1 回だけリトライする。
      resetPool();
      await delay(3000);
      try {
        return await execute(text, params);
      } catch (retryErr) {
        trackException(retryErr, { kind: 'db_query', query: text, retried: true });
        throw retryErr;
      }
    }

    // それ以外のエラーはリトライせずトラッキングして送出する。
    trackException(err, { kind: 'db_query', query: text });
    throw err;
  }
}

module.exports = { sql, getPool, query };
