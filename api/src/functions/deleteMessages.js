'use strict';

const { query } = require('../shared/db');
const { jsonResponse } = require('../shared/http');
const { isAdmin } = require('../shared/auth');
const { initTelemetry, trackEvent } = require('../shared/telemetry');

// 関数モジュールの先頭で Application Insights を初期化する。
initTelemetry();

// DELETE /api/messages/{id}
// adminロールのみ許可。messagesテーブルから該当レコードを削除する。
// ルート登録は messageById.js に集約しているため、ここではハンドラのみを export する。
async function deleteMessage(request, context) {
  // 認可: adminでなければ403
  if (!isAdmin(request)) {
    return jsonResponse(403, { error: 'Forbidden: admin role required' });
  }

  const id = request.params.id;
  if (!id) {
    return jsonResponse(400, { error: 'id is required' });
  }

  try {
    // T-SQL では RETURNING の代わりに OUTPUT 句で削除した行を返す。
    const result = await query(
      'DELETE FROM messages OUTPUT DELETED.id WHERE id = @id',
      { id }
    );

    if (result.recordset.length === 0) {
      return jsonResponse(404, { error: 'Message not found' });
    }

    // 成功時にカスタムイベントを記録する。
    trackEvent('MessageDeleted', { id: String(result.recordset[0].id) });

    return jsonResponse(200, { deleted: true, id: result.recordset[0].id });
  } catch (err) {
    context.error('deleteMessage failed:', err);
    return jsonResponse(500, { error: 'Failed to delete message' });
  }
}

module.exports = { deleteMessage };
