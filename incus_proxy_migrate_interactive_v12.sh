#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/root/incus-proxy-migrate-backups}"
mkdir -p "$BACKUP_ROOT"
CURRENT_INSTANCE=""
LAST_RUN_DIR=""

pause(){ read -r -p "按回车继续..." _; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1"; exit 1; }
}
need_cmd incus
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd bash

trim_quotes() {
  local v="$1"
  v="${v%\"}"
  v="${v#\"}"
  printf '%s' "$v"
}

get_instances() {
  incus list -c n --format csv
}

instance_exists() {
  incus info "$1" >/dev/null 2>&1
}

get_static_ipv4() {
  local inst="$1"
  incus config show "$inst" --expanded | awk '
    BEGIN { in_devices=0; type=""; ipv4="" }
    /^devices:/ { in_devices=1; next }
    in_devices && /^[^[:space:]]/ {
      if (type=="nic" && ipv4!="") { print ipv4; exit }
      exit
    }
    in_devices && /^  [^[:space:]].*:/ {
      if (type=="nic" && ipv4!="") { print ipv4; exit }
      type=""; ipv4=""
      next
    }
    in_devices && /^    type:/ { type=$2; next }
    in_devices && /^    ipv4.address:/ { ipv4=$2; next }
    END {
      if (type=="nic" && ipv4!="") print ipv4
    }
  ' | head -n1
}

parse_proxy_devices() {
  local inst="$1"
  incus config show "$inst" --expanded | awk '
    BEGIN { in_devices=0; dev=""; dtype=""; connect=""; listen=""; nat="" }
    /^devices:/ { in_devices=1; next }
    in_devices && /^[^[:space:]]/ {
      if (dev != "") printf "DEV|%s|%s|%s|%s|%s\n", dev, dtype, connect, listen, nat
      exit
    }
    in_devices && /^  [^[:space:]].*:/ {
      if (dev != "") printf "DEV|%s|%s|%s|%s|%s\n", dev, dtype, connect, listen, nat
      dev=$1; sub(":", "", dev)
      dtype=""; connect=""; listen=""; nat=""
      next
    }
    in_devices && /^    type:/    { dtype=$2; next }
    in_devices && /^    connect:/ { connect=$2; next }
    in_devices && /^    listen:/  { listen=$2; next }
    in_devices && /^    nat:/     { nat=$2; gsub(/"/, "", nat); next }
    END {
      if (dev != "") printf "DEV|%s|%s|%s|%s|%s\n", dev, dtype, connect, listen, nat
    }
  '
}

get_candidates() {
  local inst="$1"
  parse_proxy_devices "$inst" | while IFS='|' read -r _ dev dtype connect listen nat; do
    [[ "$dtype" == "proxy" ]] || continue
    nat="$(trim_quotes "${nat:-false}")"
    if [[ "$connect" =~ ^(tcp|udp):127\.0\.0\.1:([0-9]+)$ ]] && [[ "$nat" != "true" ]]; then
      local proto="${BASH_REMATCH[1]}"
      local port="${BASH_REMATCH[2]}"
      echo "$dev|$proto|$port|$connect|$listen|$nat"
    fi
  done
}

count_nat_true_proxies() {
  local inst="$1" count=0
  while IFS='|' read -r _ dev dtype connect listen nat; do
    [[ "$dtype" == "proxy" ]] || continue
    nat="$(trim_quotes "${nat:-false}")"
    [[ "$nat" == "true" ]] && ((count+=1))
  done < <(parse_proxy_devices "$inst")
  echo "$count"
}


count_migrated_proxies() {
  local inst="$1" count=0 ipv4
  ipv4="$(get_static_ipv4 "$inst")"
  while IFS='|' read -r _ dev dtype connect listen nat; do
    [[ "$dtype" == "proxy" ]] || continue
    nat="$(trim_quotes "${nat:-false}")"
    if [[ "$nat" == "true" ]]; then
      if [[ "$connect" =~ ^(tcp|udp):0\.0\.0\.0:([0-9]+)$ ]]; then
        ((count+=1))
      elif [[ -n "$ipv4" && "$connect" =~ ^(tcp|udp):${ipv4//./\.}:([0-9]+)$ ]]; then
        ((count+=1))
      fi
    fi
  done < <(parse_proxy_devices "$inst")
  echo "$count"
}

count_all_proxies() {
  local inst="$1" count=0
  while IFS='|' read -r _ dev dtype connect listen nat; do
    [[ "$dtype" == "proxy" ]] || continue
    ((count+=1))
  done < <(parse_proxy_devices "$inst")
  echo "$count"
}

count_candidates() {
  local inst="$1" count=0
  while IFS='|' read -r line; do
    [[ -n "$line" ]] && ((count+=1))
  done < <(get_candidates "$inst")
  echo "$count"
}

get_candidate_instances() {
  local inst ccount
  while IFS= read -r inst; do
    [[ -n "$inst" ]] || continue
    ccount="$(count_candidates "$inst")"
    if [[ "$ccount" -gt 0 ]]; then
      printf '%s
' "$inst"
    fi
  done < <(get_instances)
}

show_instance_summary() {
  local inst="$1"
  echo "实例: $inst"
  echo "IPv4: $(get_static_ipv4 "$inst")"
  echo "候选 proxy:"
  local found=0
  while IFS='|' read -r dev proto port connect listen nat; do
    found=1
    printf '  - %s  listen=%s  connect=%s  nat=%s  ->  %s:0.0.0.0:%s\n' \
      "$dev" "$listen" "$connect" "$nat" "$proto" "$port"
  done < <(get_candidates "$inst")
  [[ $found -eq 1 ]] || echo "  无候选"
}

make_run_dir() {
  local ts
  ts="$(date +%F_%H%M%S)"
  LAST_RUN_DIR="$BACKUP_ROOT/$ts"
  mkdir -p "$LAST_RUN_DIR"
  : > "$LAST_RUN_DIR/successful_instances.txt"
  : > "$LAST_RUN_DIR/failed_instances.txt"
  cat > "$LAST_RUN_DIR/rollback_all.sh" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
EOF2
  chmod +x "$LAST_RUN_DIR/rollback_all.sh"
}

backup_instance() {
  local inst="$1"
  [[ -n "$LAST_RUN_DIR" ]] || make_run_dir
  incus config show "$inst" --expanded > "$LAST_RUN_DIR/$inst.expanded.yaml"
}

build_rollback() {
  local inst="$1"
  local rollback="$LAST_RUN_DIR/$inst.rollback.sh"
  cat > "$rollback" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
EOF2

  while IFS='|' read -r _ dev dtype connect listen nat; do
    [[ "$dtype" == "proxy" ]] || continue
    nat="$(trim_quotes "${nat:-false}")"
    cat >> "$rollback" <<EOF2
incus config device set "$inst" "$dev" connect "$connect"
EOF2
    if [[ "$nat" == "true" ]]; then
      cat >> "$rollback" <<EOF2
incus config device set "$inst" "$dev" nat true
EOF2
    else
      cat >> "$rollback" <<EOF2
incus config device unset "$inst" "$dev" nat || true
EOF2
    fi
  done < <(parse_proxy_devices "$inst")
  chmod +x "$rollback"
}

record_success() {
  local inst="$1"
  [[ -n "$LAST_RUN_DIR" ]] || return 0
  local sf="$LAST_RUN_DIR/successful_instances.txt"
  touch "$sf"
  if ! grep -Fxq "$inst" "$sf"; then
    echo "$inst" >> "$sf"
    echo "bash \"$LAST_RUN_DIR/$inst.rollback.sh\"" >> "$LAST_RUN_DIR/rollback_all.sh"
  fi
}

record_failure() {
  local inst="$1"
  [[ -n "$LAST_RUN_DIR" ]] || return 0
  local ff="$LAST_RUN_DIR/failed_instances.txt"
  touch "$ff"
  grep -Fxq "$inst" "$ff" 2>/dev/null || echo "$inst" >> "$ff"
}

verify_device() {
  local inst="$1" dev="$2" proto="$3" port="$4"
  local wanted_connect="${proto}:0.0.0.0:${port}"
  local got=""
  while IFS='|' read -r _ pdev dtype connect listen nat; do
    [[ "$pdev" == "$dev" ]] || continue
    nat="$(trim_quotes "${nat:-false}")"
    if [[ "$connect" == "$wanted_connect" && "$nat" == "true" ]]; then
      echo "ok"
      return 0
    fi
    got="connect=$connect nat=$nat"
  done < <(parse_proxy_devices "$inst")
  echo "fail ${got:-device_not_found}"
  return 1
}

apply_instance() {
  local inst="$1"
  local mode="$2"

  if ! instance_exists "$inst"; then
    echo "实例不存在: $inst"
    return 1
  fi

  local ipv4
  ipv4="$(get_static_ipv4 "$inst")"
  if [[ -z "$ipv4" ]]; then
    echo "跳过: $inst 没有配置静态 IPv4"
    return 0
  fi

  local candidates
  candidates="$(get_candidates "$inst" || true)"
  if [[ -z "$candidates" ]]; then
    echo "无候选 proxy: $inst"
    return 0
  fi

  if [[ "$mode" == "apply" ]]; then
    [[ -n "$LAST_RUN_DIR" ]] || make_run_dir
    backup_instance "$inst"
    build_rollback "$inst"
  fi

  echo "实例: $inst"
  echo "静态 IPv4: $ipv4"
  echo

  local touched=0 ok_count=0 fail_count=0
  while IFS='|' read -r dev proto port connect listen nat; do
    [[ -n "$dev" ]] || continue
    local new_connect="${proto}:0.0.0.0:${port}"
    echo "设备:   $dev"
    echo "listen: $listen"
    echo "旧值:   connect=$connect nat=${nat:-false}"
    echo "新值:   connect=$new_connect nat=true"

    if [[ "$mode" == "dry-run" ]]; then
      echo "DRY-RUN: incus config device set \"$inst\" \"$dev\" connect \"$new_connect\""
      echo "DRY-RUN: incus config device set \"$inst\" \"$dev\" nat true"
      echo
      touched=1
      continue
    fi

    if ! incus config device set "$inst" "$dev" connect "$new_connect"; then
      echo "结果: FAILED (connect 设置失败)"
      echo
      touched=1
      ((fail_count+=1))
      continue
    fi

    if ! incus config device set "$inst" "$dev" nat true; then
      echo "结果: FAILED (nat 设置失败)"
      echo
      touched=1
      ((fail_count+=1))
      continue
    fi

    if verify_result=$(verify_device "$inst" "$dev" "$proto" "$port"); then
      echo "结果: OK"
      ((ok_count+=1))
    else
      echo "结果: FAILED ($verify_result)"
      ((fail_count+=1))
    fi
    echo
    touched=1
  done <<< "$candidates"

  if [[ "$mode" == "apply" && $touched -eq 1 ]]; then
    if [[ $ok_count -gt 0 ]]; then
      record_success "$inst"
    fi
    if [[ $fail_count -gt 0 ]]; then
      record_failure "$inst"
    fi
    echo "备份目录: $LAST_RUN_DIR"
    echo "回滚脚本: $LAST_RUN_DIR/$inst.rollback.sh"
    echo "修改后剩余候选:"
    local remaining=0
    while IFS='|' read -r dev proto port connect listen nat; do
      remaining=1
      printf '  - %s  listen=%s  connect=%s  nat=%s\n' "$dev" "$listen" "$connect" "$nat"
    done < <(get_candidates "$inst")
    [[ $remaining -eq 1 ]] || echo "  无"
  fi
}

post_check_cmds() {
  local inst="$1"
  local v4 veth0 veth1
  v4="$(get_static_ipv4 "$inst")"
  veth0="$(incus config show "$inst" --expanded | awk '/volatile\.eth0\.host_name:/ {print $2; exit}')"
  veth1="$(incus config show "$inst" --expanded | awk '/volatile\.eth1\.host_name:/ {print $2; exit}')"

  echo "建议复核命令："
  echo "incus config show $inst --expanded | grep -E '^[[:space:]]+proxy-|^[[:space:]]+listen:|^[[:space:]]+connect:|^[[:space:]]+nat:|^[[:space:]]+type: proxy'"
  [[ -n "$veth0" ]] && echo "cat /sys/class/net/$veth0/statistics/rx_bytes; cat /sys/class/net/$veth0/statistics/tx_bytes"
  [[ -n "$veth1" ]] && echo "cat /sys/class/net/$veth1/statistics/rx_bytes; cat /sys/class/net/$veth1/statistics/tx_bytes"
  echo "incus exec $inst -- ip -s link"
  [[ -n "$v4" ]] && echo "incus exec $inst -- ss -lntup"
}

audit_all() {
  echo "===== 审计结果 ====="

  local total_instances=0
  local instances_with_static_ipv4=0
  local total_proxies=0
  local migrated_proxies=0
  local candidate_instances=0
  local candidate_proxies=0
  local skipped_no_static_ipv4=0
  local instances_with_proxy=0
  local instances_no_proxy=0
  local untouched_instances=0
  local partially_done_instances=0
  local fully_done_instances=0

  while IFS= read -r inst; do
    [[ -n "$inst" ]] || continue
    ((total_instances+=1))

    local has_ipv4=0 ipv4
    ipv4="$(get_static_ipv4 "$inst")"
    if [[ -n "$ipv4" ]]; then
      has_ipv4=1
      ((instances_with_static_ipv4+=1))
    fi

    local pcount ncount mcount ccount
    pcount="$(count_all_proxies "$inst")"
    mcount="$(count_migrated_proxies "$inst")"
    ccount="$(count_candidates "$inst")"

    total_proxies=$((total_proxies + pcount))
    migrated_proxies=$((migrated_proxies + mcount))
    candidate_proxies=$((candidate_proxies + ccount))

    if [[ "$pcount" -eq 0 ]]; then
      ((instances_no_proxy+=1))
    else
      ((instances_with_proxy+=1))
    fi

    if [[ "$pcount" -gt 0 ]]; then
      if [[ "$mcount" -eq 0 && "$ccount" -gt 0 ]]; then
        ((untouched_instances+=1))
      elif [[ "$ccount" -eq 0 && "$mcount" -gt 0 ]]; then
        ((fully_done_instances+=1))
      elif [[ "$mcount" -gt 0 && "$ccount" -gt 0 ]]; then
        ((partially_done_instances+=1))
      fi
    fi

    if [[ "$ccount" -gt 0 ]]; then
      ((candidate_instances+=1))
      echo
      show_instance_summary "$inst"
    fi

    if [[ "$has_ipv4" -eq 0 && "$pcount" -gt 0 ]]; then
      ((skipped_no_static_ipv4+=1))
    fi
  done < <(get_instances)

  echo
  echo "===== 审计总结 ====="
  echo "实例总数:                     $total_instances"
  echo "有静态 IPv4 的实例数:         $instances_with_static_ipv4"
  echo "有 proxy 的实例数:            $instances_with_proxy"
  echo "没有任何 proxy 的实例数:      $instances_no_proxy"
  echo "完全未处理的实例数:          $untouched_instances"
  echo "部分已处理的实例数:          $partially_done_instances"
  echo "全部已处理完成的实例数:      $fully_done_instances"
  echo "仍有待处理 proxy 的实例数:   $candidate_instances"
  echo "proxy 设备总数:               $total_proxies"
  echo "已完成迁移的 proxy:           $migrated_proxies"
  echo "待处理 proxy 数:              $candidate_proxies"
  echo "无静态 IPv4 且含 proxy 的实例数: $skipped_no_static_ipv4"
  echo
}

pick_instance() {
  mapfile -t INSTANCES < <(get_instances)
  if [[ ${#INSTANCES[@]} -eq 0 ]]; then
    echo "没有实例"
    return 1
  fi
  echo "可选实例："
  local i=1
  for inst in "${INSTANCES[@]}"; do
    printf '%3d) %s\n' "$i" "$inst"
    ((i+=1))
  done
  read -r -p "输入序号: " idx >&2
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "输入无效" >&2; return 1; }
  (( idx >= 1 && idx <= ${#INSTANCES[@]} )) || { echo "超出范围"; return 1; }
  CURRENT_INSTANCE="${INSTANCES[idx-1]}"
  echo "当前实例: $CURRENT_INSTANCE"
}

batch_choose_instances() {
  local -a instances chosen deduped
  mapfile -t instances < <(get_candidate_instances)
  if [[ ${#instances[@]} -eq 0 ]]; then
    echo "没有待处理实例" >&2
    return 1
  fi

  echo "待处理实例输入方式：多个实例名用空格分隔；直接回车表示全部待处理实例。" >&2
  echo "全部待处理实例(${#instances[@]}): ${instances[*]}" >&2
  read -r -p "> " line

  if [[ -z "$line" ]]; then
    chosen=("${instances[@]}")
  else
    # shellcheck disable=SC2206
    chosen=($line)
  fi

  deduped=()
  local item seen existing
  for item in "${chosen[@]}"; do
    [[ -n "$item" ]] || continue
    seen=0
    for existing in "${deduped[@]:-}"; do
      if [[ "$existing" == "$item" ]]; then
        seen=1
        break
      fi
    done
    [[ $seen -eq 1 ]] && continue
    if instance_exists "$item"; then
      if [[ "$(count_candidates "$item")" -gt 0 ]]; then
        deduped+=("$item")
      else
        echo "跳过无待处理 proxy 的实例: $item" >&2
      fi
    else
      echo "跳过不存在的实例: $item" >&2
    fi
  done

  if [[ ${#deduped[@]} -eq 0 ]]; then
    echo "没有可处理的实例" >&2
    return 1
  fi

  printf '%s\n' "${deduped[@]}"
}

apply_batch() {
  local mode="$1"
  local -a CHOSEN
  if ! mapfile -t CHOSEN < <(batch_choose_instances); then
    return 0
  fi
  [[ ${#CHOSEN[@]} -gt 0 ]] || return 0

  echo "待处理实例数: ${#CHOSEN[@]}"
  echo "待处理实例: ${CHOSEN[*]}"
  if [[ "$mode" == "apply" ]]; then
    read -r -p "确认执行 APPLY？输入 YES 继续: " ans
    [[ "$ans" == "YES" ]] || { echo "已取消"; return 0; }
    make_run_dir
  fi

  local inst
  for inst in "${CHOSEN[@]}"; do
    echo
    echo "=============================="
    apply_instance "$inst" "$mode"
  done

  if [[ "$mode" == "apply" ]]; then
    echo
    echo "===== 批量执行完成 ====="
    echo "运行目录: $LAST_RUN_DIR"
    echo "成功实例清单: $LAST_RUN_DIR/successful_instances.txt"
    echo "失败实例清单: $LAST_RUN_DIR/failed_instances.txt"
    echo "批量回滚脚本: $LAST_RUN_DIR/rollback_all.sh"
  fi
}

list_run_dirs() {
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r
}

pick_run_dir() {
  local -a dirs
  mapfile -t dirs < <(list_run_dirs)
  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "没有可用运行目录"
    return 1
  fi
  echo "可用运行目录：" >&2
  local i=1
  for d in "${dirs[@]}"; do
    printf '%3d) %s\n' "$i" "$d" >&2
    ((i+=1))
  done
  read -r -p "输入序号: " idx >&2
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "输入无效" >&2; return 1; }
  (( idx >= 1 && idx <= ${#dirs[@]} )) || { echo "超出范围" >&2; return 1; }
  printf '%s\n' "${dirs[idx-1]}"
}

rollback_run_all() {
  local run_dir="$1"
  local rb="$run_dir/rollback_all.sh"
  [[ -f "$rb" ]] || { echo "未找到批量回滚脚本: $rb"; return 1; }
  echo "即将执行批量回滚: $rb"
  if [[ -f "$run_dir/successful_instances.txt" ]]; then
    echo "涉及实例:"
    sed 's/^/  - /' "$run_dir/successful_instances.txt"
  fi
  read -r -p "确认回滚本次全部成功实例？输入 YES 继续: " ans
  [[ "$ans" == "YES" ]] || { echo "已取消"; return 0; }
  bash "$rb"
  echo "批量回滚完成"
}

rollback_run_selected() {
  local run_dir="$1"
  local sf="$run_dir/successful_instances.txt"
  [[ -f "$sf" ]] || { echo "未找到成功实例清单: $sf"; return 1; }
  mapfile -t insts < "$sf"
  [[ ${#insts[@]} -gt 0 ]] || { echo "该次运行没有成功实例可回滚"; return 1; }
  echo "本次运行可回滚实例: ${insts[*]}"
  read -r -p "输入要回滚的实例名，多个用空格分隔: " line
  [[ -n "$line" ]] || { echo "未输入实例"; return 1; }
  # shellcheck disable=SC2206
  local chosen=($line)
  local inst ok=0
  echo "将从 $run_dir 回滚以下实例: ${chosen[*]}"
  read -r -p "确认回滚？输入 YES 继续: " ans
  [[ "$ans" == "YES" ]] || { echo "已取消"; return 0; }
  for inst in "${chosen[@]}"; do
    if grep -Fxq "$inst" "$sf" && [[ -f "$run_dir/$inst.rollback.sh" ]]; then
      echo "执行: $run_dir/$inst.rollback.sh"
      bash "$run_dir/$inst.rollback.sh"
      ok=1
    else
      echo "跳过: $inst 不在该次成功实例清单中或缺少回滚脚本"
    fi
  done
  [[ $ok -eq 1 ]] && echo "所选实例回滚完成"
}

rollback_menu() {
  echo "1) 按某次运行整批回滚"
  echo "2) 按某次运行选择实例回滚"
  read -r -p "选择: " sub
  local run_dir
  case "$sub" in
    1)
      run_dir="$(pick_run_dir)" || return 1
      rollback_run_all "$run_dir"
      ;;
    2)
      run_dir="$(pick_run_dir)" || return 1
      rollback_run_selected "$run_dir"
      ;;
    *)
      echo "无效选择"
      return 1
      ;;
  esac
}

main_menu() {
  while true; do
    echo
    echo "===== Incus Proxy 迁移工具 v12 ====="
    echo "当前实例: ${CURRENT_INSTANCE:-<未选择>}"
    echo "1) 审计全部实例"
    echo "2) 选择当前实例"
    echo "3) 查看当前实例候选摘要"
    echo "4) DRY-RUN 当前实例"
    echo "5) APPLY 当前实例"
    echo "6) DRY-RUN 批量执行"
    echo "7) APPLY 批量执行"
    echo "8) 显示当前实例复核命令"
    echo "9) 回滚菜单"
    echo "0) 退出"
    read -r -p "选择: " choice

    case "$choice" in
      1) audit_all; pause ;;
      2) pick_instance || true; pause ;;
      3) [[ -n "$CURRENT_INSTANCE" ]] && show_instance_summary "$CURRENT_INSTANCE" || echo "请先选择实例"; pause ;;
      4) [[ -n "$CURRENT_INSTANCE" ]] && apply_instance "$CURRENT_INSTANCE" dry-run || echo "请先选择实例"; pause ;;
      5)
        if [[ -z "$CURRENT_INSTANCE" ]]; then
          echo "请先选择实例"
        else
          read -r -p "确认 APPLY 当前实例？输入 YES 继续: " ans
          if [[ "$ans" == "YES" ]]; then
            make_run_dir
            apply_instance "$CURRENT_INSTANCE" apply
            echo "运行目录: $LAST_RUN_DIR"
            echo "批量回滚脚本: $LAST_RUN_DIR/rollback_all.sh"
          else
            echo "已取消"
          fi
        fi
        pause
        ;;
      6) apply_batch dry-run; pause ;;
      7) apply_batch apply; pause ;;
      8) [[ -n "$CURRENT_INSTANCE" ]] && post_check_cmds "$CURRENT_INSTANCE" || echo "请先选择实例"; pause ;;
      9) rollback_menu || true; pause ;;
      0) exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

main_menu
