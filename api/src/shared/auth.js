'use strict';

// Azure Static Web Apps は認証済みリクエストに x-ms-client-principal ヘッダー
// （base64エンコードされたJSON）を付与する。これをデコードして
// クライアントプリンシパル（ユーザー情報・ロール）を取得する。
function getClientPrincipal(request) {
  const header = request.headers.get('x-ms-client-principal');
  if (!header) return null;
  try {
    const decoded = Buffer.from(header, 'base64').toString('utf8');
    return JSON.parse(decoded);
  } catch (err) {
    return null;
  }
}

// admin ロールを持っているかどうかを判定する。
function isAdmin(request) {
  const principal = getClientPrincipal(request);
  return !!(
    principal &&
    Array.isArray(principal.userRoles) &&
    principal.userRoles.includes('admin')
  );
}

module.exports = { getClientPrincipal, isAdmin };
