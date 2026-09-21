# Phase 0: kind와 PostgreSQL bootstrap

이 단계는 Phase 1 Vault 전환 전의 로컬 bootstrap 환경이다. `charts/postgres`의 password는 install 시에만 전달하며, 값·Secret manifest·shell history를 Git에 보관하지 않는다. 이 정적 bootstrap credential은 Phase 1에서 Vault database secrets engine의 단명 credential로 교체된다.

## 계약

- `local/kind-config.yaml`은 control-plane 1대와 worker 2대로 `ln-ssdf-phase0` kind cluster를 만든다.
- Helm release `ssdf`, namespace `ssdf-system`은 `ssdf-postgres` StatefulSet과 `data-ssdf-postgres-0` PVC를 만든다.
- 초기화 SQL은 `lnd`와 `ssdf` 데이터베이스를 만든다. `db/schema.sql`은 `ssdf`에만 적용한다.
- schema는 evidence append-only trigger와 `phase0-v1` migration marker를 포함한다. Rekor는 권위 저장소이며 Postgres는 조회용 projection이다.

## 로컬 실행

```bash
kind create cluster --config local/kind-config.yaml
read -r -s -p 'Bootstrap PostgreSQL password: ' SSDF_BOOTSTRAP_PASSWORD
printf '\n'
helm upgrade --install ssdf charts/postgres \
  --kube-context kind-ln-ssdf-phase0 \
  --namespace ssdf-system --create-namespace \
  --set-string auth.bootstrapPassword="$SSDF_BOOTSTRAP_PASSWORD" \
  --wait --timeout 180s
scripts/phase0-verify.sh --context kind-ln-ssdf-phase0
unset SSDF_BOOTSTRAP_PASSWORD
```

`phase0-verify.sh`는 명시적 kube context만 받는다. ambient context를 쓰지 않으므로 로컬 명령이 다른 클러스터에 잘못 적용되지 않는다. 이미 `phase0-v1` marker가 있는 schema는 재적용하지 않는다. 이후 schema 변경은 이 파일을 덮어쓰지 말고 명시적 migration으로 추가한다.

## 삭제·재생성 드릴

Phase 0 완료는 기존 kind 볼륨·Helm release·Postgres 데이터를 전혀 쓰지 않는 재생성도 포함한다. `ln-ssdf-phase0`만 삭제한다. 다른 kind 클러스터에는 적용하지 않는다.

```bash
kind delete cluster --name ln-ssdf-phase0
kind create cluster --config local/kind-config.yaml --wait 120s
read -r -s -p 'Bootstrap PostgreSQL password: ' SSDF_BOOTSTRAP_PASSWORD
printf '\n'
helm upgrade --install ssdf charts/postgres \
  --kube-context kind-ln-ssdf-phase0 \
  --namespace ssdf-system --create-namespace \
  --set-string auth.bootstrapPassword="$SSDF_BOOTSTRAP_PASSWORD" \
  --wait --timeout 180s
scripts/phase0-verify.sh --context kind-ln-ssdf-phase0
unset SSDF_BOOTSTRAP_PASSWORD
```

이 드릴은 2026-09-21에 통과했다. 공통 규칙과 다음 Phase의 재생성 범위는 [AI handoff의 Phase 검증 게이트](../AI-HANDOFF.md#phase-검증-게이트-통과-못-하면-다음으로-넘어가지-마라)를 따른다.
