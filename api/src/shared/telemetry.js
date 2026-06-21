'use strict';

// Azure Application Insights の初期化とテレメトリ送信ヘルパー。
// 接続文字列は環境変数 APPLICATIONINSIGHTS_CONNECTION_STRING から読む。
const appInsights = require('applicationinsights');

let initialized = false;
let client = null;

// App Insights を初期化する（複数回呼ばれても1度だけ実行されるようガード）。
function initTelemetry() {
  if (initialized) return client;
  initialized = true;

  const connectionString = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;
  if (!connectionString) {
    // 接続文字列が無い場合はテレメトリ無効（ローカル開発などを想定）。
    return null;
  }

  try {
    appInsights
      .setup(connectionString)
      .setAutoCollectRequests(true)
      .setAutoCollectExceptions(true)
      .setAutoCollectDependencies(true)
      .setAutoCollectPerformance(true)
      .setUseDiskRetryCaching(true)
      .start();
    client = appInsights.defaultClient;
  } catch (err) {
    // 初期化に失敗してもアプリ本体は動作させる。
    client = null;
  }
  return client;
}

function getClient() {
  if (!initialized) initTelemetry();
  return client;
}

// カスタムイベントを記録する（例: MessagePosted / MessageDeleted）。
function trackEvent(name, properties) {
  const c = getClient();
  if (c) c.trackEvent({ name, properties });
}

// 例外（DBエラーなど）をトラッキングする。
function trackException(error, properties) {
  const c = getClient();
  if (c) {
    c.trackException({
      exception: error instanceof Error ? error : new Error(String(error)),
      properties,
    });
  }
}

// ハンドラをラップして、リクエストの開始・終了・所要時間を計測する。
function withTelemetry(routeName, handler) {
  return async (request, context) => {
    initTelemetry();
    const c = getClient();
    const start = Date.now();
    const label = `${request.method} /${routeName}`;

    context.log(`[AppInsights] request start: ${label}`);
    if (c) c.trackTrace({ message: `request start: ${label}` });

    let response;
    let failed = false;
    try {
      response = await handler(request, context);
      return response;
    } catch (err) {
      failed = true;
      trackException(err, { route: routeName, method: request.method });
      throw err;
    } finally {
      const duration = Date.now() - start;
      const statusCode = (response && response.status) || (failed ? 500 : 0);

      context.log(`[AppInsights] request end: ${label} -> ${statusCode} (${duration}ms)`);
      if (c) {
        c.trackRequest({
          name: label,
          url: request.url,
          duration,
          resultCode: String(statusCode),
          success: !failed && statusCode < 400,
          properties: { route: routeName, durationMs: duration },
        });
      }
    }
  };
}

module.exports = {
  initTelemetry,
  getClient,
  trackEvent,
  trackException,
  withTelemetry,
};
