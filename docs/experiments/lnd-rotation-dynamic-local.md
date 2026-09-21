# 실험 3: 동적 PostgreSQL lease와 VSO

상태: **부분 검증 완료** (2026-09-21). 동적 lease를 사용한 실제 lnd 재기동·양방향 결제 경로는 완료했지만, Vault가 in-memory dev storage이므로 운영 Vault의 내구성/자동 unseal 검증까지 완료한 것은 아니다.

기존 static credential fixture와 구분해 Vault database secrets engine의 dynamic role `lnd-dynamic`을 만들었다. 최초 만료/revoke 검증에는 20초 TTL을 썼고, 실제 lnd 기동에는 기본 5분·최대 10분 lease를 사용했다. Vault AppRole은 `database/creds/lnd-dynamic` read 권한만 가지며, VSO는 그 role로 Kubernetes `lnd-db-credential` Secret을 동기화한다.

## 관측

- 직접 발급한 dynamic credential은 PostgreSQL `select 1` 인증에 성공했다.
- 20초 lease가 만료된 뒤 같은 credential의 PostgreSQL login은 거절됐다.
- 별도 lease를 `vault lease revoke`한 직후 같은 login은 거절됐다.
- VSO가 동기화한 `lnd-db-credential`의 username/password는 PostgreSQL 인증에 성공했다.
- VSO는 50% 시점 renewal을 시도했다. max TTL 때문에 `SecretLeaseRenewalError` (`renewal duration was truncated`)가 기록됐고, controller는 새 lease를 발급해 Secret을 다시 동기화했다. 초기 20초 창을 넘긴 25초 뒤에도 동기화 Secret으로 PostgreSQL 인증에 성공했다.
- 재기동 후 새 lease를 발급했고 VSO `VaultDynamicSecret`은 `Healthy/Ready/Synced`, 300초 renewable lease 상태였다. 동기화 Secret의 값을 로컬 Docker 실험 오케스트레이션이 주 lnd의 PostgreSQL DSN으로 전달했다.
- 주 lnd는 VSO가 발급한 동적 PostgreSQL principal으로 빈 `lnd_dynamic` 데이터베이스에 기동했다. lnd의 스키마 migration이 소유자 권한을 요구하므로, 실험용 non-login `lnd_runtime` 소유자 그룹을 만들고 매 lease principal을 그 그룹의 멤버로 부여했다.
- 주 lnd에 regtest 자금을 공급해 1,000,000 sat 채널(초기 push 500,000 sat)을 열었다. 활성 채널에서 주 lnd → peer 10,000 sat, peer → 주 lnd 7,000 sat invoice 결제가 각각 `SUCCEEDED`였다.

## 제한

이 검증의 Vault는 in-memory dev storage다. 또한 lnd는 Docker에 있고 VSO Secret은 Kubernetes에 있으므로, Secret을 lnd Pod에 직접 mount하는 production rollout controller가 아니라 로컬 실험 오케스트레이션이 Secret 값을 기동 DSN으로 전달했다. 따라서 동적 credential 발급·만료·revoke·VSO reissue·동적 principal을 사용한 lnd 재기동·양방향 결제는 증명하지만, persistent file-storage/manual-unseal Vault 및 실제 배포 rollout controller가 Secret 변경을 소비하는 단일 production 경로는 아직 증명하지 않는다. production 설정은 [vault.hcl](../../experiments/lnd-rotation/vault.hcl)에 보존한다.
