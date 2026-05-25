# Codyssey B_1_1 — 시스템 관제 자동화 스크립트

리눅스 서버에 `agent-app` 을 배포하고, 보안 / 권한 / 환경 / 자동 모니터링까지 일관되게 셋업하기 위한 Bash 스크립트 세트입니다.

## 파일 목록

| 파일 | 역할 |
| --- | --- |
| `monitor.sh` | **(필수)** 매분 실행. 프로세스/포트/방화벽/자원 점검 → `/var/log/agent-app/monitor.log` 누적. |
| `report.sh` | **(보너스 1)** `monitor.log` 분석 → CPU/MEM/DISK 평균·최대·최소·샘플 수. |
| `log_retention.sh` | **(보너스 2)** 7일 경과 로그 압축 + 30일 경과 아카이브 삭제. |
| `setup.sh` | **(편의)** SSH·UFW·계정·그룹·디렉토리·ACL·환경변수·cron 일괄 구성 (재현용). |
| `요구사항_수행_내역서.md` | **(필수 제출)** 명령어 + 증거 캡처 슬롯이 포함된 보고서 양식. |

## 실행 순서 (권장 — Docker 컨테이너 기반)

교육장 PC가 일반 사용자 계정(sudo 없음)이므로, **호스트에서 Docker 컨테이너만 띄우고 미션 본 작업은 컨테이너 안에서** 진행합니다. 자세한 명령은 [`평가문항_답변.md`](평가문항_답변.md#부록-b--교육장-pc-실행-절차-docker-컨테이너) 부록 B 참고.

### 호스트에서 (Windows/macOS, sudo 불필요)

```powershell
# 1. 컨테이너 기동
docker pull ubuntu:24.04
docker run -d --name codyssey --privileged --cgroupns=host `
  --tmpfs /tmp:exec --tmpfs /run --tmpfs /run/lock `
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw `
  -p 20022:20022 -p 15034:15034 `
  ubuntu:24.04 sleep infinity

# 2. deps + 데몬 + 파일 복사
docker exec codyssey bash -c '
  apt-get update && apt-get install -y --no-install-recommends \
    openssh-server ufw cron acl dos2unix iproute2 procps psmisc ca-certificates curl
  mkdir -p /run/sshd /root/work
  service ssh start ; service cron start
'
docker cp ./monitor.sh         codyssey:/root/work/
docker cp ./report.sh          codyssey:/root/work/
docker cp ./log_retention.sh   codyssey:/root/work/
docker cp ./setup.sh           codyssey:/root/work/
docker cp ./agent-app-linux-x86 codyssey:/root/work/
docker exec codyssey bash -c 'cd /root/work && dos2unix *.sh && chmod +x *.sh agent-app-linux-x86'
```

### 컨테이너 안에서 (root 셸 — sudo 무관)

```bash
docker exec -it codyssey bash
cd /root/work

# 1. 일괄 프로비저닝 (sudo 없이 — 이미 root)
bash setup.sh ./agent-app-linux-x86

# 2. 앱 기동 (백그라운드)
su - agent-admin -c 'cd $AGENT_HOME && ./agent-app' &
# 5/5 [OK] + Agent READY 까지 확인

# 3. monitor.sh 1회 수동
su - agent-admin -c '/home/agent-admin/agent-app/bin/monitor.sh'

# 4. cron 자동 누적 확인 (1~2 분 대기)
tail -F /var/log/agent-app/monitor.log

# 5. (보너스 1) 통계
su - agent-admin -c '/home/agent-admin/agent-app/bin/report.sh'

# 6. (보너스 2) 보존 정책 테스트
touch -d '8 days ago' /var/log/agent-app/sample-old.log
/home/agent-admin/agent-app/bin/log_retention.sh
ls /var/log/monitor/agent-app/archive/
```

### 호스트로 산출물 회수

```powershell
docker exec codyssey crontab -u agent-admin -l        > evidence/09-cron.txt
docker exec codyssey cat /var/log/agent-app/monitor.log > evidence/monitor.log
docker stop codyssey ; docker rm codyssey             # 정리
```

## 직접 셋업하고 싶다면 (setup.sh 우회)

`요구사항_수행_내역서.md` 의 1~5번 섹션이 곧 단계별 명령어 모음입니다. 그대로 복사·실행해도 동일한 상태가 됩니다.

## 주의

* `setup.sh` 는 `ufw --force reset` 으로 기존 UFW 룰을 모두 지웁니다. 컨테이너 안이라 안전하지만, 실서버에 그대로 쓰지 마세요.
* `monitor.sh` 를 cron 으로 돌릴 때 환경 변수는 cron 라인에 직접 명시했습니다 (cron 은 `/etc/profile.d/*.sh` 를 자동 로드하지 않음).
* `--privileged` + cgroup 마운트는 UFW(iptables) 가 컨테이너 안에서 정상 동작하기 위해 필요합니다. `--tmpfs /tmp:exec` 는 PyInstaller 가 /tmp 에 라이브러리를 펼치고 실행하기 위해 필요.
* 컨테이너 셸을 끊으면 `service ssh / cron` 데몬은 계속 살아 있습니다 (`docker stop` 해야 진짜 멈춤).
