'use strict';

const { query } = require('../shared/db');
const { jsonResponse } = require('../shared/http');
const { initTelemetry, trackEvent } = require('../shared/telemetry');

// 関数モジュールの先頭で Application Insights を初期化する。
initTelemetry();

// POST /api/messages
// ボディ: { match_id, name, body }
// バリデーション: 全フィールド必須、body は200文字以内。
// ルート登録は messages.js に集約しているため、ここではハンドラのみを export する。
async function postMessages(request, context) {
  let payload;
  try {
    payload = await request.json();
  } catch (err) {
    return jsonResponse(400, { error: 'Invalid JSON body' });
  }

  const { match_id, name, body } = payload || {};

  // --- バリデーション ---
  const errors = [];
  if (match_id === undefined || match_id === null || `${match_id}`.trim() === '') {
    errors.push('match_id is required');
  }
  if (typeof name !== 'string' || name.trim() === '') {
    errors.push('name is required');
  }
  if (typeof body !== 'string' || body.trim() === '') {
    errors.push('body is required');
  } else if (body.length > 200) {
    errors.push('body must be 200 characters or fewer');
  }

  if (errors.length > 0) {
    return jsonResponse(400, { error: 'Validation failed', details: errors });
  }

  // --- INSERT ---
  // T-SQL では RETURNING の代わりに OUTPUT 句で挿入行を返す。
  try {
    const result = await query(
      'INSERT INTO messages (match_id, name, body) ' +
        'OUTPUT INSERTED.id, INSERTED.match_id, INSERTED.name, INSERTED.body, INSERTED.created_at ' +
        'VALUES (@match_id, @name, @body)',
      { match_id: `${match_id}`, name: name.trim(), body: body.trim() }
    );

    const row = result.recordset[0];

    // 成功時にカスタムイベントを記録する。
    trackEvent('MessagePosted', {
      id: String(row.id),
      match_id: String(row.match_id),
    });

    return jsonResponse(201, row);
  } catch (err) {
    context.error('postMessages failed:', err);
    return jsonResponse(500, { error: 'Failed to create message' });
  }
}

module.exports = { postMessages };
