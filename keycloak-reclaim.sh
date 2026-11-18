#!/bin/bash
# 미접속 계정 회수
#  - 매일 00:00 cron 등록
#    (cron 예: 0 0 * * * /path/keycloak-check-user/keycloak-reclaim.sh >> /var/log/keycloak-reclaim.log 2>&1)
#  - 기준일: 최종 접속일(last-login). 접속 기록이 없으면 계정 생성일
#  - 사용법: ./keycloak-reclaim.sh [realm ...]   (인자 없으면 REALMS 환경변수, 그것도 없으면 전체 realm)
#            master 등 EXCLUDE_REALMS에 있는 realm은 항상 제외
#  - 대상: D-DAY(기준일 + INACTIVE_DAYS일) 당일 및 경과 사용자 (안내 이력과 무관) → accountdel API 전송
#    (Keycloak 사용자 삭제는 하지 않음. 재접속하기 전까지 매일 다시 전송됨)
set -o pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

today=$(date +%F)
log "today: $today, 회수 기준: 기준일 후 ${INACTIVE_DAYS}일 경과"

[ -n "$SERVICE_ID" ] || { log "SERVICE_ID(자산번호) 환경변수 필수 → 종료"; exit 1; }

token=$(get_token) || { log "토큰 발급 실패"; exit 1; }
realms=$(select_realms "$token" "$@") || { log "realm 조회 실패"; exit 1; }
[ -z "$realms" ] && { log "처리할 realm 없음"; exit 1; }
log "대상 realm: $(echo $realms)"

rc=0
for realm in $realms; do
  token=$(get_token) || { log "토큰 발급 실패"; exit 1; }
  users=$(list_users "$token" "$realm") || { log "[$realm] 사용자 조회 실패"; rc=1; continue; }
  company="${COMPANY:-$realm}"
  u_info='[]'

  while IFS= read -r user; do
    [ -z "$user" ] && continue
    username=$(jq -r '.username' <<<"$user")

    if ! read -r base base_type < <(user_baseline "$user"); then
      log "[$realm] $username: 접속 기록·생성일 모두 없음 → 회수 제외"
      continue
    fi

    d_day=$(date -d "$base +${INACTIVE_DAYS} days" +%F)
    left=$(days_between "$today" "$d_day")
    msg="[$realm] $username: 기준일=$base($base_type), D-DAY=$d_day $(dday_label "$left")"
    if [ "$left" -gt 0 ]; then
      log "$msg → 회수 대상 아님"
      continue
    fi

    log "$msg → 회수 대상"
    u_info=$(jq -c \
      --arg account "$username" \
      --arg lastlog "$(date -d "$base" +%Y%m%d)" \
      '. + [{ACCOUNT: $account, LASTLOGIN_DT: $lastlog}]' <<<"$u_info")
  done <<<"$users"

  count=$(jq length <<<"$u_info")
  if [ "$count" -eq 0 ]; then
    log "[$realm] 회수 대상 없음"
    continue
  fi

  body=$(jq -cn --arg company "$company" --arg sid "$SERVICE_ID" --argjson u "$u_info" \
    '{COMPANY: $company, SERVICEID: $sid, U_INFO: $u}')
  if post_json "$RECLAIM_API_URL" "$body"; then
    log "[$realm] accountdel 전송 완료 (${count}명)"
  else
    log "[$realm] accountdel 전송 실패 (${count}명)"
    rc=1
  fi
done

exit $rc
