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
DB アクセスは `mssql` パッケージ + **Microsoft Entra ID（Azure AD）認証**を使用します。
SQL 認証は無効化されており、接続文字列にパスワードは含めません。

| エンドポイント | メソッド | 説明 |
| --- | --- | --- |
| `/api/messages` | GET | メッセージ一覧（`?match_id=` で絞り込み可） |
| `/api/messages` | POST | メッセージ投稿 |
| `/api/messages/{id}` | PUT | メッセージ更新（admin ロール） |
| `/api/messages/{id}` | DELETE | メッセージ削除（admin ロール） |

### 認証方式

- **本番（Function App）**: System-assigned Managed Identity で SQL に接続します。
  Managed Identity は `infra/main.bicep` の `deploymentScripts` により
  `CREATE USER ... FROM EXTERNAL PROVIDER` で DB ユーザー登録され、
  `db_datareader` / `db_datawriter` ロールが付与されます。
- **ローカル開発**: `az login` で取得した開発者資格情報を使います
  （`azure-active-directory-default` が `DefaultAzureCredential` 経由で自動解決）。

### ローカル開発（az login が必要）

DB アクセスは Entra ID 認証のため、ローカル実行前に **必ず `az login`** が必要です。

```bash
# 1) Azure にログイン（DefaultAzureCredential がこの資格情報を利用する）
az login
# 複数テナント/サブスクリプションがある場合は対象を選択
az account set --subscription "<SUBSCRIPTION_ID>"

# 2) 自分の Entra ユーザーを SQL の DB ユーザーとして登録しておく
#    （SQL サーバーの Entra 管理者として、対象 DB で一度だけ実行）
#    CREATE USER [you@example.com] FROM EXTERNAL PROVIDER;
#    ALTER ROLE db_datareader ADD MEMBER [you@example.com];
#    ALTER ROLE db_datawriter ADD MEMBER [you@example.com];

# 3) 接続先を設定（api/local.settings.json の Values）
#    "SQL_SERVER":   "<your-server>.database.windows.net"
#    "SQL_DATABASE": "<your-database>"

# 4) 依存関係をインストールして起動
cd api
npm install
npm start   # func start
```

> メモ: Serverless DB が Auto-pause 中（最終アクセスから60分後に一時停止）の場合、
> 最初のリクエストは復帰待ちで時間がかかります。API 側にリトライを実装済みのため、
> 数十秒待てば自動的に応答します。

### インフラのデプロイ

```bash
az deployment group create \
  --resource-group <RESOURCE_GROUP> \
  --template-file infra/main.bicep
```

## 注意

本サイトはファンによる**非公式**サイトです。試合データは公開情報をもとに作成しています。
最新かつ正確な情報は[公式サイト](https://www.kobesteelers.com/)でご確認ください。
