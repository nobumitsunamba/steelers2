'use strict';

const { query } = require('../shared/db');
const { jsonResponse } = require('../shared/http');
const { isAdmin } = require('../shared/auth');
const { initTelemetry } = require('../shared/telemetry');

// 関数モジュールの先頭で Application Insights を初期化する。
initTelemetry();

// PUT /api/messages/{id}
// リクエストボディ: { body }
// adminロールのみ許可。messagesテーブルの body を更新する。
// ルート登録は messageById.js に集約しているため、ここではハンドラのみを export する。
async function putMessage(request, context) {
  // 認可: adminでなければ403
  if (!isAdmin(request)) {
    return jsonResponse(403, { error: 'Forbidden: admin role required' });
  }

  const id = request.params.id;
  if (!id) {
    return jsonResponse(400, { error: 'id is required' });
  }

  let payload;
  try {
    payload = await request.json();
  } catch (err) {
    return jsonResponse(400, { error: 'Invalid JSON body' });
  }

  const { body } = payload || {};

  // バリデーション: body 必須・200文字以内
  if (typeof body !== 'string' || body.trim() === '') {
    return jsonResponse(400, { error: 'Validation failed', details: ['body is required'] });
  }
  if (body.length > 200) {
    return jsonResponse(400, {
      error: 'Validation failed',
      details: ['body must be 200 characters or fewer'],
    });
  }

  try {
    // T-SQL では RETURNING の代わりに OUTPUT 句で更新後の行を返す。
    const result = await query(
      'UPDATE messages SET body = @body ' +
        'OUTPUT INSERTED.id, INSERTED.match_id, INSERTED.name, INSERTED.body, INSERTED.created_at ' +
        'WHERE id = @id',
      { body: body.trim(), id }
    );

    if (result.recordset.length === 0) {
      return jsonResponse(404, { error: 'Message not found' });
    }

    return jsonResponse(200, result.recordset[0]);
  } catch (err) {
    context.error('putMessage failed:', err);
    return jsonResponse(500, { error: 'Failed to update message' });
  }
}

module.exports = { putMessage };
