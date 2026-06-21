'use strict';

// 全レスポンスに付与するCORSヘッダー。
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

// JSONレスポンスを生成するヘルパー。CORSヘッダーを必ず付与する。
function jsonResponse(status, body) {
  return {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders,
    },
    jsonBody: body,
  };
}

// CORSプリフライト(OPTIONS)用のレスポンス。
function preflightResponse() {
  return {
    status: 204,
    headers: corsHeaders,
  };
}

module.exports = { corsHeaders, jsonResponse, preflightResponse };
