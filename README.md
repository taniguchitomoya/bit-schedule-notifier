# BIT 競売スケジュール通知システム (bitschedule)

このリポジトリは、不動産競売物件情報サイト (BIT) から裁判所ごとの閲覧開始スケジュールを抽出し、その日の閲覧開始情報を Discord に自動通知する AWS Lambda 関数のプログラムおよびデプロイスクリプトを管理します。

## 機能概要

1. **スケジュール抽出 (`extract_schedule.py`)**:
   - [BIT (不動産競売物件情報サイト)](https://www.bit.courts.go.jp/) から全国の地裁・支部の競売スケジュール（期間入札・特別売却）の「閲覧開始日」をスクレイピングして抽出し、[schedule_dates.csv](file:///home/tomoya/bitschedule/schedule_dates.csv) に保存します。
   - 重複アクセスを防ぐためのキャッシュ機能（`download/` ディレクトリに HTML を保存）を搭載しています。
2. **Discord通知機能 (`lambda_function.py`)**:
   - `schedule_dates.csv` に基づいて、本日の日付が閲覧開始日に該当する裁判所・支部があるかをチェックし、該当する場合は Discord Webhook へ投稿します。
   - 「農地」区分の除外や、「通常」区分を「期間入札」に変換する処理を行います。
3. **AWSデプロイ自動化 (`deploy.sh`)**:
   - AWS Lambda 関数の作成・更新、IAMロールの設定、EventBridgeによるスケジュール実行（平日 9:10 JST / 0:10 UTC 実行）の設定を自動で行います。

## ディレクトリ構成

```text
.
├── .gitignore               # Git管理対象外設定 (本プロジェクト向けに整理済み)
├── README.md                # 本ドキュメント
├── requirements.txt         # 依存ライブラリ
├── extract_schedule.py      # スケジュール抽出スクリプト
├── lambda_function.py       # AWS Lambda 用通知スクリプト
├── deploy.sh                # AWSデプロイスクリプト
├── schedule_dates.csv       # 抽出されたスケジュールデータ (Lambdaに同梱、Git管理対象)
├── download/                # キャッシュ用HTML保存ディレクトリ (Git対象外)
├── initial_prompt/          # 開発時要件メモ
└── .github/
    └── workflows/
        └── lint.yml         # GitHub Actions 用 CI ワークフロー (構文チェック)
```

## セットアップ手順

### 1. 動作要件 (Prerequisites)
- **Python 3.11** (Lambda ランタイムに準拠)
- **AWS CLI** (`aws` コマンドが設定済みで、対象アカウントへのデプロイ権限があること)
- **Discord Webhook URL**

### 2. ローカル環境の準備
```bash
# 仮想環境の作成と有効化
python3 -m venv .venv
source .venv/bin/activate

# 依存パッケージのインストール
pip install -r requirements.txt
```

### 3. スケジュールの抽出・更新
```bash
python extract_schedule.py
```
実行すると、`download/` 内に裁判所ごとの HTML キャッシュが保存され、最終的に `schedule_dates.csv` が生成/更新されます。
※ `schedule_dates.csv` はGit管理対象となっているため、スクリプト実行により更新された場合はコミットして管理してください。

### 4. AWS Lambda へのデプロイ
`deploy.sh` に Discord Webhook URL を渡して実行します。
```bash
./deploy.sh <YOUR_DISCORD_WEBHOOK_URL>
```
*※ 初回実行時は IAM ロールの作成も自動的に試行されます。*

### 5. 動作テスト
デプロイ後、以下のコマンドで Lambda 関数を即時テスト実行できます。
```bash
aws lambda invoke --function-name bitschedule-notifier --payload '{}' response.json && cat response.json && rm response.json
```
正常に実行されると、指定した Discord チャンネルに本日の競売閲覧開始日一覧が投稿されます。

## 運用上の注意・制限事項

1. **EventBridge トリガーの有効期限について（将来の自動実行停止）**:
   `deploy.sh` で自動作成される EventBridge ルールの cron スケジュールは、デプロイ時点の2年間（当年度〜翌年度）に制限されています（例: 2026年実行時は `2026-2027`）。
   期限が切れると Lambda の自動実行が停止するため、永続化する場合は AWS コンソール等から EventBridge スケジュールの年フィールドを `*`（例: `cron(10 0 ? * MON-FRI *)`）に変更するか、定期的にデプロイし直してください。

2. **将来の元号変更（改元）時の対応について**:
   競売データのスケジュールパース（`extract_schedule.py`）および当日日付の和暦判定（`lambda_function.py`）は、令和（`R` / `2018 + Y`）に固定されています。
   将来的に新たな元号に改元された際は、それぞれの元号変換ロジックを手動で修正・アップデートする必要があります。

