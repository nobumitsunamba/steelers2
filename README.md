# コベルコ神戸スティーラーズ 非公式ファンサイト

NTTジャパンラグビー リーグワン **2025-26シーズン**のコベルコ神戸スティーラーズの
試合結果を表示する、シンプルな静的Webアプリです。

## ファイル構成

| ファイル | 役割 |
| --- | --- |
| `index.html` | ページ構造 |
| `style.css` | スタイル（赤と黒のチームカラー、レスポンシブ対応） |
| `script.js` | 試合データの定義と動的描画・絞り込み機能 |
| `staticwebapp.config.json` | Azure Static Web Apps 用の設定 |
| `api/` | 応援メッセージ用 API（Azure Functions / Node.js） |
| `infra/main.bicep` | Azure リソース定義（Azure SQL Serverless + Function App） |

## 機能

- ヒーローセクションにシーズン成績サマリーを表示
- リーグ戦・プレーオフの試合結果をカード形式で表示
- 勝利／敗戦での絞り込みフィルター
- 優勝（決勝）試合のハイライト表示

## 試合データの更新

`script.js` 内の `leagueMatches` / `playoffMatches` 配列を編集するだけで更新できます。

## ローカルで確認

```bash
# 任意の静的サーバーで配信（例）
python3 -m http.server 8000
# → http://localhost:8000 を開く
```

## 応援メッセージ API（バックエンド）

`api/` 配下に、試合ごとのファンの応援メッセージを保存・取得する Azure Functions API
（Node.js）があります。データストアは **Azure SQL Database（Serverless）** で、
DB アクセスは `mssql` パッケージ + **SQL 認証**を使用します。
接続情報は環境変数（`SQL_SERVER` / `SQL_DATABASE` / `SQL_USER` / `SQL_PASSWORD`）から読み込みます。

| エンドポイント | メソッド | 説明 |
| --- | --- | --- |
| `/api/messages` | GET | メッセージ一覧（`?match_id=` で絞り込み可） |
| `/api/messages` | POST | メッセージ投稿 |
| `/api/messages/{id}` | PUT | メッセージ更新（admin ロール） |
| `/api/messages/{id}` | DELETE | メッセージ削除（admin ロール） |

### 認証方式

DB アクセスは **SQL 認証**（ユーザー名／パスワード）を使用し、接続情報は環境変数から読み込みます。

| 環境変数 | 説明 |
| --- | --- |
| `SQL_SERVER` | 例: `<your-server>.database.windows.net` |
| `SQL_DATABASE` | データベース名 |
| `SQL_USER` | SQL 認証ユーザー |
| `SQL_PASSWORD` | SQL 認証パスワード |

接続プールはモジュール内でシングルトン保持し、Functions 呼び出しごとに新規接続しません。
Serverless DB の Auto-pause 復帰待ち（`40613` / `is not currently available`）の場合のみ、
プールを破棄して **1 回だけ自動リトライ**します。

### ローカル開発

```bash
# 1) 接続情報を設定（api/local.settings.json の Values）
#    "SQL_SERVER":   "<your-server>.database.windows.net"
#    "SQL_DATABASE": "<your-database>"
#    "SQL_USER":     "<sql-user>"
#    "SQL_PASSWORD": "<sql-password>"   # コミットしないこと（.gitignore 済み想定）

# 2) 依存関係をインストールして起動
cd api
npm install
npm start   # func start
```

> メモ: Serverless DB が Auto-pause 中（最終アクセスから60分後に一時停止）の場合、
> 最初のリクエストは復帰待ちで時間がかかります。API 側に 1 回の自動リトライを実装済みです。

### インフラのデプロイ

SQL 管理者パスワードは Bicep に平文で書かず、`@secure()` パラメータとしてデプロイ時に渡します。

```bash
# パスワードはプロンプトで安全に入力（履歴に残さない）
az deployment group create \
  --resource-group <RESOURCE_GROUP> \
  --template-file infra/main.bicep \
  --parameters sqlAdminLogin=<admin-login> \
  --parameters sqlAdminPassword="$SQL_ADMIN_PASSWORD"
```

> GitHub Actions からデプロイする場合は、`sqlAdminPassword` を **Actions Secrets**
> （例: `secrets.SQL_ADMIN_PASSWORD`）から `--parameters` で渡してください。

## 注意

本サイトはファンによる**非公式**サイトです。試合データは公開情報をもとに作成しています。
最新かつ正確な情報は[公式サイト](https://www.kobesteelers.com/)でご確認ください。
