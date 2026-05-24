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

## 실행 순서 (권장)

```bash
# 0. 파일을 리눅스 VM 의 작업 디렉토리에 모두 복사
#    (agent-app 바이너리도 같은 폴더에 둡니다)
cd ~/work/agent-app-mission
ls
# agent-app  monitor.sh  report.sh  log_retention.sh  setup.sh  요구사항_수행_내역서.md

# 1. 일괄 프로비저닝 (idempotent — 재실행 안전)
sudo bash setup.sh ./agent-app

# 2. 새 SSH 포트로 재접속해서 격리 위험 검증
exit
ssh -p 20022 agent-admin@<host>

# 3. 앱 부팅 (별도 터미널에서)
cd $AGENT_HOME && ./agent-app          # 5/5 [OK] + Agent READY 까지 확인 후 그대로 둠

# 4. 첫 모니터 실행 (수동 1회)
$AGENT_HOME/bin/monitor.sh

# 5. cron 자동 누적 확인 (1~2 분 대기)
tail -F /var/log/agent-app/monitor.log

# 6. (보너스) 통계
$AGENT_HOME/bin/report.sh
$AGENT_HOME/bin/report.sh "2026-05-15 14:00:00" "2026-05-15 14:30:00"

# 7. (보너스) 보존 정책 테스트
sudo touch -d '8 days ago' /var/log/agent-app/sample-old.log
sudo $AGENT_HOME/bin/log_retention.sh
ls /var/log/monitor/agent-app/archive/
```

## 직접 셋업하고 싶다면 (setup.sh 우회)

`요구사항_수행_내역서.md` 의 1~5번 섹션이 곧 단계별 명령어 모음입니다. 그대로 복사·실행해도 동일한 상태가 됩니다.

## 주의

* `setup.sh` 는 `ufw --force reset` 으로 기존 UFW 룰을 모두 지웁니다. 다른 서비스가 돌고 있는 박스에는 그대로 쓰지 마세요.
* SSH 포트 reload 직후 **반드시 새 세션을 열어 재접속이 되는지** 확인한 뒤에야 기존 세션을 닫으세요.
* `monitor.sh` 를 cron 으로 돌릴 때 환경 변수는 cron 라인에 직접 명시했습니다 (cron 은 `/etc/profile.d/*.sh` 를 자동 로드하지 않음).
