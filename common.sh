#!/bin/bash
# keycloak.sh(사전 안내) / keycloak-reclaim.sh(회수) 공통 설정·함수
# 모든 값은 환경변수로 덮어쓸 수 있습니다.

KEYCLOAK_URL="${KEYCLOAK_URL:-http://aws.keycloak.com}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"   # 필수: 환경변수(k8s Secret)로 주입

NOTIFY_API_URL="${NOTIFY_API_URL:-https://security.com/api/accountmail}"
RECLAIM_API_URL="${RECLAIM_API_URL:-https://security/api/accountdel}"

REALMS="${REALMS:-}"                        # 처리할 realm (공백/쉼표 구분). 비우면 전체. 스크립트 인자가 우선
EXCLUDE_REALMS="${EXCLUDE_REALMS-master}"   # 항상 제외할 realm (빈 값으로 주면 제외 없음)

COMPANY="${COMPANY:-}"          # 비어 있으면 realm 이름을 COMPANY로 사용
SERVICE_ID="${SERVICE_ID:-}"    # (필수) 자산번호. API 본문의 SERVICEID 값
INACTIVE_DAYS="${INACTIVE_DAYS:-30}"
NOTIFY_DAYS=(10 5 3 1)          # D-DAY 며칠 전에 안내할지 (첫 값이 가장 큰 값)
DRY_RUN="${DRY_RUN:-0}"         # 1이면 API 호출 없이 요청 내용만 출력
PAGE_SIZE=100

log() { echo "[$(date '+%F %T')] $*" >&2; }

get_token() {
  curl -sS --fail --location "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${KEYCLOAK_ADMIN_USER}" \
    --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    --data-urlencode 'client_id=admin-cli' | jq -er '.access_token'
}

# $1=token → realm 이름 한 줄씩
list_realms() {
  curl -sS --fail --location "${KEYCLOAK_URL}/admin/realms" \
    --header "Authorization: Bearer $1" | jq -er '.[].realm'
}

# $1=token, $2...=스크립트 인자 → 처리할 realm 한 줄씩
# 우선순위: 스크립트 인자 > REALMS 환경변수 > 전체 realm. EXCLUDE_REALMS는 항상 제외
select_realms() {
  local token=$1; shift
  local all wanted r
  all=$(list_realms "$token") || return 1
  wanted="$*"
  [ -z "$wanted" ] && wanted="${REALMS//,/ }"
  [ -z "$wanted" ] && wanted="$all"
  for r in $wanted; do
    if ! grep -qxF -- "$r" <<<"$all"; then log "realm '$r' 없음 → 건너뜀"; continue; fi
    if [[ " ${EXCLUDE_REALMS//,/ } " == *" $r "* ]]; then log "realm '$r' 제외 대상(EXCLUDE_REALMS) → 건너뜀"; continue; fi
    echo "$r"
  done
}

# $1=token $2=realm → 사용자 JSON 한 줄씩 (기본 100명 제한을 피하려고 페이지 단위 조회)
list_users() {
  local first=0 page n
  while :; do
    page=$(curl -sS --fail --location \
      "${KEYCLOAK_URL}/admin/realms/$2/users?first=${first}&max=${PAGE_SIZE}&briefRepresentation=false" \
      --header "Authorization: Bearer $1") || return 1
    n=$(jq 'length' <<<"$page") || return 1
    [ "$n" -eq 0 ] && break
    jq -c '.[]' <<<"$page"
    [ "$n" -lt "$PAGE_SIZE" ] && break
    first=$((first + PAGE_SIZE))
  done
}

# $1=사용자 JSON → last-login을 YYYY-MM-DD로 출력 (없거나 파싱 실패 시 return 1)
# ISO8601("2026-08-13T01:02:03Z")과 epoch(초/밀리초) 형식 모두 처리
lastlogin_ymd() {
  local v
  v=$(jq -r '.attributes."last-login"[0] // empty' <<<"$1")
  [ -z "$v" ] && return 1
  if [[ "$v" =~ ^[0-9]{13}$ ]]; then date -d "@$((v / 1000))" +%F
  elif [[ "$v" =~ ^[0-9]{10}$ ]]; then date -d "@$v" +%F
  else date -d "${v%%T*}" +%F 2>/dev/null
  fi
}

# $1=사용자 JSON → 계정 생성일 YYYYMMDD (없으면 빈 문자열)
created_ymd() {
  local ts
  ts=$(jq -r '.createdTimestamp // empty' <<<"$1")
  [ -n "$ts" ] && date -d "@$((ts / 1000))" +%Y%m%d
}

# $1=사용자 JSON → "YYYY-MM-DD 기준" 출력. 기준은 last-login, 접속 기록이 없으면 created(계정 생성일)
# 둘 다 없으면 return 1
user_baseline() {
  local d
  if d=$(lastlogin_ymd "$1"); then echo "$d last-login"; return 0; fi
  d=$(created_ymd "$1")
  [ -n "$d" ] || return 1
  echo "$(date -d "$d" +%F) created"
}

# $1, $2 = YYYY-MM-DD → $2 - $1 (일 수)
days_between() {
  echo $(( ($(date -ud "$2" +%s) - $(date -ud "$1" +%s)) / 86400 ))
}

# $1=D-DAY까지 남은 일수 → "D-5 (5일 남음)" / "D-DAY (오늘)" / "D+3 (3일 경과)"
dday_label() {
  if [ "$1" -gt 0 ]; then echo "D-$1 ($1일 남음)"
  elif [ "$1" -eq 0 ]; then echo "D-DAY (오늘)"
  else echo "D+$((-$1)) ($((-$1))일 경과)"
  fi
}

# $1=URL $2=JSON body → HTTP 2xx이면 성공
post_json() {
  if [ "$DRY_RUN" = 1 ]; then
    log "[DRY_RUN] POST $1"; jq . <<<"$2" >&2; return 0
  fi
  local resp code
  resp=$(curl -sS --location -w '\n%{http_code}' -X POST "$1" \
    --header 'Content-Type: application/json; charset=UTF-8' \
    --data-binary "$2") || { log "POST 실패(연결 오류): $1"; return 1; }
  code=${resp##*$'\n'}
  resp=${resp%$'\n'*}
  log "POST $1 -> HTTP $code $resp"
  [[ "$code" =~ ^2 ]]
}
