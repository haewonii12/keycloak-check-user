#!/bin/bash
# 미접속 계정 회수 사전 안내
#  - 기준일 + INACTIVE_DAYS일(D-DAY) 기준 D-10, D-5, D-3, D-1 인 사용자를 accountmail API로 전송
#    (안내일을 놓친 사용자도 연기 없이 원래 D-DAY 기준으로 처리)
#  - 기준일: 최종 접속일(last-login). 접속 기록이 없으면 계정 생성일
#  - 사용법: ./keycloak.sh [realm ...]   (인자 없으면 REALMS 환경변수, 그것도 없으면 전체 realm)
#            master 등 EXCLUDE_REALMS에 있는 realm은 항상 제외
#  - 매일 1회 실행 (cron 예: 0 9 * * * /path/keycloak-check-user/keycloak.sh >> /var/log/keycloak-notify.log 2>&1)
#  - 회수(accountdel 전송)는 keycloak-reclaim.sh 가 담당
set -o pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

today=$(date +%F)
log "today: $today, 안내 대상: D-${NOTIFY_DAYS[*]}"

[ -n "$SERVICE_ID" ] || { log "SERVICE_ID(자산번호) 환경변수 필수 → 종료"; exit 1; }

token=$(get_token) || { log "토큰 발급 실패"; exit 1; }
realms=$(select_realms "$token" "$@") || { log "realm 조회 실패"; exit 1; }
[ -z "$realms" ] && { log "처리할 realm 없음"; exit 1; }
log "대상 realm: $(echo $realms)"

rc=0
for realm in $realms; do
  token=$(get_token) || { log "토큰 발급 실패"; exit 1; }   # admin-cli 토큰 만료(기본 60초) 대비 realm마다 재발급
  users=$(list_users "$token" "$realm") || { log "[$realm] 사용자 조회 실패"; rc=1; continue; }
  company="${COMPANY:-$realm}"
  u_info='[]'

  while IFS= read -r user; do
    [ -z "$user" ] && continue
    username=$(jq -r '.username' <<<"$user")

    if ! read -r base base_type < <(user_baseline "$user"); then
      log "[$realm] $username: 접속 기록·생성일 모두 없음 → 안내 제외"
      continue
    fi

    d_day=$(date -d "$base +${INACTIVE_DAYS} days" +%F)
    left=$(days_between "$today" "$d_day")
    if [[ " ${NOTIFY_DAYS[*]} " != *" $left "* ]]; then
      log "[$realm] $username: 기준일=$base($base_type), D-DAY=$d_day $(dday_label "$left") → 안내일 아님 (안내: D-${NOTIFY_DAYS[*]})"
      continue
    fi

    log "[$realm] $username: 기준일=$base($base_type), D-DAY=$d_day $(dday_label "$left") → 안내 대상"
    u_info=$(jq -c \
      --arg account  "$username" \
      --arg d_date   "$((INACTIVE_DAYS - left))" \
      --arg end_date "$(date -d "$d_day +1 day" +%Y%m%d)" \
      --arg created  "$(created_ymd "$user")" \
      --arg lastlog  "$(date -d "$base" +%Y%m%d)" \
      '. + [{ACCOUNT: $account, D_DATE: $d_date, END_DATE: $end_date, LASTLOGIN_DT: $lastlog}
            + (if $created == "" then {} else {CREATED_DT: $created} end)]' <<<"$u_info")
  done <<<"$users"

  count=$(jq length <<<"$u_info")
  if [ "$count" -eq 0 ]; then
    log "[$realm] 안내 대상 없음"
    continue
  fi

  body=$(jq -cn --arg company "$company" --arg sid "$SERVICE_ID" --argjson u "$u_info" \
    '{COMPANY: $company, SERVICEID: $sid, U_INFO: $u}')
  if ! post_json "$NOTIFY_API_URL" "$body"; then
    log "[$realm] 안내 전송 실패 ($count명)"
    rc=1
    continue
  fi
  log "[$realm] 안내 전송 완료 ($count명)"
done

exit $rc
