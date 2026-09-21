# 실험 2: 전체 Pod 복구 승인 재검증

상태: **부분 검증** (2026-09-21).

기존의 `containers[0]` 및 호출자 제공 `spec-hash` 비교를 제거했다. `recovery-approval-v4` immutable ConfigMap은 CI 승인자가 만든 canonical JSON의 전체 Pod spec, labels, annotations를 보관하며, Kyverno가 제출된 값을 직접 비교한다. Kubernetes가 주입하는 ServiceAccount 토큰 volume으로 인해 승인이 흔들리지 않도록 fixture는 `automountServiceAccountToken: false`와 적용되는 기본 Pod 값을 명시한다.

## API-server 관측

`kind-ln-ssdf-e1`에서 `system:serviceaccount:experiment-2:ci-deployer`로 server dry-run을 수행했다.

- `recovery-approved-v4`: 허용.
- 같은 manifest에 unapproved sidecar 추가: `require-bound-recovery-approval`에 의해 거절.
- unapproved initContainer 추가: 같은 규칙에 의해 거절.
- `sidecar.istio.io/inject: "true"` annotation 추가: 같은 규칙에 의해 거절.

재현 시 현재 시각으로 발행하고 10분 이하 lease 및 현재 신뢰 상태를 갖는 **새 immutable approval record**를 사용해야 한다. 이전 record를 update하지 않는다. 이 결과는 Pod 계약 결속만 검증한다. approval issuer의 production RBAC, ArgoCD 상태, 감사 저장소, LN 결제 복구는 아직 연결하지 않았다.
