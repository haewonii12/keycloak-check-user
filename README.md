# keycloak-check-user

Keycloak 미접속 계정 사전 안내 및 회수 요청 스크립트.

최종 접속일(접속 기록이 없으면 계정 생성일)로부터 `INACTIVE_DAYS`(기본 90일) 뒤를 **D-DAY**로 정하고 다음을 합니다.

- D-DAY **전**(D-10, D-5, D-3, D-1): 안내 메일 API(`accountmail`) 호출
- D-DAY **당일부터 매일**: 회수 API(`accountdel`) 호출

**Keycloak 사용자 삭제는 하지 않습니다** (회수는 accountdel을 받는 쪽에서 처리).

| 파일 | 역할 | 실행 주기 |
|---|---|---|
| `keycloak.sh` | 사전 안내 → `NOTIFY_API_URL` (accountmail) | 매일 09:00 |
| `keycloak-reclaim.sh` | 회수 요청 → `RECLAIM_API_URL` (accountdel) | 매일 00:00 |
| `common.sh` | 공통 설정·함수 (두 스크립트가 `source`) | - |
| `k8s/cronjob.yaml` | Kubernetes CronJob 배포 매니페스트 | - |

## 요구 사항

`bash`, `curl`, `jq`, GNU `date`(coreutils)

## 사용법

```bash
SERVICE_ID=<자산번호> ./keycloak.sh [realm ...]
SERVICE_ID=<자산번호> ./keycloak-reclaim.sh [realm ...]

# 실제 API 호출 없이 대상·요청 본문만 확인
SERVICE_ID=<자산번호> DRY_RUN=1 ./keycloak.sh realmA
SERVICE_ID=<자산번호> DRY_RUN=1 ./keycloak-reclaim.sh realmA
```

`SERVICE_ID`가 비어 있으면 아무것도 하지 않고 exit 1로 종료합니다.

cron 예:

```
0 9 * * * SERVICE_ID=<자산번호> /path/keycloak-check-user/keycloak.sh         >> /var/log/keycloak-notify.log  2>&1
0 0 * * * SERVICE_ID=<자산번호> /path/keycloak-check-user/keycloak-reclaim.sh >> /var/log/keycloak-reclaim.log 2>&1
```

### 처리할 realm

우선순위: **스크립트 인자 > `REALMS` 환경변수 > 전체 realm** (앞에 값이 있으면 뒤는 무시).
그 결과에서 `EXCLUDE_REALMS`(기본 `master`)에 있는 realm만 추가로 뺍니다.

```bash
REALMS=A ./keycloak.sh       # A만 처리 (EXCLUDE_REALMS 설정과 무관)
./keycloak.sh A              # A만 처리
REALMS=A ./keycloak.sh B     # 인자 우선 → B만 처리
./keycloak.sh                # master를 뺀 전체 realm
```

Keycloak에 없는 realm은 `realm 'A' 없음 → 건너뜀` 로그 후 제외됩니다.

## 환경변수 (`common.sh`)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `SERVICE_ID` | **(필수)** | 자산번호. 두 API 본문의 `SERVICEID` 값 |
| `KEYCLOAK_URL` | `http://aws.keycloak.com` | Keycloak 주소 |
| `KEYCLOAK_ADMIN_USER` | `admin` | master realm 관리자 계정 |
| `KEYCLOAK_ADMIN_PASSWORD` | **(필수)** | 관리자 비밀번호. 환경변수 또는 k8s Secret으로 주입 |
| `NOTIFY_API_URL` | `https://security.com/api/accountmail` | 안내 메일 API |
| `RECLAIM_API_URL` | `https://security/api/accountdel` | 회수 API |
| `REALMS` | (빈 값 = 전체) | 처리할 realm, 공백/쉼표 구분 |
| `EXCLUDE_REALMS` | `master` | 항상 제외할 realm. 빈 값이면 제외 없음 |
| `COMPANY` | (빈 값 = realm 이름) | API 본문의 `COMPANY` 값 |
| `INACTIVE_DAYS` | `90` | 기준일로부터 D-DAY까지 일수 |
| `DRY_RUN` | `0` | `1`이면 API 호출 없이 요청 본문을 로그로 출력 |

안내 시점은 `common.sh`의 `NOTIFY_DAYS=(10 5 3 1)` 배열로 정합니다 (환경변수 아님, 파일 수정 필요).

## 동작 방식

### 기준일과 D-DAY

- **기준일**: 사용자 속성 `last-login` (ISO8601 또는 epoch 초/밀리초). 없으면 `createdTimestamp`(계정 생성일).
  둘 다 없으면 처리에서 제외.
- **D-DAY**: 기준일 + `INACTIVE_DAYS`일. 모든 사용자에게 같은 기준을 적용합니다 (연기·저장 없음).
- 다시 로그인하면 `last-login`이 바뀌어 D-DAY도 새로 계산됩니다.

예 (`INACTIVE_DAYS=30`, 오늘 2026-11-12):

| 최종 접속 | D-DAY | keycloak.sh | keycloak-reclaim.sh |
|---|---|---|---|
| 10-12 (31일 전) | 11-11 | 안내일 아님 (D+1) | 회수 대상 (accountdel 전송) |
| 10-13 (30일 전) | 11-12 | 안내일 아님 (D-DAY) | 회수 대상 (accountdel 전송) |
| 10-18 (25일 전) | 11-17 | **안내 대상 (D-5)** | 회수 대상 아님 |
| 10-21 (22일 전) | 11-20 | 안내일 아님 (D-8) | 회수 대상 아님 |
| 10-23 (20일 전) | 11-22 | **안내 대상 (D-10)** | 회수 대상 아님 |

### keycloak.sh (사전 안내)

1. realm마다 관리자 토큰 재발급(admin-cli 토큰 만료 대비) 후 사용자 전체를 페이지 단위(100명)로 조회
2. 오늘 기준 D-DAY까지 남은 일수가 `NOTIFY_DAYS`(10, 5, 3, 1) 중 하나면 안내 대상
3. 대상자를 모아 realm 단위로 한 번 `NOTIFY_API_URL`에 POST (대상 0명이면 호출 안 함)

- 실행이 누락되거나 전송이 실패한 날의 안내는 다시 보내지 않습니다.

### keycloak-reclaim.sh (회수 요청)

1. realm마다 사용자 조회
2. D-DAY 당일이거나 지난 사용자(남은 일수 ≤ 0)를 회수 대상으로 선정 (안내 이력과 무관)
3. 대상자를 모아 realm 단위로 한 번 `RECLAIM_API_URL`에 POST (대상 0명이면 호출 안 함)

- Keycloak에서 사용자를 지우지 않으므로 **다시 로그인하기 전까지 매일 같은 사용자가 다시 전송**됩니다.
  받는 쪽은 같은 계정의 중복 요청을 처리할 수 있어야 합니다.
- 전송이 실패하거나 실행이 누락돼도 다음 날 자동으로 다시 전송됩니다.
- 처음 운영할 때는 이미 D-DAY가 지난 오래된 계정이 한꺼번에 전송되므로 `DRY_RUN=1`로 대상을 먼저 확인하세요.

## API 요청

공통: `POST`, `Content-Type: application/json; charset=UTF-8`, realm마다 1회 호출, HTTP 2xx면 성공.

### accountmail (keycloak.sh)

| 파라미터 | 형식 | 값 |
|---|---|---|
| `COMPANY` | 문자열 | `COMPANY` 환경변수, 비어 있으면 realm 이름 |
| `SERVICEID` | 문자열 | `SERVICE_ID` 환경변수 (자산번호) |
| `U_INFO[].ACCOUNT` | 문자열 | Keycloak username |
| `U_INFO[].D_DATE` | `YYYYMMDD` | D-DAY |
| `U_INFO[].END_DATE` | `YYYYMMDD` | D-DAY + 1일 |
| `U_INFO[].LASTLOGIN_DT` | `YYYYMMDD` | 기준일 (접속 기록이 없으면 계정 생성일) |
| `U_INFO[].CREATED_DT` | `YYYYMMDD` | 계정 생성일. **생성일이 없으면 필드 생략** |

```json
{
  "COMPANY": "r1",
  "SERVICEID": "AS-0001",
  "U_INFO": [
    {"ACCOUNT": "login25", "D_DATE": "20261117", "END_DATE": "20261118",
     "LASTLOGIN_DT": "20261018", "CREATED_DT": "20260426"}
  ]
}
```

### accountdel (keycloak-reclaim.sh)

| 파라미터 | 형식 | 값 |
|---|---|---|
| `COMPANY` | 문자열 | accountmail과 같음 |
| `SERVICEID` | 문자열 | accountmail과 같음 |
| `U_INFO[].ACCOUNT` | 문자열 | Keycloak username |
| `U_INFO[].LASTLOGIN_DT` | `YYYYMMDD` | 기준일 (접속 기록이 없으면 계정 생성일) |

```json
{
  "COMPANY": "r1",
  "SERVICEID": "AS-0001",
  "U_INFO": [
    {"ACCOUNT": "login31", "LASTLOGIN_DT": "20261012"},
    {"ACCOUNT": "login30", "LASTLOGIN_DT": "20261013"}
  ]
}
```

## 로그

모든 로그는 stderr로 `[YYYY-MM-DD HH:MM:SS] ...` 형식이며, 사용자마다 D-DAY까지 남은 일수를 남깁니다.
남은 일수 표기: `D-5 (5일 남음)`, `D-DAY (오늘)`, `D+2 (2일 경과)`.
API 응답은 `POST <URL> -> HTTP <코드> <응답본문>`으로 남습니다.

keycloak.sh:

```
[r1] login25: 기준일=2026-10-18(last-login), D-DAY=2026-11-17 D-5 (5일 남음) → 안내 대상
[r1] login22: 기준일=2026-10-21(last-login), D-DAY=2026-11-20 D-8 (8일 남음) → 안내일 아님 (안내: D-10 5 3 1)
[r1] login10: 기준일=2026-11-02(last-login), D-DAY=2026-12-02 D-20 (20일 남음) → 안내일 아님 (안내: D-10 5 3 1)
[r1] 안내 전송 완료 (1명)
```

keycloak-reclaim.sh:

```
[r1] login31: 기준일=2026-10-12(last-login), D-DAY=2026-11-11 D+1 (1일 경과) → 회수 대상
[r1] login30: 기준일=2026-10-13(last-login), D-DAY=2026-11-12 D-DAY (오늘) → 회수 대상
[r1] login25: 기준일=2026-10-18(last-login), D-DAY=2026-11-17 D-5 (5일 남음) → 회수 대상 아님
[r1] accountdel 전송 완료 (2명)
```

사용자 수만큼 로그 줄이 생기므로 사용자가 많으면 로그 파일 크기에 유의하세요.

## 종료 코드

- `0`: 정상
- `1`: `SERVICE_ID` 미설정, 토큰 발급·realm 조회 실패, 처리할 realm 없음, 또는 일부 realm에서 사용자 조회/API 전송 실패

## Kubernetes 배포

`k8s/cronjob.yaml`에 Namespace, Secret(관리자 계정), ConfigMap(설정), CronJob 2개(안내 09:00, 회수 00:00, Asia/Seoul)가 들어 있습니다.

```bash
# image 값, Secret 비밀번호, ConfigMap의 SERVICE_ID를 바꾼 뒤
kubectl apply -f k8s/cronjob.yaml
kubectl -n keycloak-check-user create configmap keycloak-check-user-scripts \
  --from-file=common.sh --from-file=keycloak.sh --from-file=keycloak-reclaim.sh \
  --dry-run=client -o yaml | kubectl apply -f -
# 스크립트 수정 시 위 configmap 명령만 다시 실행
```

- k8s에서는 ConfigMap 값(`INACTIVE_DAYS`, `REALMS` 등)이 적용됩니다.
- 처음에는 ConfigMap의 `DRY_RUN`을 `"1"`로 두고 로그 확인 후 `"0"`으로 변경 권장
- 안내 Job `backoffLimit: 0` (재시도 시 메일 중복 발송 방지), 회수 Job `backoffLimit: 1` (재시도 시 accountdel이 다시 전송될 수 있음)
- 이미지에 tzdata가 없으면 `TZ: "KST-9"`(POSIX 표기)를 사용
