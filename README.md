# B1-1 시스템 관제 자동화

교육장 PC(x86_64 / Intel Mac)에서 Docker 컨테이너(Ubuntu 24.04)를 띄우고, 그 안에서 보안·권한·환경·모니터링을 설정한 기록이다. 교육장 계정은 sudo 권한이 없어서, 호스트(Mac)에서는 docker 명령만 쓰고 실제 작업은 컨테이너 안 root 셸에서 했다.

스크립트는 `setup.sh`(전체 셋업), `monitor.sh`(모니터링), `report.sh`(통계, 보너스), `log_retention.sh`(로그 보존, 보너스) 네 개다.

---

## 1. 컨테이너 준비

### 1.1 바이너리 준비

zip 안에 x86용/arm64용 두 개가 있는데 교육장 PC는 x86_64라 `agent-app-linux-x86`만 쓴다.

```bash
kyumin14040659@c6r10s7 Codyssey_B_1_1 % uname -m
# x86_64

kyumin14040659@c6r10s7 Codyssey_B_1_1 % unzip -o ~/Downloads/agent-app.zip -d ~/Downloads/agent-app-extracted
kyumin14040659@c6r10s7 Codyssey_B_1_1 % cp ~/Downloads/agent-app-extracted/agent-app-linux-x86 ./agent-app-linux-x86
kyumin14040659@c6r10s7 Codyssey_B_1_1 % chmod +x ./agent-app-linux-x86
```

### 1.2 컨테이너 실행

```bash
kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker pull --platform=linux/amd64 ubuntu:24.04

kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker run -d --name codyssey --privileged --cgroupns=host \
  --platform=linux/amd64 \
  --tmpfs /tmp:exec --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -p 20022:20022 -p 15034:15034 \
  ubuntu:24.04 sleep infinity
```

- `--platform=linux/amd64` : 바이너리와 arch를 맞춰야 한다. 안 맞으면 나중에 실행할 때 `No such file or directory`가 난다.
- `--privileged` : UFW(iptables)가 컨테이너 안에서 동작하려면 필요하다.
- `--tmpfs /tmp:exec` : 바이너리가 /tmp에 라이브러리를 풀고 실행하므로 exec 옵션이 있어야 한다.

### 1.3 패키지 설치 + 파일 복사

```bash
kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker exec codyssey bash -c '
  apt-get update
  apt-get install -y --no-install-recommends \
    openssh-server ufw cron acl dos2unix iproute2 procps psmisc ca-certificates curl
  mkdir -p /run/sshd /root/work
  service ssh start
  service cron start
'

kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker cp ./monitor.sh        codyssey:/root/work/
kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker cp ./report.sh         codyssey:/root/work/
kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker cp ./log_retention.sh  codyssey:/root/work/
kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker cp ./setup.sh          codyssey:/root/work/
kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker cp ./agent-app-linux-x86 codyssey:/root/work/

kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker exec codyssey bash -c '
  cd /root/work && dos2unix *.sh 2>/dev/null && chmod +x *.sh agent-app-linux-x86
'
```

### 1.4 컨테이너 진입

```bash
kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker exec -it codyssey bash
root@codyssey:/# cd /root/work
```

여기부터는 컨테이너 안 root 셸에서 작업한다.

---

## 2. setup.sh 로 한 번에 셋업

SSH, UFW, 계정/그룹, 디렉토리/ACL, 환경변수, 키파일, cron까지 `setup.sh` 하나로 처리했다. 인자 없이 실행하면 폴더 안의 `agent-app-linux-x86`을 찾아서 설치한다.

```bash
root@codyssey:/root/work# bash setup.sh
```

설치 끝나면 바이너리가 제대로 들어갔는지 한 번 확인한다. (이게 없으면 §6에서 `No such file or directory`로 헤맨다)

```bash
root@codyssey:/root/work# ls -l /home/agent-admin/agent-app/agent-app
# -rwxr-x--- 1 agent-admin agent-core 6498144 ... agent-app
```

<img width="1110" height="1094" alt="setup.sh 12단계" src="https://github.com/user-attachments/assets/d1d9dda4-e1ea-445f-b663-6477c1168a30" />

아래 §3~§8은 setup.sh가 만든 결과를 항목별로 확인한 것이다.

---

## 3. 보안 / 네트워크

### 3.1 SSH 포트 20022 + root 로그인 차단

```bash
root@codyssey:/# cat /etc/ssh/sshd_config.d/agent-app.conf
# Port 20022
# PermitRootLogin no

root@codyssey:/# sshd -T | grep -Ei '^(port|permitrootlogin)\b'
# port 20022
# permitrootlogin no

root@codyssey:/# ss -tulnp | grep sshd
# tcp LISTEN 0 128 0.0.0.0:20022 0.0.0.0:* users:(("sshd",pid=...,fd=3))
```

<img width="671" height="224" alt="SSH 설정 확인" src="https://github.com/user-attachments/assets/19e18542-8beb-4b37-9633-7fda703fe779" />

22번은 스캐너가 제일 먼저 노리는 포트라 옮겨서 자동 공격 시도를 줄였다. root 직접 로그인을 막으면 비밀번호 하나 털려도 바로 장악당하지 않고, 일반 계정 + sudo 두 단계를 거쳐야 한다.

### 3.2 UFW — 20022, 15034 만 허용

```bash
root@codyssey:/# ufw status verbose
# Status: active
# Default: deny (incoming), allow (outgoing)
# 20022/tcp                  ALLOW IN    Anywhere
# 15034/tcp                  ALLOW IN    Anywhere
```

<img width="412" height="199" alt="UFW 상태" src="https://github.com/user-attachments/assets/3ac69f01-4ebb-4073-9dbd-43cd25233005" />

기본을 deny로 두고 필요한 포트(SSH 20022, 앱 15034)만 열었다. 새 서비스가 생기면 직접 allow를 추가해야 하니 안 쓰는 포트가 실수로 열리는 일이 없다.

---

## 4. 계정 / 그룹 / 권한

### 4.1 계정과 그룹

```bash
root@codyssey:/# id agent-admin
# uid=1000(agent-admin) ... groups=...,1000(agent-common),1001(agent-core)

root@codyssey:/# id agent-dev
# uid=1001(agent-dev) ... groups=...,1000(agent-common),1001(agent-core)

root@codyssey:/# id agent-test
# uid=1002(agent-test) ... groups=...,1000(agent-common)

root@codyssey:/# getent group agent-common
# agent-common:x:1000:agent-admin,agent-dev,agent-test
root@codyssey:/# getent group agent-core
# agent-core:x:1001:agent-admin,agent-dev
```

`agent-test`는 `agent-core`에 안 넣었다. 이게 api_keys와 로그 접근을 막는 첫 번째 장치다.

<img width="737" height="160" alt="계정 / 그룹" src="https://github.com/user-attachments/assets/ef29ae13-c468-490a-9b6b-e62dfcce0710" />

### 4.2 디렉토리와 ACL

| 경로 | owner | group | mode |
| --- | --- | --- | --- |
| `$AGENT_HOME` | agent-admin | agent-common | 2775 |
| `upload_files` | agent-admin | agent-common | 2775 + ACL |
| `api_keys` | agent-admin | agent-core | 2770 + ACL |
| `bin` | agent-dev | agent-core | 2770 |
| `/var/log/agent-app` | agent-admin | agent-core | 2770 + ACL |

```bash
root@codyssey:/# getfacl --absolute-names /home/agent-admin/agent-app/api_keys
# group:agent-core:rwx
# other::---
```

mode 앞자리 `2`는 SETGID라서, 디렉토리 안에 새로 만든 파일이 그 디렉토리 그룹을 자동으로 물려받는다. 매번 chown 안 해도 그룹이 맞춰진다.

<img width="693" height="591" alt="디렉토리 + ACL" src="https://github.com/user-attachments/assets/452d9bfd-0dd9-4cb9-9b18-3c4e7f32fdba" />

### 4.3 접근 막히는지 직접 확인

```bash
# agent-test 는 막혀야 정상
root@codyssey:/# su - agent-test -c 'ls /home/agent-admin/agent-app/api_keys'
# ls: cannot open directory ...: Permission denied

# agent-dev 는 되어야 정상
root@codyssey:/# su - agent-dev -c 'ls /home/agent-admin/agent-app/api_keys'
# secret.key
```

<img width="608" height="61" alt="음성/양성 검증" src="https://github.com/user-attachments/assets/2e1a0d55-c38e-4182-9cd1-50836cd1e416" />

api_keys랑 로그를 agent-core로 묶은 건 "필요한 사람만 본다"는 원칙 때문이다. agent-test(QA)는 공유 폴더만 쓰면 되고, 키나 운영 로그까지 볼 필요가 없다. 키가 테스트 중에 새거나 로그의 민감 정보가 노출되는 걸 막는다. 그룹으로 한 번, ACL `other::---`로 또 한 번 막아서 누가 실수로 권한을 건드려도 다른 폴더로 번지지 않는다.

---

## 5. 환경 변수 / 키 파일

```bash
root@codyssey:/# cat /etc/profile.d/agent-app.sh
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

`/etc/profile.d/`에 넣으면 누가 로그인해도 같은 경로를 쓴다. 참고로 이번 바이너리는 `AGENT_KEY_PATH`를 파일이 아니라 디렉토리로 받고, 키 파일명은 `secret.key`다.

<img width="521" height="200" alt="환경 변수" src="https://github.com/user-attachments/assets/d4ff87de-f2bd-40e6-9e8d-a17205ea54d6" />

```bash
root@codyssey:/# cat /home/agent-admin/agent-app/api_keys/secret.key
# agent_api_key_test
```

키 파일 권한은 640이라 owner와 agent-core 그룹만 읽는다.

<img width="567" height="119" alt="API 키 파일" src="https://github.com/user-attachments/assets/30938b67-86d7-4c74-9425-4b1302001e00" />

---

## 6. 앱 실행

일반 계정(agent-admin)으로 실행한다. (root로 돌리면 바이너리가 막는다)

```bash
root@codyssey:/# su - agent-admin -c 'cd $AGENT_HOME && ./agent-app' &
```

```
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
[2/5] Verifying Environment Variables     [OK]
[3/5] Checking Required Files             [OK]
[4/5] Checking Port Availability          [OK]
[5/5] Verifying Log Permission            [OK]
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

<img width="572" height="211" alt="Boot Sequence" src="https://github.com/user-attachments/assets/c8512b7d-e782-4427-bc7c-ea0b6331a423" />

```bash
root@codyssey:/# ss -tulnp | grep 15034
# tcp LISTEN 0 1 0.0.0.0:15034 0.0.0.0:* users:(("agent-app",pid=...,fd=4))
```

<img width="705" height="46" alt="LISTEN 확인" src="https://github.com/user-attachments/assets/c88dc459-6143-4d5e-a5a8-576f99446205" />
<img width="291" height="29" alt="pidof" src="https://github.com/user-attachments/assets/d6a068f1-8fbe-4902-898d-b7f889f0219e" />

> 만약 `./agent-app: No such file or directory`가 뜨면 둘 중 하나다. ① 바이너리가 설치 안 됨 → `ls -l $AGENT_HOME/agent-app`로 확인하고 `bash setup.sh` 다시. ② 컨테이너 arch가 amd64가 아님 → `--platform=linux/amd64`로 다시 만든다.

---

## 7. monitor.sh

### 7.1 위치와 권한

```bash
root@codyssey:/# ls -l /home/agent-admin/agent-app/bin/monitor.sh
# -rwxr-x--- 1 agent-dev agent-core 4597 ... monitor.sh
```

소유자는 agent-dev(스크립트 작성자), 그룹은 agent-core, 권한은 750이다. cron은 agent-admin으로 돌아가는데, agent-admin도 agent-core라서 그룹 실행 비트(r-x)로 실행된다. 소유자가 아니어도 그룹으로 돌릴 수 있고, other는 막혀 있다. 즉 작성자와 실행자가 다른데 그룹으로 묶어서 둘 다 되게 했다.

### 7.2 하는 일

- 프로세스 확인: `pidof agent-app` → 없으면 exit 1
- 포트 확인: `ss`로 15034 LISTEN → 없으면 exit 1
- 방화벽 확인: 꺼져 있으면 경고만
- 자원 수집: CPU / MEM / DISK
- 임계치: CPU>20, MEM>10, DISK>80 이면 경고만
- 로그 기록: `/var/log/agent-app/monitor.log`에 한 줄 추가
- 로그 회전: 10MB 넘으면 .1~.10으로 밀어냄

### 7.3 프로세스/포트 확인에 쓴 명령

프로세스는 `pidof`로 찾았다. 이름(basename)으로만 매칭해서, 인자에 우연히 "agent-app"이 들어간 다른 명령을 잘못 잡지 않는다. `pgrep -f`는 명령어 전체를 보기 때문에 monitor.sh 자기 자신까지 잡힐 수 있어서 안 썼다.

포트는 `ss`를 썼다. netstat의 최신 대체이고 더 빠르다. 없을 때를 대비해 netstat로 fallback도 넣었다.

### 7.4 CPU/MEM/DISK 값 구하는 방법

- CPU: `/proc/stat`을 1초 간격으로 두 번 읽어서 그 차이로 계산했다. `top -bn1`은 첫 값이 부팅 이후 평균이라 실제 순간값과 달라서 안 썼다.
- MEM: `/proc/meminfo`의 MemAvailable로 계산했다. `free`의 used는 버전마다 buff/cache 계산이 달라서 MemAvailable이 더 정확하다.
- DISK: `df -P /`의 Used%를 썼다. `-P`를 주면 한 줄로 나와서 파싱이 안 깨진다.

로그 포맷은 `[시간] PID:.. CPU:..% MEM:..% DISK_USED:..%`로 고정했다. report.sh가 이 포맷을 정규식으로 읽어서 통계를 내기 때문에, 형식이 바뀌면 통계가 깨진다.

### 7.5 경고만 하고 안 멈추는 항목

프로세스/포트가 죽은 건 서비스가 멈춘 거라 exit 1로 끝낸다. 반면 방화벽 꺼짐이나 임계치 초과는 경고만 찍고 계속 간다. 이런 것까지 매번 exit 1로 처리하면 CPU가 잠깐 튈 때마다 알림이 쏟아져서, 정작 진짜 장애를 놓치게 된다. 일시적인 건 로그에 쌓아두고 나중에 report.sh로 패턴을 보면 된다.

### 7.6 로그 10MB / 10개 관리

logrotate 대신 monitor.sh 안에서 직접 처리했다. 매분 실행될 때마다 크기를 보고 10MB를 넘으면 회전시키니까, 하루 한 번 도는 logrotate보다 즉시 반응하고 별도 설정 파일도 필요 없다.

```bash
size=$(stat -c%s "$LOG_FILE")
if [ "$size" -ge "$MAX_SIZE_BYTES" ]; then   # 10MB
  rm -f "${LOG_FILE}.10"                      # 가장 오래된 것 삭제
  for i in 9 8 ... 1; do
    mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"  # .9→.10 ... .1→.2
  done
  mv "$LOG_FILE" "${LOG_FILE}.1"             # 현재 → .1
fi
```

번호를 거꾸로(9→1) 도는 이유는, 정순으로 하면 .1을 .2로 옮긴 직후 .2를 .3으로 옮길 때 방금 만든 걸 덮어쓰기 때문이다. 결과적으로 현재 로그 + .1~.10 해서 최대 11개만 남는다.

### 7.7 실행 결과

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

<img width="670" height="268" alt="monitor.sh happy path" src="https://github.com/user-attachments/assets/9cd10d07-e793-4db8-a05b-d516f5acb465" />

### 7.8 앱을 죽이면 exit 1

```bash
root@codyssey:/# kill -9 $(pidof agent-app)
root@codyssey:/# su - agent-admin -c '/home/agent-admin/agent-app/bin/monitor.sh'; echo "exit=$?"
```

```
[HEALTH CHECK]
Checking process 'agent-app'... [FAIL]
[ERROR] process 'agent-app' is not running
exit=1
```

<img width="748" height="143" alt="monitor.sh FAIL" src="https://github.com/user-attachments/assets/9434b5a3-1662-437d-b24a-5a2706761cb4" />

---

## 8. cron 자동 실행

### 8.1 등록

```bash
root@codyssey:/# crontab -u agent-admin -l
# * * * * * AGENT_HOME=/home/agent-admin/agent-app AGENT_PORT=15034 AGENT_LOG_DIR=/var/log/agent-app /home/agent-admin/agent-app/bin/monitor.sh >/dev/null 2>&1
```

cron은 로그인 셸이 아니라서 `/etc/profile.d`가 안 읽힌다. 그래서 환경변수를 cron 줄에 직접 적었다.

### 8.2 1분마다 쌓이는지 확인

```bash
root@codyssey:/# tail -5 /var/log/agent-app/monitor.log
# [2026-05-24 10:54:02] PID:581 CPU:0.9% MEM:14.9% DISK_USED:2%
# [2026-05-24 10:55:02] PID:581 CPU:1.0% MEM:14.3% DISK_USED:2%
# [2026-05-24 10:56:02] PID:581 CPU:0.3% MEM:13.8% DISK_USED:2%
# [2026-05-24 10:57:02] PID:581 CPU:1.9% MEM:16.1% DISK_USED:2%
```

<img width="1117" height="171" alt="cron 누적" src="https://github.com/user-attachments/assets/42eca002-4f5e-4dc4-a851-c68aea570af9" />

### 8.3 `>` 와 `>>`

`>`는 파일을 비우고 새로 쓰고, `>>`는 끝에 덧붙인다. 로그는 `>>`로 쌓아야 한다. cron이 매분 새 프로세스로 도는데 `>`로 쓰면 매번 기존 줄이 지워져서 한 줄만 남고 통계를 못 낸다. (cron 줄 끝의 `>/dev/null`은 출력 버리는 용도라 `>`가 맞다)

---

## 9. 확장 / 트러블슈팅

### 9.1 대상이 Nginx로 바뀐다면

- 프로세스 이름을 nginx로 바꾼다. Nginx는 master/worker 여러 개라 `cat /run/nginx.pid`로 master를 보는 게 낫다.
- 포트는 80/443 두 개를 확인한다.
- worker가 여러 개라 CPU가 더 높게 나오니 임계치를 올린다.
- LISTEN만으로는 부족해서 `curl /health` 같은 응답 확인을 추가하면 좋다.

### 9.2 프로세스는 살아있는데 포트가 안 열릴 때

가능한 원인과 확인 순서:

1. `pgrep -af agent-app` — 진짜 떠 있는지 (좀비 아닌지)
2. `ss -tlnp | grep 15034` — LISTEN인지, 127.0.0.1에만 묶였는지 0.0.0.0인지
3. `nc -zv localhost 15034` — 로컬에서 붙는지
4. 외부에서 안 되면 방화벽(ufw) 확인
5. 앱 로그 확인 (bind 실패, DB 대기로 멈춤 등)

보통 2번에서 거의 잡힌다. (127.0.0.1에만 묶였거나, 다른 게 포트를 먼저 잡았거나)

### 9.3 로그가 디스크를 채울 것 같으면

- 단기: `du`로 어디가 큰지 보고, 회전된 로그를 `gzip`으로 압축, 급하면 오래된 것부터 삭제, monitor.sh 주기를 5분으로 늘림.
- 중기: `log_retention.sh`의 보존 기간을 줄이고(7→3일 등), /var/log를 별도 볼륨으로 빼고, 로그가 왜 폭증했는지 원인을 찾는다.

이번 과제에는 `log_retention.sh`(보너스)로 7일 지난 로그 압축, 30일 지난 건 삭제까지 만들어 뒀다.

---

## 10. 체크리스트

| 항목 | 결과 |
| --- | --- |
| SSH 20022 + root 차단 | 통과 |
| UFW 20022/15034만 허용 | 통과 |
| 계정 3개 + 그룹 2개 | 통과 |
| 디렉토리/권한/ACL | 통과 |
| 환경변수 5개 | 통과 |
| 키 파일 내용 | 통과 |
| Boot 5/5 + Agent READY | 통과 |
| monitor.sh 출력 | 통과 |
| monitor.log 포맷 + 누적 | 통과 |
| 비정상 시 exit 1 | 통과 |
| 로그 10MB/10개 | 통과 |
| report.sh / log_retention.sh (보너스) | 통과 |

---

## 11. 정리

```bash
# 다 끝나면 컨테이너 정리
kyumin14040659@c6r10s7 Codyssey_B_1_1 % docker stop codyssey && docker rm codyssey
```
