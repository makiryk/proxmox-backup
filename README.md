# proxmox-backup

Proxmox VE の仮想マシン（VM）・コンテナ（LXC）バックアップを自動取得し、Google Drive へオフサイト保管・世代管理・リストア検証を行うプロジェクト。

## ディレクトリ構成
```text
proxmox-backup/
├── .gitignore           # 一時ファイル・認証情報除外ルール
├── README.md            # 本書
├── plan.md              # プロジェクト憲章（目的・範囲・方針）
├── team.md              # 体制と役割・レビューフロー
├── board.md             # WBS・バックログ・スプリント盤面
├── overview.md          # 技術調査と叩き台
├── log.md               # 決定・レビュー・履歴ログ
├── docs/                # 設計書・手順書・報告書
│   ├── design.md        # 要件定義・基本設計書（予定）
│   ├── manual.md        # 導入・リストア運用手順書（予定）
│   └── test-report.md   # 動作検証結果報告書（予定）
└── scripts/             # Proxmox 用スクリプト
    └── pve-backup-hook.sh # vzdump 連携 / バックアップ同期スクリプト（予定）
```

## プロジェクト管理情報
- **方式**: ハイブリッド（前半ウォーターフォール ＋ 後半スクラム）
- **プロファイル**: 標準（主要役割を分担、独立レビュー ＋ 節目に相互レビュー）
- **管理ドキュメント**:
  - [plan.md](plan.md): プロジェクト憲章
  - [board.md](board.md): 進行状況・WBS・スプリント
  - [team.md](team.md): 体制とレビュー体制
  - [overview.md](overview.md): 方式調査と選定理由
  - [log.md](log.md): 決定と作業の履歴
