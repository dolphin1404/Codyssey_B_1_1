# B1-1: 시스템 관제 자동화 (Linux Monitor System)

> 본 문서는 **교육장 Mac(일반 사용자, sudo 권한 없음)** 환경에서 Docker 컨테이너 안 Ubuntu 24.04 에 `agent-app` 을 배포하고, 보안·권한·환경·자동 모니터링까지 일관되게 셋업한 전체 과정을 기록합니다. 모든 명령과 그에 따른 출력은 실제 실행 결과이며, 각 단계마다 **"무엇을 했는가" + "왜 그렇게 했는가"** 를 함께 설명합니다.

---

## 1. 초기 환경 구축 (Mac + Docker)

교육장 Mac은 일반 사용자 계정이라 sudo 권한이 없습니다. 따라서 **호스트(Mac)에서는 docker 명령만**, 미션 본 작업(useradd, ufw, /var/log 등)은 모두 **컨테이너 안 root 셸**에서 수행합니다.

### 1.1 아키텍처 자동 매칭 (Apple Silicon vs Intel Mac)

```bash
kyumin@MacBook Codyssey_B_1_1 % uname -m
# arm64   → Apple Silicon (M1~M4)
# x86_64  → Intel Mac

kyumin@MacBook Codyssey_B_1_1 % if [[ "$(uname -m)" == "arm64" ]]; then
  export PLATFORM=linux/arm64 BIN=agent-app-linux-arm64
else
  export PLATFORM=linux/amd64 BIN=agent-app-linux-x86
fi
kyumin@MacBook Codyssey_B_1_1 % echo "PLATFORM=$PLATFORM  BIN=$BIN"
```

### 1.2 zip 풀고 본인 아키텍처 바이너리만 작업 폴더로

```bash
kyumin@MacBook Codyssey_B_1_1 % unzip -o ~/Downloads/agent-app.zip -d ~/Downloads/agent-app-extracted
kyumin@MacBook Codyssey_B_1_1 % cp ~/Downloads/agent-app-extracted/$BIN ./$BIN
kyumin@MacBook Codyssey_B_1_1 % chmod +x ./$BIN
kyumin@MacBook Codyssey_B_1_1 % ls -lh $BIN
```

### 1.3 Ubuntu 24.04 컨테이너 생성 및 실행

```bash
kyumin@MacBook Codyssey_B_1_1 % docker pull --platform=$PLATFORM ubuntu:24.04

kyumin@MacBook Codyssey_B_1_1 % docker run -d --name codyssey --privileged --cgroupns=host \
  --platform=$PLATFORM \
  --tmpfs /tmp:exec --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -p 20022:20022 -p 15034:15034 \
  ubuntu:24.04 sleep infinity
```

> - `--privileged` + cgroup 마운트 — UFW(iptables) 가 컨테이너 안에서 동작하려면 필수
> - `--tmpfs /tmp:exec` — PyInstaller 가 `/tmp` 에 lib 펼치고 실행해야 하므로 `exec` 옵션
> - `-p 20022:20022 -p 15034:15034` — Mac 호스트에서 직접 SSH·앱 접근 가능

### 1.4 필수 패키지 설치 + 데몬 기동

```bash
kyumin@MacBook Codyssey_B_1_1 % docker exec codyssey bash -c '
  apt-get update
  apt-get install -y --no-install-recommends \
    openssh-server ufw cron acl dos2unix \
    iproute2 procps psmisc ca-certificates curl
  mkdir -p /run/sshd /root/work
  service ssh start
  service cron start
'
```

### 1.5 스크립트 + 바이너리 docker cp

```bash
kyumin@MacBook Codyssey_B_1_1 % docker cp ./monitor.sh        codyssey:/root/work/
kyumin@MacBook Codyssey_B_1_1 % docker cp ./report.sh         codyssey:/root/work/
kyumin@MacBook Codyssey_B_1_1 % docker cp ./log_retention.sh  codyssey:/root/work/
kyumin@MacBook Codyssey_B_1_1 % docker cp ./setup.sh          codyssey:/root/work/
kyumin@MacBook Codyssey_B_1_1 % docker cp ./$BIN              codyssey:/root/work/

kyumin@MacBook Codyssey_B_1_1 % docker exec codyssey bash -c "
  cd /root/work
  dos2unix *.sh 2>/dev/null
  chmod +x *.sh $BIN
  ls -la
"
```

### 1.6 컨테이너 안 root 셸 진입

```bash
kyumin@MacBook Codyssey_B_1_1 % docker exec -it codyssey bash
root@codyssey:/# cd /root/work
root@codyssey:/root/work#
```

이 시점부터 모든 명령은 **컨테이너 안 root 셸**에서 실행합니다.

---

## 2. 일괄 프로비저닝 (setup.sh)

본 프로젝트는 `setup.sh` 하나로 **SSH·UFW·계정·그룹·ACL·환경변수·키파일·cron 12 단계를 한 번에** 구성합니다. (수동 명령으로 풀어보고 싶다면 `요구사항_수행_내역서.md` 의 §1~§5 참고)

```bash
root@codyssey:/root/work# bash setup.sh ./agent-app-linux-x86
# (Apple Silicon 이면 ./agent-app-linux-arm64)
```

**실행 결과 — 12 단계 전체**

<img width="1110" height="1094" alt="setup.sh 12단계" src="https://github.com/user-attachments/assets/d1d9dda4-e1ea-445f-b663-6477c1168a30" />

> 각 단계의 세부 결과는 아래 §3 ~ §8 에서 단계별로 확인합니다.

---

## 3. 보안 및 네트워크 설정

### 3.1 SSH 포트 변경 (22 → 20022) + Root 원격 로그인 차단

```bash
root@codyssey:/# cat /etc/ssh/sshd_config.d/agent-app.conf
# Managed by setup.sh
# Port 20022
# PermitRootLogin no

root@codyssey:/# sshd -T | grep -Ei '^(port|permitrootlogin)\b'
# port 20022
# permitrootlogin no

root@codyssey:/# ss -tulnp | grep sshd
# tcp LISTEN 0 128 0.0.0.0:20022 0.0.0.0:* users:(("sshd",pid=...,fd=3))
# tcp LISTEN 0 128    [::]:20022    [::]:* users:(("sshd",pid=...,fd=4))
```

**실행 결과**

<img width="671" height="224" alt="SSH 설정 확인" src="https://github.com/user-attachments/assets/19e18542-8beb-4b37-9633-7fda703fe779" />

> **왜 SSH 포트를 옮기고 root 를 막는가 (위협 모델)** — 22번은 Shodan·Masscan·Mirai 봇넷이 1순위로 스캔하는 포트입니다. 인터넷에 노출된 22번은 시간당 수천 건의 brute-force 를 받습니다. 20022 로 옮기면 *"비용 효율 낮으면 다음 표적으로 넘어가는"* 자동 스캐너 대부분을 우회 — **공격 표면 축소**입니다(절대 방어가 아니라 공격 비용 상승). `root` 는 모든 유닉스에 존재하는 *알려진 계정명*이라 사전공격의 표준 타깃이므로, 일반 계정 로그인 + `sudo` 2단계를 강제하면 단일 비밀번호 유출만으로 시스템이 통째로 넘어가지 않습니다(**최소 권한 원칙**의 1차 방어선).

### 3.2 UFW 방화벽 — 20022/tcp, 15034/tcp 만 허용

```bash
root@codyssey:/# ufw status verbose
# Status: active
# Default: deny (incoming), allow (outgoing), deny (routed)
# To                         Action      From
# --                         ------      ----
# 20022/tcp                  ALLOW IN    Anywhere
# 15034/tcp                  ALLOW IN    Anywhere
# 20022/tcp (v6)             ALLOW IN    Anywhere (v6)
# 15034/tcp (v6)             ALLOW IN    Anywhere (v6)
```

**실행 결과**

<img width="412" height="199" alt="UFW 상태" src="https://github.com/user-attachments/assets/3ac69f01-4ebb-4073-9dbd-43cd25233005" />

> `default deny incoming` 으로 **화이트리스트 모델**을 강제 — 명시적으로 허용한 SSH(20022)·APP(15034) 외 모든 인바운드 차단. 새 서비스가 생기면 `ufw allow` 한 줄을 의식적으로 추가해야 하므로 *의도하지 않은 노출*을 막습니다.

---

## 4. 사용자 / 그룹 / 권한 관리

### 4.1 계정 및 그룹 멤버십

```bash
root@codyssey:/# id agent-admin
# uid=1000(agent-admin) gid=1002(agent-admin) groups=1002(agent-admin),1000(agent-common),1001(agent-core)

root@codyssey:/# id agent-dev
# uid=1001(agent-dev) gid=1003(agent-dev) groups=1003(agent-dev),1000(agent-common),1001(agent-core)

root@codyssey:/# id agent-test
# uid=1002(agent-test) gid=1004(agent-test) groups=1004(agent-test),1000(agent-common)

root@codyssey:/# getent group agent-common
# agent-common:x:1000:agent-admin,agent-dev,agent-test

root@codyssey:/# getent group agent-core
# agent-core:x:1001:agent-admin,agent-dev
```

> 🔑 `agent-test` 가 `agent-core` 그룹에 **없음** — `api_keys` / 로그 디렉토리 접근 자동 차단의 1차 게이트.

**실행 결과**

<img width="737" height="160" alt="계정 / 그룹" src="https://github.com/user-attachments/assets/ef29ae13-c468-490a-9b6b-e62dfcce0710" />

### 4.2 디렉토리 구조 + ACL 권한

| 경로 | owner | group | mode | 의도 |
| --- | --- | --- | --- | --- |
| `$AGENT_HOME` | agent-admin | agent-common | 2775 | 공용 진입점 |
| `$AGENT_HOME/upload_files` | agent-admin | agent-common | 2775 + ACL | 공유 업로드 (admin/dev/test 모두 R/W) |
| `$AGENT_HOME/api_keys` | agent-admin | agent-core | **2770 + ACL** | 비밀 (admin/dev 만 R/W) |
| `$AGENT_HOME/bin` | agent-dev | agent-core | 2770 | 스크립트 보관 |
| `/var/log/agent-app` | agent-admin | agent-core | **2770 + ACL** | 로그 (admin/dev 만 R/W) |

```bash
root@codyssey:/# ls -ld /home/agent-admin /home/agent-admin/agent-app \
                       /home/agent-admin/agent-app/upload_files \
                       /home/agent-admin/agent-app/api_keys \
                       /home/agent-admin/agent-app/bin \
                       /var/log/agent-app

root@codyssey:/# getfacl --absolute-names /home/agent-admin/agent-app/api_keys
# group:agent-core:rwx
# other::---

root@codyssey:/# getfacl --absolute-names /var/log/agent-app
# group:agent-core:rwx
# other::---
```

> `2xxx` 모드의 앞자리 `2` 는 **SETGID 비트** — 디렉토리 안에 새로 생기는 파일이 부모 디렉토리의 그룹(agent-common / agent-core)을 자동 상속하게 해서 사람의 실수를 줄입니다.

**실행 결과**

<img width="693" height="591" alt="디렉토리 + ACL" src="https://github.com/user-attachments/assets/452d9bfd-0dd9-4cb9-9b18-3c4e7f32fdba" />

### 4.3 음성/양성 검증 — 그룹 분리가 실제로 동작하는지

```bash
# (음성) agent-test 는 agent-core 가 아니므로 차단되어야 함
root@codyssey:/# su - agent-test -c 'ls /home/agent-admin/agent-app/api_keys'
# ls: cannot open directory '/home/agent-admin/agent-app/api_keys': Permission denied

# (양성) agent-dev 는 agent-core 멤버 → 통과
root@codyssey:/# su - agent-dev -c 'ls /home/agent-admin/agent-app/api_keys'
# secret.key
# t_secret.key
```

<img width="608" height="61" alt="음성/양성 검증" src="https://github.com/user-attachments/assets/2e1a0d55-c38e-4182-9cd1-50836cd1e416" />

### 4.4 왜 api_keys / 로그 디렉토리를 `agent-core` 로 제한했나 — 최소 권한 원칙

**최소 권한 원칙(Principle of Least Privilege)**: 각 주체는 본인 직무 수행에 *필요한 최소한의* 권한만 가진다.

| 역할 | 직무 | 필요한 데이터 | api_keys / 로그 |
| --- | --- | --- | --- |
| agent-admin | 운영/관리, cron 실행자 | 전 영역 | ✅ (agent-core) |
| agent-dev | monitor.sh 작성, 디버깅 | 코드 + 로그 + 키 검증 | ✅ (agent-core) |
| agent-test | QA/테스트 | **공유 업로드 파일만** | ❌ (agent-core 아님) |

- **agent-test 가 `api_keys` 를 보면 안 되는 이유**: 테스트 환경에서 키가 유출되면 *lateral movement*(측면 이동)의 진입점이 됨. QA 도구가 키를 로그·스크린샷에 노출시킬 위험도 있음.
- **agent-test 가 로그를 보면 안 되는 이유**: 운영 로그에는 IP·내부 경로 등 민감 정보가 쌓일 수 있어, QA 가 운영 로그를 보는 건 *직무 분리(separation of duties)* 위반.
- **그룹을 2단계(common/core)로 나눈 이유 = 방어 깊이(defense in depth)**:
  1. 1차 게이트 — 그룹 멤버십. `agent-test` 는 `agent-core` 에 **없음**.
  2. 2차 게이트 — ACL `group:agent-core:rwx` + `other::---`. 실수로 누가 agent-test 를 agent-core 에 넣어도, 디렉토리 모드 `2770` 이 즉시 차단.

즉 "공유(`upload_files`)" 와 "비밀(`api_keys`·로그)" 의 *데이터 등급*을 그룹으로 분리해, 한 계정의 권한 변경이 다른 등급으로 **전파되지 않게** 한 것입니다. (위 §4.3 음성 테스트가 이 정책이 실제로 작동함을 증명)

---

## 5. 환경 변수 + 키 파일

### 5.1 `/etc/profile.d/agent-app.sh`

```bash
root@codyssey:/# cat /etc/profile.d/agent-app.sh
# # Managed by setup.sh
# export AGENT_HOME="/home/agent-admin/agent-app"
# export AGENT_PORT="15034"
# export AGENT_UPLOAD_DIR="${AGENT_HOME}/upload_files"
# export AGENT_KEY_PATH="${AGENT_HOME}/api_keys"
# export AGENT_LOG_DIR="/var/log/agent-app"

root@codyssey:/# su - agent-admin -c 'env | grep ^AGENT_ | sort'
# AGENT_HOME=/home/agent-admin/agent-app
# AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys
# AGENT_LOG_DIR=/var/log/agent-app
# AGENT_PORT=15034
# AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files
```

> 새 agent-app-linux 바이너리는 `AGENT_KEY_PATH` 를 **디렉토리** 로 기대합니다 (이전 spec 은 파일 경로). setup.sh 가 이 차이를 반영.
> 환경 변수를 `/etc/profile.d/` 에 박아두면 *어느 로그인 셸로 들어와도 같은 경로*가 보장되어, 운영자/개발자/QA 가 동일한 설정으로 디버깅할 수 있습니다.

**실행 결과**

<img width="521" height="200" alt="환경 변수" src="https://github.com/user-attachments/assets/d4ff87de-f2bd-40e6-9e8d-a17205ea54d6" />

### 5.2 API 키 파일 (`secret.key`)

```bash
root@codyssey:/# ls -l /home/agent-admin/agent-app/api_keys/
# -rw-r-----+ 1 agent-admin agent-core   19 ... secret.key
# lrwxrwxrwx  1 root        agent-core   10 ... t_secret.key -> secret.key

root@codyssey:/# cat /home/agent-admin/agent-app/api_keys/secret.key
# agent_api_key_test
```

> 새 바이너리는 파일명을 `secret.key` 로 기대 (이전 spec 은 `t_secret.key`). 호환을 위해 심볼릭 링크도 함께 생성. 권한 `640 (rw-r-----)` — owner(admin) 읽기/쓰기, group(agent-core) 읽기, other 차단.

**실행 결과**

<img width="567" height="119" alt="API 키 파일" src="https://github.com/user-attachments/assets/30938b67-86d7-4c74-9425-4b1302001e00" />

---

## 6. 애플리케이션 실행 (agent-app)

### 6.1 Boot Sequence 5/5 + "Agent READY"

```bash
root@codyssey:/# su - agent-admin -c 'cd $AGENT_HOME && ./agent-app' &
```

```
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
   ... Running as service user 'agent-admin' (uid=1000)
[2/5] Verifying Environment Variables     [OK]
   ... All required Envs correct
[3/5] Checking Required Files             [OK]
   ... Verified 'secret.key' with correct key string.
[4/5] Checking Port Availability          [OK]
   ... Port 15034 is available.
[5/5] Verifying Log Permission            [OK]
   ... Log directory is writable: /var/log/agent-app
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

**실행 결과**

<img width="572" height="211" alt="Boot Sequence" src="https://github.com/user-attachments/assets/c8512b7d-e782-4427-bc7c-ea0b6331a423" />

### 6.2 LISTEN 상태 확인

```bash
root@codyssey:/# ss -tulnp | grep 15034
# tcp LISTEN 0 1 0.0.0.0:15034 0.0.0.0:* users:(("agent-app",pid=...,fd=4))

root@codyssey:/# pidof agent-app
# 573 574
```

<img width="705" height="46" alt="LISTEN 확인" src="https://github.com/user-attachments/assets/c88dc459-6143-4d5e-a5a8-576f99446205" />
<img width="291" height="29" alt="pidof" src="https://github.com/user-attachments/assets/d6a068f1-8fbe-4902-898d-b7f889f0219e" />

---

## 7. 시스템 모니터링 스크립트 (monitor.sh)

### 7.1 파일 위치 / 권한 + 권한 정책 설계 의도

```bash
root@codyssey:/# ls -l /home/agent-admin/agent-app/bin/monitor.sh
# -rwxr-x--- 1 agent-dev agent-core 4597 ... monitor.sh
```

- 소유자: **agent-dev** — 개발자 역할이 스크립트를 작성/수정하므로 owner.
- 그룹: **agent-core** — admin·dev 만 실행 가능한 보안 그룹.
- 권한: **750 (rwxr-x---)** — other 완전 차단.

**소유자(agent-dev) / 실행자(agent-admin, cron) 권한 정책을 어떻게 만족시켰나**

| 비트 | 대상 | 권한 | 결과 |
| --- | --- | --- | --- |
| owner `rwx` | agent-dev | 읽기/쓰기/실행 | 개발자가 스크립트를 **편집·실행** |
| group `r-x` | agent-core(admin·dev) | 읽기/실행 | **agent-admin 이 그룹 비트로 실행** — cron 실행 가능 |
| other `---` | 그 외(agent-test 포함) | 없음 | 접근 차단 |

- cron 은 `crontab -u agent-admin` 으로 등록되어 **agent-admin uid 로** monitor.sh 를 실행합니다.
- agent-admin 은 `agent-core` 멤버 → 750 모드의 **group `r-x` 비트**로 실행 권한을 획득. (소유자가 아니어도 그룹으로 통과)
- 로그 디렉토리 `/var/log/agent-app` 는 `owner=agent-admin, group=agent-core, 2770` → agent-admin 이 owner 비트로 쓰기, SETGID 로 새 로그가 agent-core 그룹 자동 상속.
- 즉 "**작성자(agent-dev) ≠ 실행자(agent-admin)**" 를 그룹(agent-core) 공유로 잇고, other 를 막아 *최소 권한*을 동시에 만족시켰습니다.

### 7.2 monitor.sh 동작 요약

| 단계 | 항목 | 실패 시 |
| --- | --- | --- |
| Health 1 | `pidof agent-app` 프로세스 점검 | `exit 1` |
| Health 2 | `ss -tln` TCP 15034 LISTEN 점검 | `exit 1` |
| Status | UFW/firewalld 활성 점검 | `[WARNING]` 만 출력 |
| Resource | CPU% (`/proc/stat` 1초 델타) / MEM% (`MemAvailable`) / DISK% (`df -P /`) | — |
| Threshold | CPU>20 / MEM>10 / DISK>80 | `[WARNING]` 만 출력 |
| Logging | `/var/log/agent-app/monitor.log` 에 append (`>>`) | — |
| Rotate | 10MB 초과 시 `.1`~`.10` 시프트, 최대 10개 | — |

### 7.3 프로세스 식별 / 포트 확인 — 사용 명령과 선택 이유

**프로세스 식별** — `pidof -s agent-app` → (없으면) `pgrep -x agent-app`

| 명령 | 선택 이유 |
| --- | --- |
| `pidof -s` | 실행 파일의 **basename** 으로만 매칭 → 인자/경로에 우연히 "agent-app" 이 들어간 다른 명령(예: `vim agent-app.sh`)을 false-positive 로 잡지 않음. `-s` 는 첫 매칭 1개만 반환. |
| `pgrep -x` (fallback) | `/proc/<pid>/comm` **정확 매칭**. pidof 가 인터프리터 스크립트에 약한 점을 보완. |
| `pgrep -f` 를 **안 쓴 이유** | `-f` 는 cmdline 전체를 substring 매칭 → monitor.sh 자기 자신의 명령행("...monitor.sh ...agent-app...")까지 잡아 *자기 자신을 살아있다고 오판*할 위험. 그래서 의도적으로 제외. |

**포트 확인** — `ss -tln | grep ':15034'` (없으면 `netstat -tln`)

| 명령 | 선택 이유 |
| --- | --- |
| `ss -tln` | `netstat` 의 현대 대체. iproute2 로 기본 설치, 큰 연결 테이블에서 netstat 보다 수 배 빠름. `-t`(TCP) `-l`(LISTEN) `-n`(no DNS). |
| `netstat` fallback | minimal 환경에서 `ss` 가 없을 때 대비. |
| 끝 고정 정규식 | `0.0.0.0:15034` / `[::]:15034` 모두 매칭하되 `$`(끝)로 고정해 `150341` 같은 부분일치 방지. |

### 7.4 CPU/MEM/DISK 추출·파싱 방식 + 로그 포맷 고정 이유

| 자원 | 추출 방식 | 선택 이유 |
| --- | --- | --- |
| **CPU%** | `/proc/stat` 의 cpu 라인을 **1초 간격 2회** 읽어 `(total_Δ − idle_Δ) × 100 / total_Δ` | `top -bn1` 의 첫 샘플은 *부팅 이후 누적 평균*이라 순간값과 다름. /proc/stat 델타가 cron 1분 주기에 더 정확. |
| **MEM%** | `/proc/meminfo` 의 `(MemTotal − MemAvailable) / MemTotal × 100` | `free` 의 used 는 buff/cache 처리가 커널 버전마다 달라 부정확. `MemAvailable` 은 커널이 직접 계산한 *"앱이 즉시 쓸 수 있는 메모리"* (Linux 3.14+). |
| **DISK%** | `df -P /` 의 5번째 컬럼에서 `%` 제거 | `-P`(POSIX) 옵션은 디바이스명이 길어도 **한 줄**로 유지 → `awk NR==2` 파싱이 안 깨짐. |

**로그 포맷을 왜 이 형태로 고정했나**

```
[YYYY-MM-DD HH:MM:SS] PID:.. CPU:..% MEM:..% DISK_USED:..%
```

- `report.sh` 의 awk 파서가 정규식으로 **정확히 일치**해야 통계를 계산할 수 있음 → 포맷이 흔들리면 통계가 깨짐.
- 시간을 ISO 8601 유사 형태로 고정 → `date -d` 로 바로 파싱 가능 → report.sh 의 시간구간 필터를 단순 구현.
- 한 줄(single line) 고정 → `grep`/`awk`/`tail` 로 다루기 쉽고, 라인 수 = 샘플 수.

### 7.5 "경고만 출력 vs 즉시 종료" 를 분리한 운영상 이유

| 분류 | 항목 | 액션 |
| --- | --- | --- |
| **Health (알람)** | 프로세스 다운 / 포트 LISTEN 실패 | `exit 1` → cron 이 메일·모니터링 알림 트리거 |
| **Status / Threshold (신호)** | 방화벽 비활성, CPU·MEM·DISK 임계 초과 | `[WARNING]` 만 출력, `exit 0` |

1. **알람 vs 신호 분리** — "서비스 자체가 멈춤"은 즉시 행동이 필요한 *알람*, "임계치 일시 초과"는 누적 추적용 *신호*. 성격이 다르므로 종료 코드를 다르게.
2. **경고 피로(alert fatigue) 방지** — 모든 임계 초과를 `exit 1` 로 처리하면 CPU 가 한 번 튈 때마다 알림 폭주 → 사람이 알림을 무시 → **진짜 장애가 묻힘**.
3. **자가 치유성** — 일시적 임계 초과는 시스템이 스스로 회복하는 게 정상. 즉시 종료하면 회복 기회 없이 인시던트화.
4. **로그 가시성** — `exit 1` 로 끝나면 그 줄만 남지만, WARNING 으로 누적하면 report.sh 가 *"매시 정각마다 CPU 가 튄다"* 같은 시계열 패턴을 분석 가능.

### 7.6 로그 용량 관리 (10MB / 최대 10개) — 구현 방식 + 동작 원리

**구현 방식: logrotate 가 아니라 monitor.sh 내부 스크립트 로직**

| 비교 | 스크립트 내부 (채택) | logrotate |
| --- | --- | --- |
| 트리거 | monitor.sh 매 실행 직전(매분) | `/etc/cron.daily/logrotate` 하루 1회 |
| 정확도 | 10MB 초과 **즉시** 회전 | 최대 24시간까지 더 누적 가능 |
| 의존성 | 없음 (systemd 없는 컨테이너도 OK) | logrotate 패키지 + 설정 파일 |
| 권한 | 이미 agent-admin/agent-core 권한으로 동작 | root 실행 → ACL 우회 가능성 |

**동작 원리** (monitor.sh 의 rotate 블록)

```bash
MAX_SIZE_BYTES=$((10 * 1024 * 1024))   # 10MB
MAX_ROTATIONS=10                        # 최대 10개 보관

size=$(stat -c%s "$LOG_FILE")           # 현재 로그 크기(byte)
if [ "$size" -ge "$MAX_SIZE_BYTES" ]; then
  rm -f "${LOG_FILE}.10"                       # ① 가장 오래된 .10 삭제
  for i in 9 8 7 ... 1; do                      # ② 역순 시프트
    mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))" #    .9→.10, .8→.9, ..., .1→.2
  done
  mv "$LOG_FILE" "${LOG_FILE}.1"               # ③ 현재 로그 → .1
fi
```

- **왜 역순(9→1) 으로 도는가**: 정순(1→2)으로 돌리면 `.1→.2` 직후 `.2→.3` 이 방금 만든 `.2` 를 덮어써 데이터가 사라짐. 역순이면 항상 빈 슬롯으로 이동.
- **결과**: 항상 `monitor.log`(현재) + `.1`~`.10`(과거 10개) = 최대 11개, 총 ~110MB 상한. 가장 오래된 것부터 자동 폐기.

### 7.7 직접 실행

```bash
root@codyssey:/# su - agent-admin -c '/home/agent-admin/agent-app/bin/monitor.sh'
```

```
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app'... [OK] (PID: 573)
Checking port 15034... [OK]

[FIREWALL CHECK]
UFW service is active... [OK]

[RESOURCE MONITORING]
CPU Usage  : 2.3%
MEM Usage  : 14.6%
DISK Used  : 2%
[WARNING] MEM threshold exceeded (14.6% > 10%)

[INFO] Log appended: /var/log/agent-app/monitor.log
```

**실행 결과**

<img width="670" height="268" alt="monitor.sh happy path" src="https://github.com/user-attachments/assets/9cd10d07-e793-4db8-a05b-d516f5acb465" />

### 7.8 FAIL path — 앱을 죽이면 exit 1

```bash
root@codyssey:/# kill -9 $(pidof agent-app)
root@codyssey:/# su - agent-admin -c '/home/agent-admin/agent-app/bin/monitor.sh'; echo "exit=$?"
```

```
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app'... [FAIL]
[ERROR] process 'agent-app' is not running
exit=1
```

> 프로세스 점검 실패 즉시 `exit 1` — 자원 수집/임계치 단계까지 가지 않고 종료. cron 이 이 종료 코드를 받아 알림을 띄울 수 있음.

**실행 결과**

<img width="748" height="143" alt="monitor.sh FAIL" src="https://github.com/user-attachments/assets/9434b5a3-1662-437d-b24a-5a2706761cb4" />

---

## 8. cron 자동 실행 (매분)

### 8.1 등록된 cron 룰

```bash
root@codyssey:/# crontab -u agent-admin -l
# * * * * * AGENT_HOME=/home/agent-admin/agent-app AGENT_PORT=15034 AGENT_LOG_DIR=/var/log/agent-app /home/agent-admin/agent-app/bin/monitor.sh >/dev/null 2>&1
```

> 환경변수를 cron 라인에 직접 명시 — cron 은 로그인 셸이 아니라 `/etc/profile.d/*.sh` 가 자동 로드되지 않음.

### 8.2 60초 간격 자동 누적

```bash
root@codyssey:/# tail -8 /var/log/agent-app/monitor.log
# [2026-05-24 10:54:02] PID:581 CPU:0.9% MEM:14.9% DISK_USED:2%
# [2026-05-24 10:54:45] PID:581 CPU:2.1% MEM:16.6% DISK_USED:2%
# [2026-05-24 10:55:02] PID:581 CPU:1.0% MEM:14.3% DISK_USED:2%
# [2026-05-24 10:56:02] PID:581 CPU:0.3% MEM:13.8% DISK_USED:2%
# [2026-05-24 10:57:02] PID:581 CPU:1.9% MEM:16.1% DISK_USED:2%
```

**실행 결과**

<img width="1117" height="171" alt="cron 누적" src="https://github.com/user-attachments/assets/42eca002-4f5e-4dc4-a851-c68aea570af9" />

### 8.3 리다이렉션 `>` 와 `>>` 의 차이 — 로그 누적에 `>>` 가 필요한 이유

| 기호 | 동작 | 기존 파일 |
| --- | --- | --- |
| `>` | redirect | **truncate(0 byte 로 비움)** 후 새로 씀 |
| `>>` | append | **파일 끝에 추가** |

```bash
echo "first"  > a.txt    # a.txt = "first"
echo "second" > a.txt    # a.txt = "second"          ← 첫 줄 사라짐 (덮어쓰기)
echo "third" >> a.txt    # a.txt = "second\nthird"    ← 누적 (추가)
```

- monitor.sh 는 cron 으로 **매분 별도 프로세스**로 실행됩니다.
- 로그를 `>` 로 쓰면 매 실행이 *이전 모든 라인을 지워* → monitor.log 가 항상 1줄 → 통계·시계열 분석 불가.
- `>>` 로 쓰면 매 실행이 *끝에 한 줄 추가* → 누적 시계열이 만들어져 report.sh 분석이 가능. **그래서 로그 기록은 반드시 `>>`.**
- 한편 cron 라인 끝의 `>/dev/null 2>&1` 의 `>` 는 cron 메일용 stdout/stderr 를 *버리는* 의도된 truncate (메일 폭주 방지). 즉 **누적엔 `>>`, 일회성 버림엔 `>`** 로 의식적으로 구분.

---

## 9. 설계 해설 & 트러블슈팅 (확장 시나리오)

### 9.1 모니터링 대상이 Nginx 로 바뀐다면 — monitor.sh 핵심 수정 포인트

| 영역 | agent-app → Nginx 변경점 |
| --- | --- |
| **프로세스** | `agent-app` → `nginx`. 단 Nginx 는 master+worker 다중 프로세스 → `pidof` 보다 `cat /run/nginx.pid`(master PID)가 정석. |
| **포트** | 15034 → 80(HTTP) + 443(HTTPS). port 체크를 배열 루프로: `for p in 80 443; do ...; done` (둘 다 LISTEN 이어야 OK). |
| **임계값** | Nginx 는 worker 수만큼 CPU 가 곱해짐 → CPU 임계 20%→50~70% 상향, MEM 도 캐시 고려해 상향. |
| **추가 점검** | "LISTEN ≠ 응답". `curl -fsS http://localhost/health` 액티브 헬스체크 추가(200=OK, 5xx=FAIL). |
| **로그** | monitor.log 는 동일. 단 Nginx 자체 `access.log`/`error.log`(5xx 비율 등)는 별도 모니터링 권장. |
| **방화벽** | UFW: 20022 + (15034 제거) + 80 + 443. |

### 9.2 "프로세스는 살아있는데 포트가 안 열린다" — 원인 후보 + 확인 순서

**원인 후보 (가능성 높은 순)**

1. **bind 실패** — 다른 프로세스가 같은 포트 점유 → 앱 로그에 `Address already in use`. 확인: `ss -tlnp | grep :15034`
2. **127.0.0.1 에만 bind** — LISTEN 되지만 외부 불가. 확인: `ss -tln` 의 Local Address 가 `127.0.0.1:` 인지 `0.0.0.0:` 인지 → bind 주소를 `0.0.0.0` 로
3. **방화벽 드롭** — LISTEN 은 OK 인데 외부 거절. 확인: `ufw status` / 다른 호스트에서 `nc -zv <host> 15034`
4. **startup deadlock** — 프로세스만 존재, main loop 미진입(DB 대기 등). 확인: `strace -p <pid>` 가 futex/poll 에서 멈춤
5. **listen() 이전 blocking I/O** — 큰 파일 로드 등. 확인: `ps -o pid,wchan,cmd <pid>` 의 wait channel
6. **SELinux/AppArmor 가 bind 거부**. 확인: `journalctl | grep -iE "denied|avc"`

**확인 순서 (위에서부터 거의 다 잡힘)**

```
1. pgrep -af agent-app          # 진짜 살아있나(좀비/defunct 아닌가)
2. ss -tlnp | grep 15034        # LISTEN? bind 주소? (1차로 대부분 판별)
3. nc -zv localhost 15034       # 로컬 접근되나
4. nc -zv <외부호스트> 15034     # 외부 접근되나 (3과 다르면 방화벽)
5. tail /var/log/agent-app/...  # 앱 자체 에러 로그
6. strace -p <pid>              # 위에서 못 잡으면 시스템콜 추적
```

### 9.3 로그가 급증해 디스크가 가득 찰 위험 — 운영자 대응

**단기(시간 단위)**
1. 어디서 폭증하는지: `du -h /var/log/agent-app/* | sort -h | tail`
2. 회전된 로그 즉시 압축: `gzip /var/log/agent-app/monitor.log.{2..10}` (~10배 절감)
3. 비정상 폭증 판단: `grep -c WARNING ...` / `grep ERROR ... | head` (코드 버그·공격 여부)
4. 디스크 잔여 < 5% 면 *가동중단 방지 > 사후분석* → 오래된 아카이브부터 삭제
5. 임시로 monitor.sh 주기 완화: `* * * * *` → `*/5 * * * *`

**중기(일 단위)**
1. 보존기간 단축: `log_retention.sh` 의 `COMPRESS_AGE_DAYS 7→3`, `DELETE_AGE_DAYS 30→14`
2. 로그 레벨 상향: 앱 DEBUG→INFO→WARN
3. `/var/log` 별도 파티션·볼륨 분리 → 루트(/) 가 같이 차는 사태 방지
4. monitor.sh `DISK_WARN 80→70` 으로 조기 경보
5. 중앙 로그 수집(rsyslog/Loki) 도입 — 로컬 짧게, 원격 장기 보관
6. 근본 원인(RCA): 무한 retry·connection storm·panic loop 여부 추적

> 본 프로젝트는 이미 **(보너스)** `log_retention.sh` 로 7일 경과 압축 + 30일 경과 삭제를 자동화해 단기/중기 대응 일부를 스크립트화해 두었습니다.

---

## 10. 검증 체크리스트 (요구사항 §8 기준)

| # | 항목 | 결과 | 근거 |
| --- | --- | --- | --- |
| 1 | SSH 포트 20022 + Root 원격 차단 | ✅ | §3.1 |
| 2 | UFW 활성 + 20022·15034 만 허용 | ✅ | §3.2 |
| 3 | 계정 3개 + 그룹 2개 + 멤버십 | ✅ | §4.1 |
| 4 | 디렉토리 구조 + 권한/ACL | ✅ | §4.2~4.4 |
| 5 | 환경 변수 5종 노출 | ✅ | §5.1 |
| 6 | 키 파일 = `agent_api_key_test` | ✅ | §5.2 |
| 7 | Boot 5/5 [OK] + Agent READY + LISTEN | ✅ | §6 |
| 8 | monitor.sh 콘솔 출력 (Health/Resource/Threshold) | ✅ | §7.7 |
| 9 | monitor.log 포맷 일치 + 매분 누적 | ✅ | §7.4, §8.2 |
| 10 | Health 실패 시 exit 1 | ✅ | §7.8 |
| 11 | 로그 용량 관리(10MB/10개) 동작 설명 | ✅ | §7.6 |

---

## 11. 컨테이너 정리

```bash
# 작업 끝나면
kyumin@MacBook Codyssey_B_1_1 % docker stop codyssey && docker rm codyssey
```

---

## 12. 학습 정리 (한 줄씩)

- **SSH 포트 변경 + Root 차단** (§3.1): 22번은 자동화 스캐너의 1순위 타깃 → *공격 표면 축소*, root 차단은 *최소 권한 원칙*의 1차 방어선.
- **UFW** (§3.2): `default deny incoming` 으로 화이트리스트 모델 강제 → *의도하지 않은 노출* 차단.
- **계정·그룹·ACL** (§4.4): `agent-common`(공유) vs `agent-core`(비밀) 2단계 분리 + SETGID 자동 그룹 상속 → 최소 권한.
- **환경 변수 고정** (§5.1): `/etc/profile.d/` 로 어느 셸에서든 같은 경로 보장. cron 은 로그인 셸이 아니므로 cron 라인에 직접 명시.
- **명령 선택** (§7.3): `pidof`/`ss` 는 정확·고속, `pgrep -f` 는 자기 자신 오탐 위험으로 제외.
- **자원·포맷** (§7.4): `/proc/stat` 델타·`MemAvailable`·`df -P` 로 정확히 측정, 포맷 고정으로 report.sh 파싱 보장.
- **경고 vs 종료** (§7.5): 알람(exit 1) ↔ 신호(WARNING) 분리로 경고 피로 방지.
- **로그 회전** (§7.6): 스크립트 내부 역순 시프트로 10MB/10개 유지.
- **`>` vs `>>`** (§8.3): 누적엔 `>>`(덮어쓰기 방지), 일회성 버림엔 `>`.
- **로그 보존 정책**: 7일 = 진행 중 인시던트 즉시 가용성, 30일 = 주간/월간 회고. 그 이상은 비용 대비 가치 급감 → 자동 삭제.

---

*본 문서는 학습 및 동료 평가를 위해 작성된 실제 실행 로그입니다. 모든 스크린샷은 교육장 Mac → Docker(Ubuntu 24.04) 환경에서 직접 캡처되었습니다.*
