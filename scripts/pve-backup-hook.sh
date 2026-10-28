#!/usr/bin/env bash
#
# pve-backup-hook.sh - Proxmox VE vzdump hook script
#
# vzdump のバックアップ完了時に、アーカイブ(.vma.zst / .tar.zst 等)とログを
# rclone で Google Drive へ転送し、VMID ごとに直近 KEEP_GENERATIONS 世代を保持する。
#
# 設置: /root/scripts/pve-backup-hook.sh (chmod 755)
# 設定: /etc/vzdump.conf に  script: /root/scripts/pve-backup-hook.sh
#
# フェーズ (vzdump から $1 で渡される):
#   job-start / job-end / job-abort
#   backup-start / backup-end / backup-abort / log-end / pre-stop / pre-restart / post-restart
#
# 方針: 転送失敗は ERROR をログに残すが、常に exit 0 で返し、vzdump ジョブを道連れにしない。
#       秘密情報は持たず、rclone の設定名(リモート名)のみを使う。

set -u
set -o pipefail

# ============================================================================
# 設定 (環境変数で上書き可能)
# ============================================================================
RCLONE_BIN="${RCLONE_BIN:-rclone}"
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-gdrive}"                 # rclone.conf のリモート名
RCLONE_REMOTE="${RCLONE_REMOTE:-${RCLONE_REMOTE_NAME}:ProxmoxBackups}"  # 保存先 (末尾スラッシュなし)
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/root/.config/rclone/rclone.conf}"
KEEP_GENERATIONS="${KEEP_GENERATIONS:-7}"                          # Google Drive 上の保持世代数
LOG_FILE="${LOG_FILE:-/var/log/pve-backup-hook.log}"
STATE_FILE="${STATE_FILE:-/run/pve-backup-hook.state}"             # ジョブ内の失敗件数(フェーズ間共有)
RETRIES="${RETRIES:-3}"
RETRIES_SLEEP="${RETRIES_SLEEP:-10s}"
TPSLIMIT="${TPSLIMIT:-10}"
BWLIMIT="${BWLIMIT:-}"                                             # 例: 20M (空なら無制限)
CONN_TIMEOUT="${CONN_TIMEOUT:-60s}"                                # rclone --contimeout
IO_TIMEOUT="${IO_TIMEOUT:-5m}"                                     # rclone --timeout (無通信タイムアウト)
DRY_RUN="${DRY_RUN:-0}"                                            # 1 なら転送・削除せずログのみ

# ============================================================================
# 共通関数
# ============================================================================
PHASE="${1:-unknown}"
MODE="${2:-}"
VMID="${3:-}"
LOG_VMID="${VMID:--}"

log() {
    # 形式: [YYYY-MM-DD hh:mm:ss] [PHASE] [VMID] Message
    local msg="$*"
    printf '[%s] [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PHASE" "$LOG_VMID" "$msg" \
        >>"$LOG_FILE" 2>/dev/null || printf '%s\n' "$msg" >&2
}

log_error() { log "ERROR: $*"; }

# 失敗カウンタ (job-start で初期化、job-end で集計)
state_reset() { : >"$STATE_FILE" 2>/dev/null || true; }
state_add_failure() { printf '%s\n' "${VMID:-job}" >>"$STATE_FILE" 2>/dev/null || true; }
state_failures() {
    [[ -f "$STATE_FILE" ]] || { echo 0; return; }
    wc -l <"$STATE_FILE" | tr -d ' '
}

rclone_common_opts() {
    local -a opts=(
        --config "$RCLONE_CONFIG_FILE"
        --retries "$RETRIES"
        --retries-sleep "$RETRIES_SLEEP"
        --low-level-retries 10
        --tpslimit "$TPSLIMIT"
        --contimeout "$CONN_TIMEOUT"
        --timeout "$IO_TIMEOUT"
    )
    [[ -n "$BWLIMIT" ]] && opts+=(--bwlimit "$BWLIMIT")
    printf '%s\n' "${opts[@]}"
}

# rclone を共通オプション付きで実行する。stdout/stderr は呼び出し側で扱う。
run_rclone() {
    local -a common
    mapfile -t common < <(rclone_common_opts)
    "$RCLONE_BIN" "$1" "${common[@]}" "${@:2}"
}

# ローカルファイル 1 件を Drive へ転送する。 $1=ローカルパス $2=種別ラベル
upload_file() {
    local src="$1" label="$2" name size start end rc out
    if [[ -z "$src" || ! -f "$src" ]]; then
        log_error "${label} が見つかりません (path='${src}')。転送をスキップします。"
        state_add_failure
        return 0
    fi
    name="$(basename "$src")"
    size="$(stat -c %s "$src" 2>/dev/null || echo '?')"
    log "${label} 転送開始: ${name} (${size} bytes) -> ${RCLONE_REMOTE}/"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN: 転送をスキップしました。"
        return 0
    fi

    start=$SECONDS
    out="$(run_rclone copyto "$src" "${RCLONE_REMOTE}/${name}" --checksum 2>&1)"
    rc=$?
    end=$SECONDS
    if (( rc == 0 )); then
        log "${label} 転送成功: ${name} (${size} bytes, $((end - start)) 秒)"
    else
        log_error "${label} 転送失敗: ${name} (rc=${rc}, $((end - start)) 秒)"
        printf '%s\n' "$out" | tail -n 20 | while IFS= read -r line; do log "  rclone: ${line}"; done
        state_add_failure
    fi
    return 0
}

# ----------------------------------------------------------------------------
# 世代パージ: Drive 上のファイルを VMID ごとにまとめ、新しい KEEP_GENERATIONS 世代を残して削除する。
# 世代 = "vzdump-<qemu|lxc>-<vmid>-<YYYY_MM_DD-hh_mm_ss>" のステム。
# アーカイブ・ログ・.notes など同一ステムのファイルはまとめて削除する。
# 一覧取得に失敗した場合や、想定外の件数・名前の場合は何も削除しない。
# ----------------------------------------------------------------------------
purge_old_generations() {
    local listing rc stem_list del_list total_del=0 f

    if ! [[ "$KEEP_GENERATIONS" =~ ^[0-9]+$ ]] || (( KEEP_GENERATIONS < 1 )); then
        log_error "KEEP_GENERATIONS が不正です ('${KEEP_GENERATIONS}')。パージをスキップします。"
        return 0
    fi

    listing="$(run_rclone lsf "$RCLONE_REMOTE" --files-only --include 'vzdump-*' 2>>"$LOG_FILE")"
    rc=$?
    if (( rc != 0 )); then
        log_error "Drive 上の一覧取得に失敗しました (rc=${rc})。安全のためパージをスキップします。"
        state_add_failure
        return 0
    fi

    # 対象ファイル名のみ (vzdump-{qemu,lxc}-<vmid>-<timestamp>.<拡張子>) を処理する
    # 出力: "<vmid> <stem>" を stem 重複なしで列挙 -> vmid ごとに新しい順に並べ、KEEP 以降を削除対象とする
    stem_list="$(printf '%s\n' "$listing" \
        | sed -nE 's/^(vzdump-(qemu|lxc)-([0-9]+)-[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2})\..+$/\3 \1/p' \
        | sort -u)"

    if [[ -z "$stem_list" ]]; then
        log "パージ対象の世代がありません。"
        return 0
    fi

    del_list="$(printf '%s\n' "$stem_list" \
        | sort -k1,1n -k2,2r \
        | awk -v keep="$KEEP_GENERATIONS" '{ if ($1 != cur) { cur = $1; n = 0 } n++; if (n > keep) print $2 }')"

    if [[ -z "$del_list" ]]; then
        log "保持世代数 (${KEEP_GENERATIONS}) 以内のため削除対象はありません。"
        return 0
    fi

    while IFS= read -r stem; do
        [[ -n "$stem" ]] || continue
        # ステム + "." で始まるファイルだけを対象にする (vmid 100 が 1000 を巻き込まないよう完全一致)
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            if [[ "$DRY_RUN" == "1" ]]; then
                log "DRY_RUN: 削除予定 ${f}"
                continue
            fi
            if run_rclone deletefile "${RCLONE_REMOTE}/${f}" >>"$LOG_FILE" 2>&1; then
                log "古い世代を削除: ${f}"
                total_del=$((total_del + 1))
            else
                log_error "削除失敗: ${f}"
                state_add_failure
            fi
        done < <(printf '%s\n' "$listing" | grep -F -- "${stem}." | awk -v s="${stem}." 'index($0, s) == 1')
    done <<<"$del_list"

    log "世代パージ完了: 削除 ${total_del} ファイル (保持 ${KEEP_GENERATIONS} 世代/VMID)"
    return 0
}

# ============================================================================
# 前提チェック
# ============================================================================
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

if ! command -v "$RCLONE_BIN" >/dev/null 2>&1; then
    case "$PHASE" in
        job-start|backup-end|log-end|job-end)
            log_error "rclone が見つかりません (RCLONE_BIN='${RCLONE_BIN}')。処理をスキップします。" ;;
    esac
    exit 0
fi

# ============================================================================
# フェーズ処理
# ============================================================================
case "$PHASE" in
    job-start)
        state_reset
        log "ジョブ開始 (mode=${MODE:-?}, storage=${STOREID:-?}, host=${HOSTNAME:-?}, remote=${RCLONE_REMOTE})"
        if [[ "$DRY_RUN" != "1" ]]; then
            if ! run_rclone about "${RCLONE_REMOTE_NAME}:" >/dev/null 2>>"$LOG_FILE"; then
                log_error "Google Drive (${RCLONE_REMOTE_NAME}:) への疎通チェックに失敗しました。転送は個別に再試行されます。"
                state_add_failure
            else
                log "Google Drive への疎通チェック OK"
            fi
        fi
        ;;

    backup-start)
        log "バックアップ開始 (mode=${MODE:-?}, vmtype=${VMTYPE:-?}, hostname=${HOSTNAME:-?})"
        ;;

    backup-end)
        log "ローカルバックアップ完了 (TARFILE=${TARFILE:-}) "
        upload_file "${TARFILE:-}" "アーカイブ"
        ;;

    log-end)
        upload_file "${LOGFILE:-}" "ログ"
        ;;

    backup-abort)
        log_error "バックアップが中断されました (mode=${MODE:-?})。転送は行いません。"
        state_add_failure
        ;;

    job-end)
        purge_old_generations
        failures="$(state_failures)"
        if (( failures > 0 )); then
            log_error "ジョブ終了: 失敗 ${failures} 件あります。詳細は上記ログを確認してください。"
        else
            log "ジョブ正常終了: 失敗 0 件"
        fi
        ;;

    job-abort)
        log_error "ジョブが異常終了しました (mode=${MODE:-?})。"
        ;;

    pre-stop|pre-restart|post-restart)
        : # 何もしない
        ;;

    *)
        log "未対応のフェーズ: '${PHASE}' (無視します)"
        ;;
esac

# 転送失敗でも vzdump ジョブを妨げない
exit 0
