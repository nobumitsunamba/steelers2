# Azure 構築手順書（Static Web Apps + Functions + SQL Serverless）

**対象システム**: コベルコ神戸スティーラーズ ファンサイト
**構成**: Azure Static Web Apps (Free) + Managed Functions + Azure SQL Database Serverless
**ソース管理 / CI-CD**: GitHub + GitHub Actions
**認証方式（DB接続）**: SQL 認証（環境変数経由）
**作成日**: 2026年6月

> 本書は **Azure 側の設定作業のみ** を記録したものです。アプリケーションのコード実装内容は対象外とし、
> 「どの画面・どのメニューで、何を設定したか」に絞って記載しています。
> 最終的に必要だった設定のみを残し、試行錯誤・手戻りした内容は省いています。

---

## 全体の流れ

| # | 作業 | 主な操作場所 |
|---|---|---|
| 1 | Static Web App リソースの作成（GitHub 連携） | Azure Portal / Static Web Apps |
| 2 | Azure SQL Server + Serverless データベースの作成 | Azure Portal / SQL databases |
| 3 | SQL Server の認証方式を混在モードに変更 | Azure Portal / SQL Server → Microsoft Entra ID |
| 4 | アプリ専用 SQL ユーザーの作成 | Azure Portal / クエリ エディター |
| 5 | SWA の環境変数（アプリ設定）登録 | Azure Portal / Static Web App → 環境変数 |
| 6 | admin ロールの付与（管理者ユーザー招待） | Azure Portal / Static Web App → ロールの管理 |
| 7 | GitHub Secrets（デプロイトークン）の設定 | GitHub / Settings → Secrets |
| 8 | テーブルの作成 | Azure Portal / クエリ エディター |
| 9 | 監視（Application Insights）の確認 | Azure Portal / Static Web App → Application Insights |

> **アーキテクチャ補足**: SWA の Free プランでは API は SWA に統合された **Managed Functions** として動作します。
> 別途 Function App リソースを作る必要はなく、リポジトリの `api/` フォルダが SWA デプロイ時に自動的に Functions として配置されます。

---

## 1. Static Web App リソースの作成（GitHub 連携）

最初に Web アプリの入れ物となる Static Web App を作成し、GitHub リポジトリと連携させる。
この作成操作により、GitHub 側にデプロイ用ワークフローと Secret が **自動生成** される。

### 操作画面
Azure Portal 上部の検索バーで「Static Web Apps」を検索 →「+ 作成」

### 基本タブ

| 項目 | 設定値 |
|---|---|
| サブスクリプション | 利用中のサブスクリプション |
| リソースグループ | `my-swa-app`（無ければ「新規作成」） |
| 名前 | `steelers` |
| プランの種類 | **Free（個人用または趣味のプロジェクト向け）** |
| Azure Functions などの詳細のリージョン | Japan East（East Asia 等の近隣でも可） |

### デプロイの詳細（同じ基本タブ内）

| 項目 | 設定値 |
|---|---|
| ソース | **GitHub** |
| GitHub アカウント | 「GitHub でサインイン」して認可 |
| 組織 | 対象の GitHub Organization / ユーザー |
| リポジトリ | `steelers2` |
| 分岐（ブランチ） | `main` |

### ビルドの詳細（同じ基本タブ内）

| 項目 | 設定値 |
|---|---|
| ビルドのプリセット | **Custom** |
| アプリの場所（App location） | `/` |
| API の場所（Api location） | `api` ← Managed Functions のソース |
| 出力先（Output location） | （空欄） |

「確認および作成」→「作成」。

> **自動生成される成果物**:
> - リポジトリに `.github/workflows/azure-static-web-apps-<ランダム名>.yml` がコミットされる
> - GitHub の Secrets に `AZURE_STATIC_WEB_APPS_API_TOKEN_<ランダム名>` が自動登録される
> - 初回デプロイの GitHub Actions が自動で起動する

> **注意**: ワークフローファイル内の `app_location` / `api_location` は後から変更可能だが、
> 変更した場合はコミットして再デプロイが必要。本構成では `app_location: "/"`、`api_location: "api"`。

---

## 2. Azure SQL Server + Serverless データベースの作成

### 操作画面
Azure Portal 上部の検索バーで「SQL databases」を検索 →「+ 作成」

### 基本タブ

| 項目 | 設定値 |
|---|---|
| リソースグループ | `my-swa-app`（SWA と同じグループにまとめる） |
| データベース名 | `steelers2-db` |
| サーバー | 「新規作成」をクリック |

### サーバー作成サブ画面（「新規作成」内）

| 項目 | 設定値 |
|---|---|
| サーバー名 | `steelers2-sql-server` |
| 場所 | Japan East |
| 認証方式 | 「Microsoft Entra のみを使用した認証を設定する」を選択 |
| Microsoft Entra 管理者 | 「管理者を設定」→ 自分のアカウントを検索して選択 |

> **注意**: サーバー名はグローバルで一意。重複エラーが出た場合は `-jpe` 等のサフィックスを追加する。

### データベースの構成（「データベースの構成」ボタンをクリック）

| 項目 | 設定値 |
|---|---|
| サービスレベル | **General Purpose — Serverless** |
| Free database offer | Applied（オン）のまま |
| 無料枠到達時の挙動 | 「Auto-pause the database until next month」を選択 |
| 最大仮想コア数 | 2 |
| 最小仮想コア数 | 0.5 |
| 自動一時停止（Auto-pause delay） | 60 分（既定） |

> **重要**: 「Continue using database for additional charges」に切り替えると Auto-pause に戻せないため、
> 必ず「Auto-pause the database until next month」のままにする。

「適用」をクリック。

### バックアップタブ

| 項目 | 設定値 |
|---|---|
| バックアップストレージの冗長性 | ローカル冗長（コスト削減のため） |

### ネットワークタブ

| 項目 | 設定値 |
|---|---|
| 接続方法 | パブリックエンドポイント |
| Azure サービスおよびリソースにこのサーバーへのアクセスを許可 | **はい** ← Managed Functions からのアクセスに必須 |
| 現在のクライアント IP アドレスを追加 | はい（Query Editor 操作用） |

> 「Azure サービスへのアクセスを許可」は、ファイアウォール規則 `0.0.0.0 - 0.0.0.0`（AllowAllAzureIps）に相当する。
> SWA Managed Functions は Azure サービス枠から接続するため、この許可が無いと DB 接続できない。

### セキュリティタブ
何も変更せずそのまま次へ進む。

### 追加設定タブ

| 項目 | 設定値 |
|---|---|
| データソース | なし（空の DB として作成） |
| 照合順序 | `SQL_Latin1_General_CP1_CI_AS`（既定） |

「確認および作成」→「作成」。デプロイ完了まで数分待つ。

---

## 3. SQL Server の認証方式を混在モードに変更

SWA の Free プランでは Managed Identity を DB 接続に使えないため、SQL 認証も使えるように変更する。

### 操作画面
`steelers2-sql-server`（**データベースではなく SQL Server リソース**）→ 左メニュー「Microsoft Entra ID」

> **注意**: `steelers2-db`（データベースリソース）には「Microsoft Entra ID」メニューはない。
> データベースの「概要」画面のタイトル括弧内のサーバー名をクリックして SQL Server リソースへ移動する。

### 設定内容
「**Microsoft Entra のみの認証をサポートする**」のチェックを **オフ** にする →「保存」

これで Entra ID 管理者（管理用）と SQL 認証（アプリ接続用）の両方が使えるようになる。

---

## 4. アプリ専用 SQL ユーザーの作成

サーバー管理者アカウントをアプリに直接使わず、最小権限のユーザーを作成する。

### パスワードの生成
Azure Cloud Shell で以下を実行し、出力された文字列をパスワードとして使用する。

```bash
openssl rand -base64 24
```

### 操作画面
`steelers2-db` → 左メニュー「クエリ エディター (プレビュー)」→「Microsoft Entra 認証」でサインイン

> **Serverless の初回接続エラーについて**: 「is not currently available」エラーが出た場合は Auto-pause からの復帰中。
> 「〇〇 として接続する」ボタンをクリック → 1 分待つ → ページ更新 → 再度サインイン、で解消する。

### 実行する SQL

```sql
CREATE USER steelers_app_user WITH PASSWORD = '<生成したパスワード>';
ALTER ROLE db_datareader ADD MEMBER steelers_app_user;
ALTER ROLE db_datawriter ADD MEMBER steelers_app_user;
```

「クエリが正常に実行されました」と表示されれば完了。

---

## 5. SWA の環境変数（アプリ設定）登録

Managed Functions はここで登録した環境変数を読み取り、SQL 認証で DB に接続する。

### 操作画面
`steelers`（Static Web App リソース）→ 左メニュー「環境変数」→「運用（Production）」タブ

「+ 追加」で以下の 4 つを登録し「適用」をクリック。

| 名前 | 値 |
|---|---|
| `SQL_SERVER` | `steelers2-sql-server.database.windows.net` |
| `SQL_DATABASE` | `steelers2-db` |
| `SQL_USER` | `steelers_app_user` |
| `SQL_PASSWORD` | 手順 4 で生成したパスワード |

> パスワードは環境変数に保存されていれば十分。手元のメモからは削除してよい。
> ローカル開発時のみ `api/local.settings.json`（`.gitignore` 対象、コミット禁止）に同じ値を設定する。

---

## 6. admin ロールの付与（管理者ユーザーの招待）

メッセージの編集・削除など管理者専用 API（`/api/messages/*` の PUT / DELETE）は、
SWA のロール `admin` を持つユーザーのみに許可している（`staticwebapp.config.json` の `allowedRoles` で制御）。
この `admin` ロールは Azure Portal から個別ユーザーへ招待して付与する。

### 操作画面
`steelers`（Static Web App リソース）→ 左メニュー「ロールの管理（Role management）」→「招待（Invite）」

### 設定内容

| 項目 | 設定値 |
|---|---|
| 承認プロバイダー | GitHub（利用しているログインプロバイダーに合わせる） |
| 招待先の詳細 | 対象ユーザーのユーザー名 |
| ドメイン | 自動入力される SWA の既定ドメイン（例 `red-coast-...azurestaticapps.net`） |
| ロール | `admin` |
| 有効期限 | 適宜（最大 168 時間 / 7 日） |

「生成（Generate）」で招待リンクが作られるので、対象ユーザーに共有する。
ユーザーがリンクを開いてサインインすると、そのユーザーに `admin` ロールが紐づく。

> 既定では全ユーザーが匿名（`anonymous`）+ 認証済み（`authenticated`）ロールを持つ。
> `admin` のような追加ロールはこの招待操作でのみ付与される。

---

## 7. GitHub Secrets（デプロイトークン）の設定

手順 1 の SWA 作成時に Secret は自動登録されるが、**ワークフローを手動で作り直した／トークンを再生成した**
場合は、`deployment_token was not provided` エラーで GitHub Actions が失敗する。その際は以下で再設定する。

### Secret 名の確認
リポジトリの `.github/workflows/azure-static-web-apps-*.yml` を開き、以下の `secrets.` 以降の名前を確認する。

```yaml
azure_static_web_apps_api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN_RED_COAST_040212C10 }}
```

### デプロイトークンの取得
Azure Portal → `steelers`（SWA リソース）→「概要」画面上部「**デプロイ トークンの管理**」→ トークンをコピー

### GitHub への登録
GitHub リポジトリ → Settings → Secrets and variables → Actions →「**New repository secret**」

| 項目 | 値 |
|---|---|
| Name | ワークフローで確認した名前（例 `AZURE_STATIC_WEB_APPS_API_TOKEN_RED_COAST_040212C10`） |
| Secret | Azure からコピーしたデプロイトークン |

「Add secret」をクリック。以後 `main` への push で GitHub Actions が緑のチェックになることを確認する。

---

## 8. テーブルの作成

デプロイ成功後、DB にテーブルが存在しない場合は Query Editor から作成する（Azure 上の DB 操作）。

### 操作画面
`steelers2-db` → 左メニュー「クエリ エディター (プレビュー)」→「Microsoft Entra 認証」でサインイン

### テーブル存在確認

```sql
SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE';
```

### テーブル作成例

```sql
CREATE TABLE dbo.messages (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    match_id    NVARCHAR(100),
    name        NVARCHAR(200),
    body        NVARCHAR(MAX),
    created_at  DATETIME2 DEFAULT SYSUTCDATETIME()
);
```

> リポジトリに `api/schema.sql` を用意しておけば、後述の IaC ワークフロー（付録）で自動適用も可能。

### データ確認

```sql
SELECT * FROM dbo.messages;
SELECT COUNT(*) AS row_count FROM dbo.messages;
```

---

## 9. 監視（Application Insights）の確認

Managed Functions のログ・例外は Application Insights に送られる。SWA 作成時に併せて有効化される場合が多いが、
有効になっているかを確認する。

### 操作画面
`steelers`（Static Web App リソース）→ 左メニュー「Application Insights」

- 無効の場合は「有効にする」→ 新規または既存の Application Insights リソースを割り当てる。
- 有効化すると Functions の `context.log` 出力や例外（例: Serverless 復帰中の `40613`）を
  「ログ」「失敗」ブレードから追跡できる。

---

## 補足: コスト構造

| リソース | 費用 |
|---|---|
| Static Web Apps（Free プラン） | 無料 |
| Azure SQL Serverless | 月 100,000 vCore 秒・32GB ストレージまで無料。無料枠到達後は Auto-pause（月末まで停止、追加課金なし） |
| Application Insights | 月 5GB まで無料枠あり |
| GitHub Actions | パブリック / 無料枠内で無料 |

> **注意**: Free database offer は SLA 対象外。社内ファンサイト用途では実用上問題ないが、
> 将来的に常時稼働保証が必要な場合は「Continue using database for additional charges」への
> 切り替えを検討する（逆方向への切り替えは不可）。

---

## 付録: IaC（Bicep）による自動構築（任意）

手順 2〜8 のうち SQL Server / データベース / ファイアウォール / SWA アプリ設定 / スキーマ適用は、
リポジトリの `infra/main.bicep` と `.github/workflows/deploy-infra.yml` で自動化できる。
ポータルでの手作業を再現性のある形で残したい場合に利用する。

### 必要な GitHub 設定

`.github/workflows/deploy-infra.yml` を実行するには、GitHub 側に以下を登録する。

**Settings → Secrets and variables → Actions → Secrets**

| Secret 名 | 値 |
|---|---|
| `AZURE_CREDENTIALS` | `az ad sp create-for-rbac --sdk-auth` の出力 JSON（サービスプリンシパル） |
| `SQL_ADMIN_PASSWORD` | SQL Server 管理者パスワード（`@secure()` パラメータに渡る） |

**Settings → Secrets and variables → Actions → Variables**

| Variable 名 | 値 |
|---|---|
| `AZURE_RESOURCE_GROUP` | デプロイ先リソースグループ名（例 `my-swa-app`） |
| `SQL_ADMIN_LOGIN` | SQL 管理者ログイン名（任意。未設定なら `steelersadmin`） |
| `AZURE_STATIC_WEBAPP_NAME` | （任意）SWA 名を明示する場合。未設定ならグループ内から自動検出 |
| `AZURE_STATIC_WEBAPP_RG` | （任意）SWA が別リソースグループの場合 |

### サービスプリンシパルの作成例

```bash
az ad sp create-for-rbac \
  --name "steelers-deployer" \
  --role contributor \
  --scopes /subscriptions/<サブスクリプションID>/resourceGroups/my-swa-app \
  --sdk-auth
```

出力 JSON をそのまま `AZURE_CREDENTIALS` に登録する。

### ワークフローの実行
GitHub → Actions →「Deploy Infra (Bicep)」→「Run workflow」（または `infra/**`・`api/schema.sql` の変更を `main` に push）。

このワークフローは次を自動実行する。

1. `infra/main.bicep` をデプロイ（SQL Server / Serverless DB / ファイアウォール 等）
2. GitHub ランナーの送信元 IP を **一時的に** SQL ファイアウォールへ追加し、`api/schema.sql` を適用（完了後に規則を削除）
3. `az staticwebapp appsettings set` で SWA に `SQL_SERVER` / `SQL_DATABASE` / `SQL_USER` / `SQL_PASSWORD` を投入

> Serverless の Auto-pause 復帰待ちに備え、スキーマ適用は最大 6 回・20 秒間隔でリトライする設計。

> **手動構築（手順 2〜8）と IaC のどちらか一方で十分**。両方を混在させると設定が二重管理になるため、
> 運用方針に合わせていずれかに統一すること。
