# Phase 1: Vault, transit auto-unseal, VSO와 동적 DB credential

Phase 1은 Phase 0의 PostgreSQL bootstrap superuser를 애플리케이션 경로에서 제거한다. `lnd`에는 VSO가 동기화한 1시간 renewable PostgreSQL lease만 제공한다.

## 구성 계약

- `unsealer-vault`: Raft PVC를 가진 일반 Vault다. 최초 기동과 복구에서 Git 밖의 Shamir key로 수동 unseal한다.
- `main-vault`: 별도 Raft PVC를 가진 Vault다. unsealer의 transit key와 최소 권한 periodic token으로 auto-unseal한다.
- main의 transit token은 `vault-system/main-vault-transit` runtime Secret에만 있다. unsealer root token은 이 Secret이나 Git에 넣지 않는다.
- VSO 1.5.1은 Kubernetes auth로 `database/creds/lnd`만 읽으며, `ssdf-system/lnd-db-credential`을 `username`과 `password` 키만 가진 Secret으로 동기화한다.
- `lnd_runtime`은 non-login Postgres role이고, lease principal만 그 멤버가 된다. bootstrap `postgres` 계정은 Vault database plugin 설정에만 사용된다.
- Vault의 `lnd`와 `postgres-observability` database role은 `renew_statements`로 PostgreSQL `VALID UNTIL`도 갱신한다. Vault lease가 갱신돼도 DB 역할의 만료 시각이 연장되지 않으면 실제 로그인은 실패한다.
- VSO는 Secret 데이터가 바뀌면 `lnd-primary` StatefulSet과 `postgres-exporter` Deployment를 재시작한다. 두 workload가 Secret을 환경변수로 읽어 실행 중에는 새 값을 다시 읽지 못하기 때문이다. Argo CD는 해당 VSO 재시작 주석만 diff/sync에서 제외한다.

## Bootstrap

`STATE_DIR`은 저장소 밖의 새 디렉터리여야 한다. `unsealer-init.json`과 `main-init.json`에는 root token과 recovery key가 있으므로 0600 권한을 유지하고 백업 매체를 분리한다.

로컬 환경을 완전히 새로 만들 때는 기존 regtest 체인, Vault, wallet, channel 상태를
삭제하고 새 recovery material과 Raft snapshot을 생성한다. 다음 명령은 명시적으로
`ln-ssdf-phase0` kind cluster만 대상으로 하며, Phase 0부터 Phase 8까지의 bootstrap을
순서대로 검증한다.

```bash
scripts/fresh-local-bootstrap.sh \
  --state-dir "$HOME/.local/state/ln-ssdf-phase1" \
  --confirm-recreate
```

```bash
STATE_DIR="$HOME/.local/state/ln-ssdf-phase1"
scripts/phase1-bootstrap.sh \
  --context kind-ln-ssdf-phase0 \
  --state-dir "$STATE_DIR"
scripts/phase1-verify.sh \
  --context kind-ln-ssdf-phase0 \
  --state-dir "$STATE_DIR"
```

Bootstrap은 idempotent다. 이미 생성된 recovery file을 재생성하지 않으며, unsealer가 sealed인 경우에만 threshold 수만큼의 Shamir key를 제출한다.

## 검증 범위와 복구 드릴

검증은 다음을 실제로 확인한다.

- unsealer Raft persistence와 manual unseal
- main Vault를 seal·Pod 재생성한 뒤 transit auto-unseal
- VSO `Ready`, 3600초 renewable database lease, 동기화 Secret의 Postgres `lnd` 로그인
- Phase 2의 `scripts/phase2-db-rotation-drill.sh`에서 자동 갱신 시 DB 역할 만료 연장, 최대 TTL 후 Secret 회전과 LND 재시작, 원래 1시간 lease 복원, 결제 재성공
- 별도 10초 dynamic credential의 로그인 성공 후 만료 거부
- kind cluster와 Vault PVC를 삭제한 뒤 unsealer snapshot 수동 복원 → main snapshot transit auto-unseal → VSO 재동기화

kind 전체 삭제 복구에는 unsealer와 main의 Raft snapshot 및 이 state directory가 모두 필요하다. `scripts/phase1-backup.sh`로 두 snapshot을 먼저 만든 뒤 `scripts/phase1-rebuild-drill.sh --state-dir "$STATE_DIR"`를 실행한다. 이 드릴은 destructive이며 `ln-ssdf-phase0`만 삭제한다.

2026-09-21에 실제 드릴을 통과했다. 복원 후 새 PostgreSQL bootstrap password를 Vault database plugin에 재설정했다. lnd의 채널·결제 상태 복구는 아직 존재하지 않으므로 Phase 2의 별도 복구 검증 범위다.
