# Proxmox サーバーバックアップ（Google Drive連携）要件定義・基本設計書

作成: 2026-10-28 ／ 状態: 基本設計完了（レビュー待ち）

---

## 1. 要件定義

### 1.1 背景と目的
Proxmox VE 環境で稼働する仮想マシン（VM）および LXC コンテナのデータを、ハードウェア障害・災害・ランサムウェア被害等のリスクから保護するため、オフサイト（Google Drive）へ自動的に二重化バックアップし、迅速にリストアできる体制を確立する。

### 1.2 確定要件一覧 (Requirements)

| 要件 ID | 要件名 | 確定仕様 | 受け入れ基準 |
|---|---|---|---|
| **R-01** | バックアップ対象の網羅 | 全ての VM および LXC コンテナを一括バックアップ（新規作成されたVM/CTも自動対象）。モードは無停止の `snapshot`、圧縮は `zstd`。 | 全VM/LXCの整合性あるバックアップアーカイブ（`.vma.zst` / `.tar.zst`）が生成されること |
| **R-02** | 自動実行と世代管理 | 毎日深夜（午前 03:00 想定）に自動実行。ローカルは直近 1 世代のみ保持（ディスク容量圧迫防止）。Google Drive 上には直近 7 世代（約1週間分）を保持し、古い世代は自動パージ。 | スケジュール自動実行され、Google Drive 上に7世代保持、ローカルに1世代保持が維持されること |
| **R-03** | Google Drive への安全・確実な転送 | rclone を経由してローカルバックアップ完了直後にフックスクリプト経由で Google Drive へ転送。一時マウントは行わず、ファイル単位の安全な転送を実施。APIレート制限や一時的な通信断に対するリトライを備える。 | 転送がエラーなく完了し、Google Drive 上に完全なアーカイブとログがアップロードされること |
| **R-04** | リストア検証可能性 | Google Drive 上に保管されたバックアップアーカイブを取得し、Proxmox VE 上に別 VMID として新規復元・起動できること。 | テストVM/CTを別 ID で復元し、OSが正常起動すること |
| **R-05** | 運用・保守・エラー追跡 | 転送結果、所要時間、転送サイズ、エラー詳細が専用ログファイル（`/var/log/pve-backup-hook.log`）に記録されること。 | ログファイルからジョブ単位・VM単位の成否が確認できること |

### 1.3 前提条件と環境
- **Proxmox VE バージョン**: 8.x（または 7.x）
- **Google Drive プラン**: Google One 有料プラン（十分な空き容量を確保）
- **通信要件**: Proxmox ホストから Google Drive API への HTTPS (443) 外向き通信が可能であること
- **作業環境**: OAuth 認可のため、ブラウザが利用可能な作業用 PC（本端末）を使用

---

## 2. システム構成・アーキテクチャ設計

### 2.1 全体アーキテクチャ図

```text
+-------------------------------------------------------------------------+
| Proxmox VE Host                                                         |
|                                                                         |
|  [Proxmox Backup Scheduler (cron/vzdump)]                               |
|   - スケジュール: 毎日 03:00                                            |
|   - 対象: All VMs / LXC Containers                                     |
|   - モード: snapshot / 圧縮: zstd                                       |
|                                                                         |
|         | 1. バックアップ実行                                           |
|         v                                                               |
|  [Local Directory Storage] (/var/lib/vz/dump)                           |
|   - vzdump-qemu-100-*.vma.zst (ローカル保持: keep-last=1)               |
|   - vzdump-qemu-100-*.log                                               |
|                                                                         |
|         | 2. vzdump フック呼び出し (backup-end / log-end / job-end)     |
|         v                                                               |
|  [/root/scripts/pve-backup-hook.sh]                                     |
|   - 設定: /etc/vzdump.conf (script: /root/scripts/pve-backup-hook.sh)   |
|   - ログ: /var/log/pve-backup-hook.log                                  |
|                                                                         |
|         | 3. rclone copy / delete 実行 (HTTPS / OAuth 2.0)              |
+---------|---------------------------------------------------------------+
          |
          v
+-------------------------------------------------------------------------+
| Google Drive                                                            |
|  Folder: ProxmoxBackups/                                                |
|   ├── vzdump-qemu-100-2026_10_28-03_00_00.vma.zst                       |
|   ├── vzdump-qemu-100-2026_10_28-03_00_00.log                           |
|   ├── vzdump-lxc-200-2026_10_28-03_00_00.tar.zst                        |
|   └── ... (VMごとに直近 7 世代分を保持、古い世代は自動削除)              |
+-------------------------------------------------------------------------+
```

### 2.2 方式選定理由
- **FUSE マウント（rclone mount）を不採用とした理由**:
  Proxmox のストレージとして Google Drive を直接マウントすると、大容量書き込み時の I/O タイムアウト、カーネルのハング、Google Drive API の一時的な切断やレート制限（750GB/日、リクエスト頻度）によるバックアップジョブ全体のクラッシュが発生しやすい。
- **vzdump フックスクリプトを採用した理由**:
  Proxmox 標準のフック機能（`vzdump-hook`）を使用することで、各 VM/CT のローカルバックアップ完了直後（`backup-end` フェーズ）に即座に Google Drive へ転送できる。cron のように「バックアップが終わるのを推定時刻で待つ」必要がなく、無駄な待機時間や二重実行リスクがない。

---

## 3. スクリプト仕様設計 (`pve-backup-hook.sh`)

### 3.1 フックフェーズごとの動作

| フェーズ (`$1`) | 引数・環境変数 | 実行処理 |
|---|---|---|
| `job-start` | `$2`: mode | ジョブ開始ログ出力、rclone と Google Drive 間の疎通チェック（`rclone about gdrive:`） |
| `backup-start` | `$2`: mode, `$3`: vmid | VMごとの開始ログ出力 |
| `backup-end` | `$2`: mode, `$3`: vmid<br>`$TARFILE`: アーカイブパス | アーカイブファイル（`.vma.zst` 等）を `rclone copyto` で Google Drive にアップロード。<br>オプション: `--retries 3`, `--tpslimit 10`, `--bwlimit`（必要時） |
| `log-end` | `$2`: mode, `$3`: vmid<br>`$LOGFILE`: ログパス | バックアップログファイルを Google Drive にアップロード |
| `backup-abort` | `$2`: mode, `$3`: vmid | 個別バックアップ失敗時のエラーログ記録 |
| `job-end` | `$2`: mode | 全 VM 転送完了後、Google Drive 上の世代パージ処理（各 VMID ごとに直近 7 世代を残して古いアーカイブを削除）、完了サマリログ出力 |
| `job-abort` | `$2`: mode | ジョブ全体異常終了ログ記録 |

### 3.2 世代管理（ローテーション）仕様
- **ローカル側**:
  Proxmox Web UI の バックアップジョブ設定にて `Retention: Keep Last = 1` を設定。Proxmox 自身が最新1世代以外のローカルファイルを自動削除。
- **Google Drive 側**:
  `job-end` フェーズにおいて、Google Drive 上の各 VMID についてファイル一覧を取得し、作成日時順でソートして 7 世代を超える古いアーカイブおよび対応するログファイルを `rclone delete` で削除。
  （または `rclone delete --min-age 8d "gdrive:ProxmoxBackups"` を組み合わせた確実なクリーンアップ）

### 3.3 エラーハンドリングとリトライ
1. **一時的なネットワーク切断・APIエラー**:
   - `rclone` の標準リトライ機能（`--retries 3 --retries-sleep 10s`）を活用。
2. **転送失敗時の挙動**:
   - 転送失敗時もフックスクリプトは exit 0（または適切な警告）で返し、Proxmox 本体の次 VM バックアップを妨げないようにする（ログには明確な ERROR を残す）。
3. **ログ形式**:
   - `/var/log/pve-backup-hook.log` に `[YYYY-MM-DD hh:mm:ss] [PHASE] [VMID] Message` の統一フォーマットで追記出力。

---

## 4. リストア（障害復旧）設計

### 4.1 リストア方式

#### パターン A: 通常復旧（直近世代からの復元）
- ローカルストレージ（`/var/lib/vz/dump`）に最新世代が残っている場合。
- Proxmox Web UI の「ストレージ (local) -> バックアップ」から対象を選択し、「リストア」をクリック。

#### パターン B: 過去世代または別環境からの復旧（Google Drive からの復旧）
1. **アーカイブ一覧の確認**:
   ```bash
   rclone lsf "gdrive:ProxmoxBackups/"
   ```
2. **目的のアーカイブを Proxmox ローカルにダウンロード**:
   ```bash
   rclone copy "gdrive:ProxmoxBackups/vzdump-qemu-100-2026_10_28-03_00_00.vma.zst" /var/lib/vz/dump/
   ```
3. **Proxmox CLI または Web UI で復元**:
   - QEMU VM の場合:
     ```bash
     qmrestore /var/lib/vz/dump/vzdump-qemu-100-2026_10_28-03_00_00.vma.zst <新しいVMID> --storage local-lvm
     ```
   - LXC コンテナの場合:
     ```bash
     pct restore <新しいCTID> /var/lib/vz/dump/vzdump-lxc-200-2026_10_28-03_00_00.tar.zst --storage local-lvm
     ```

### 4.2 テストリストア検証計画
- プロジェクトスプリント2にて、本番VMに影響を与えないよう「新規のテストVM（例: VMID 900番台）」を作成し、バックアップ取得 → Google Drive アップロード → 別 VMID（例: 901）としてリストア → 正常起動確認、の一連フローを実証する。

---

## 5. セキュリティと認証設計
- **認証情報（OAuth Token）の保護**:
  - `rclone.conf` は Proxmox ホストの `/root/.config/rclone/rclone.conf`（パーミッション `0600`）に厳重保管。
  - Git リポジトリへのコミットは `.gitignore` により完全ブロック。
- **アクセス権限の最小化**:
  - Google Drive 側の保存先フォルダ（`ProxmoxBackups`）に限定した運用。
