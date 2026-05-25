# 새 agent-app-linux 바이너리 적용 가이드

> 다운로드한 `agent-app.zip` 안의 두 바이너리(`agent-app-linux-x86`, `agent-app-linux-arm64`) 검증 결과와 변경된 spec, 그리고 즉시 따라 할 수 있는 적용 순서를 정리한 문서입니다.

---

## 1. 바이너리 정보

| 파일 | 아키텍처 | 크기 | 용도 |
| --- | --- | --- | --- |
| `agent-app-linux-x86` | **x86-64 / amd64** (이름은 "x86" 이지만 실제로는 64-bit) | 6.2 MB | 일반 Intel/AMD 서버, Docker Desktop on Windows/WSL, EC2 m/c/r 계열, GCP n/e 계열 등 |
| `agent-app-linux-arm64` | ARM64 / aarch64 | 7.2 MB | Apple Silicon Mac (M1~M4), AWS Graviton, Raspberry Pi 4/5, Ampere |

> `file` 명령으로 본 결과: x86 은 "ELF 64-bit LSB executable, x86-64, ... for GNU/Linux 3.2.0", arm64 는 "ELF 64-bit LSB executable, ARM aarch64, ... for GNU/Linux 3.7.0".
> 어느 쪽이든 **glibc 2.35(=22.04) 에서 그대로 동작** — 이전 바이너리가 요구하던 glibc 2.38 (24.04+) 의존성이 사라졌습니다.

`uname -m` 결과에 따라 고르세요:
- `x86_64` → `agent-app-linux-x86`
- `aarch64` / `arm64` → `agent-app-linux-arm64`

---

## 2. 새 바이너리에서 바뀐 spec (중요)

이전 바이너리와 비교하면 **3가지가 바뀌었습니다**. 셋 다 setup.sh 에 반영해서 패치 완료.

| 항목 | 이전 | 새 버전 |
| --- | --- | --- |
| **루트 실행** | 가능 (운영자 책임으로 금지) | **바이너리가 자체 차단** — `Running as 'root' is forbidden.` 메시지 + [FAIL] |
| **AGENT_KEY_PATH** | `…/api_keys/t_secret.key` (**파일** 경로) | `…/api_keys` (**디렉토리** 경로) |
| **키 파일명** | `t_secret.key` | `secret.key` |

증거: 빈 환경으로 실행했을 때 새 바이너리가 친절하게 알려줍니다.
```
[2/5] Verifying Environment Variables     [FAIL]
   >>> Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys
[3/5] Checking Required Files             [FAIL]
   >>> Missing File: secret.key
   >>>    (Expected location: /home/agent-admin/agent-app/api_keys/secret.key)
```

setup.sh 가 이미 위 3가지를 모두 반영하도록 패치되었습니다 (아래 §3 참고).

---

## 3. 적용 절차 — 교육장 PC (Docker 컨테이너) 기준

교육장 PC 는 일반 사용자 계정(sudo 없음)이므로, **호스트는 Docker 명령만 쓰고 미션은 컨테이너 안에서** 진행합니다.

### 3-A. 호스트 (Windows/macOS, sudo 불필요)

```powershell
cd C:\WorkSpace_2026\Codyssey_B_1_1     # 프로젝트 폴더

# 1) zip 풀고 본인 아키텍처의 바이너리만 같은 폴더에
Expand-Archive 'C:\Users\…\Downloads\agent-app.zip' .\_zip -Force
Copy-Item .\_zip\agent-app-linux-x86 .          # 또는 -arm64

# 2) Ubuntu 24.04 컨테이너 띄우기 (한 번만)
docker pull ubuntu:24.04
docker run -d --name codyssey --privileged --cgroupns=host `
  --tmpfs /tmp:exec --tmpfs /run --tmpfs /run/lock `
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw `
  -p 20022:20022 -p 15034:15034 `
  ubuntu:24.04 sleep infinity

# 3) 컨테이너 안 deps 설치 + 데몬 기동
docker exec codyssey bash -c '
  apt-get update && apt-get install -y --no-install-recommends \
    openssh-server ufw cron acl dos2unix iproute2 procps psmisc ca-certificates curl
  mkdir -p /run/sshd /root/work
  service ssh start ; service cron start
'

# 4) 파일들 docker cp 로 컨테이너 안으로
docker cp .\monitor.sh         codyssey:/root/work/
docker cp .\report.sh          codyssey:/root/work/
docker cp .\log_retention.sh   codyssey:/root/work/
docker cp .\setup.sh           codyssey:/root/work/
docker cp .\agent-app-linux-x86 codyssey:/root/work/

# 5) 라인엔딩 + 실행 비트 정리
docker exec codyssey bash -c 'cd /root/work && dos2unix *.sh && chmod +x *.sh agent-app-linux-x86'
```

### 3-B. 컨테이너 안 (root 셸 — sudo 무관)

```bash
docker exec -it codyssey bash
cd /root/work

# 1) 일괄 프로비저닝 (setup.sh 가 받은 첫 인자를 ${AGENT_HOME}/agent-app 으로 install)
bash setup.sh ./agent-app-linux-x86

# 2) 앱 기동 (백그라운드)
su - agent-admin -c 'cd $AGENT_HOME && ./agent-app' &
sleep 4
# >>> Starting Agent Boot Sequence...
# [1/5] ~ [5/5] 모두 [OK] + Agent READY     ← 여기 보이면 성공

# 3) monitor 수동 1회 + cron 누적 확인
su - agent-admin -c '/home/agent-admin/agent-app/bin/monitor.sh'
sleep 70 && tail -3 /var/log/agent-app/monitor.log

# 4) 검증
crontab -u agent-admin -l                    # cron 룰
ss -tulnp | grep -E ':(20022|15034)\b'       # 두 포트만 LISTEN
ufw status                                   # 방화벽 활성

exit   # 컨테이너 셸 나오기
```

### 3-C. 산출물 회수 + 정리

```powershell
# 컨테이너 안 로그/증거를 호스트로 회수
docker exec codyssey crontab -u agent-admin -l        > evidence\09-cron.txt
docker exec codyssey cat /var/log/agent-app/monitor.log > evidence\monitor.log

# 작업 끝나면 정리
docker stop codyssey ; docker rm codyssey
```

### 핵심 포인트 — `setup.sh` 인자
- `setup.sh` 는 **첫 인자를 받아서 그대로 `$AGENT_HOME/agent-app` 으로 설치**합니다.
- 즉, `bash setup.sh ./agent-app-linux-x86` 이라고 호출해도 결과적으로 `/home/agent-admin/agent-app/agent-app` 으로 들어갑니다. → **monitor.sh 의 `pidof agent-app` 가 그대로 동작.**
- 따라서 `AGENT_PROC` 환경변수 같은 걸 override 할 필요 없습니다.

---

## 4. 이미 setup.sh 를 한 번 돌린 상태에서 새 바이너리로 갈아끼우기

이전 바이너리로 한 번 설치했고 그 위에 새 바이너리를 덮어쓰는 경우 (컨테이너 안 root 셸에서, sudo 무관):

```bash
# (1) 새 바이너리 docker cp 로 컨테이너 안에 가져온 뒤
docker cp ./agent-app-linux-x86 codyssey:/root/agent-app-linux-x86
docker exec -it codyssey bash    # 컨테이너 진입

# (2) 새 바이너리 교체 (sudo 없이 — 이미 root)
install -o agent-admin -g agent-core -m 750 \
  /root/agent-app-linux-x86 \
  /home/agent-admin/agent-app/agent-app

# (3) 키 파일 이름 변경 (t_secret.key -> secret.key)
mv /home/agent-admin/agent-app/api_keys/t_secret.key \
   /home/agent-admin/agent-app/api_keys/secret.key
ln -sf secret.key /home/agent-admin/agent-app/api_keys/t_secret.key  # 호환 심볼릭 링크

# (4) AGENT_KEY_PATH 를 디렉토리로 변경
sed -i 's|/api_keys/t_secret.key|/api_keys|' /etc/profile.d/agent-app.sh

# (5) 재로그인(=su -) 후 부팅 → profile 재로드
su - agent-admin -c 'cd $AGENT_HOME && ./agent-app'
```

---

## 5. 검증 결과 (실제 캡처)

방금 Ubuntu 22.04 컨테이너에서 위 절차대로 처음부터 다시 돌린 결과:

| 항목 | 결과 |
| --- | --- |
| Boot Sequence 5/5 [OK] + "Agent READY" | ✅ ([07-boot.png](screenshots/07-boot.png)) |
| `pidof agent-app` / `pgrep -x agent-app` 둘 다 매칭 | ✅ (comm 이 자동으로 `agent-app`) |
| `0.0.0.0:15034 LISTEN` | ✅ |
| `monitor.sh` happy path (Health/Firewall/Resource/Threshold/Logging) | ✅ ([08-monitor.png](screenshots/08-monitor.png)) |
| `monitor.sh` 비정상 종료 `exit 1` | ✅ ([12-monitor-fail.png](screenshots/12-monitor-fail.png)) |
| cron 매분 누적 | ✅ ([09-cron.png](screenshots/09-cron.png)) |
| report.sh / log_retention.sh | ✅ ([10-report.png](screenshots/10-report.png), [11-retention.png](screenshots/11-retention.png)) |

새 바이너리는 진짜 워크로드 사이클(메모리 25MB씩 누적 증가, CPU level 1→10)을 돌려서 **`monitor.sh` 의 MEM 임계치(10%)가 자연스럽게 트리거**됩니다. 임계치 알림이 동작함을 spec mockup 이 아닌 실제 데이터로 증명할 수 있는 부분.

---

## 6. 트러블슈팅

### Q1. `Running as 'root' is forbidden.` 가 나옵니다
**원인**: 새 바이너리가 root 실행을 자체 차단함.
**해결**: 반드시 `sudo -iu agent-admin bash -lc '...'` 또는 `su - agent-admin -c '...'` 로 일반 사용자 컨텍스트에서 실행.

### Q2. `Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys`
**원인**: `AGENT_KEY_PATH` 가 파일 경로(`.../t_secret.key`)로 설정되어 있음. 이전 spec.
**해결**: `/etc/profile.d/agent-app.sh` 에서 디렉토리로 변경 (`AGENT_KEY_PATH=$AGENT_HOME/api_keys`). 새 setup.sh 는 이미 적용됨.

### Q3. `Missing File: secret.key`
**원인**: 키 파일이 `t_secret.key` 로만 있음.
**해결**:
```bash
sudo mv /home/agent-admin/agent-app/api_keys/t_secret.key \
        /home/agent-admin/agent-app/api_keys/secret.key
```

### Q4. ARM 머신(Apple Silicon, Graviton 등)인데 x86 으로 받은 경우
바이너리 실행 시 `Exec format error` 또는 `cannot execute binary file`.
**해결**: `agent-app-linux-arm64` 를 사용. 그 외엔 절차 동일.

### Q5. `monitor.sh` 가 `[FAIL] process 'agent-app' is not running` 인데, 실행한 적이 있음
**확인 순서**:
1. `ps -ef | grep agent-app` — 프로세스가 진짜 있나
2. `pidof agent-app` — comm 매칭 되나
3. 백그라운드 실행했으면 부모 셸이 죽으면서 자식도 같이 죽었을 수 있음. `nohup` 또는 `systemd-run` 으로 detach.

---

## 7. 평가문항 답변서에 추가할 한 줄 (선택)

만약 시험에서 "이전 바이너리와 새 바이너리의 spec 차이를 설명할 수 있는가?" 라고 묻는다면:

> 새 `agent-app-linux` 바이너리는 (1) 루트 실행을 자체 차단하여 운영자 실수를 방지하고, (2) `AGENT_KEY_PATH` 를 디렉토리로 받아 키 파일 이름을 spec(`secret.key`)에 고정함으로써 환경변수 오타로 인한 장애 가능성을 줄였습니다. (3) glibc 의존성도 2.38 → 2.35 로 낮춰 22.04 호환성을 확보했습니다. setup.sh 는 첫 인자를 `$AGENT_HOME/agent-app` 으로 install 하므로, 바이너리 이름이 `agent-app-linux-x86` 이어도 monitor.sh 의 `pidof agent-app` 가 그대로 매칭됩니다.
