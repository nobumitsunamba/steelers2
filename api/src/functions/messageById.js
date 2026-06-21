'use strict';

const { app } = require('@azure/functions');
const { putMessage } = require('./putMessages');
const { deleteMessage } = require('./deleteMessages');
const { preflightResponse, jsonResponse } = require('../shared/http');
const { initTelemetry, withTelemetry } = require('../shared/telemetry');

// 関数モジュールの先頭で Application Insights を初期化する。
initTelemetry();

// /api/messages/{id} のルート登録を1つに集約する。
// 同一ルートを複数の関数で登録するとメソッドによっては404になるため、
// ここでメソッドを振り分けて各ハンドラを呼び出す。
// withTelemetry でラップし、リクエストの開始・終了・所要時間を計測する。
app.http('messageById', {
  methods: ['PUT', 'DELETE', 'OPTIONS'],
  authLevel: 'anonymous',
  route: 'messages/{id}',
  handler: withTelemetry('messages/{id}', async (request, context) => {
    if (request.method === 'OPTIONS') {
      return preflightResponse();
    }
    if (request.method === 'PUT') {
      return putMessage(request, context);
    }
    if (request.method === 'DELETE') {
      return deleteMessage(request, context);
    }
    return jsonResponse(405, { error: 'Method not allowed' });
  }),
});
