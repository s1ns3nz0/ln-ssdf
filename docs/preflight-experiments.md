# 선행 실험

목적은 [합의한 설계](design-decisions.md)의 네 가지 구현 의존성을 실제 동작으로 검증하는 것이다. 실험 1은 **통과**, 실험 2~4는 아래의 통합 조건을 충족해야 통과로 표시한다. GHCR·keyless·Rekor는 로컬 fixture의 범위 밖이다.

## 확인한 환경

2026-09-21 확인: Docker는 Linux daemon으로 실행 중이다. kind·kubectl·Helm·cosign이 설치되어 있고 로컬 kind 클러스터는 없다. 기존 kubectl context는 EKS이므로 실험에는 사용하지 않는다. 실험용 kubeconfig를 작업공간 내부에 별도로 만들고 모든 명령에서 명시한다. Manyfast MCP 등록·OAuth 인증·기획서 업로드는 완료했으며 실제 화면은 아직 미구현이다.

## 1. 별도 OCI 저장소의 SBOM·VSA 검증

- 이미지 digest와 VSA 저장소를 분리한다. 우선 로컬 OCI 레지스트리에서 형식·경로를 확인하고 최종적으로 프로젝트 GHCR에서 검증한다. 로컬 성공만으로 GHCR·keyless·Rekor 통합 성공을 주장하지 않는다.
- 도구 버전, 이미지 digest, predicate 형식, 서명 identity, 저장 위치, 정책을 기록한다.
- Trivy CycloneDX SBOM → cosign attestation → GHCR 저장 → 이미지 digest·SBOM 해시를 연결한 취약점 보고서·VSA 검증을 포함한다. 자체 코드의 소스·lockfile SBOM은 Git 커밋 연결도 확인한다.
- SBOM 형식 오류·분석 실패·필수 분석 범위 누락·잘못된 digest·서명 위조를 각각 거절하는지 확인한다. 알려진 패키지가 들어 있는 독립 fixture로 누락을 검출하고 스캐너 성공 종료만으로 품질 통과를 판정하지 않는다.
- 취약점 DB 발행 후 48시간 경계, 갱신 실패 시 유효한 캐시 사용, 검사 미완료, 일일 재검사에서 새 차단 취약점이 확인되는 경로를 검증한다. 실제 외부 DB를 조작하지 않고 고정 fixture·주입 가능한 시각으로 경계 테스트를 수행하며 실제 통합 실행과 구분해 기록한다.
- 정상 VSA는 허용한다. 누락, 잘못된 digest, 신뢰하지 않는 서명자, 만료, 실패 판정, 조회 장애는 차단해야 한다.
- 실제 Kyverno admission 결과를 확인한다. cosign 검증 성공 또는 문서상 지원만으로 통과시키지 않는다. 검증 캐시가 만료·철회 처리를 숨기는지도 확인한다.
- 참고: [Kyverno API의 Repository 필드](https://pkg.go.dev/github.com/kyverno/kyverno/api/kyverno/v1), [Cosign 별도 저장소](https://github.com/sigstore/cosign#specifying-registry-location-for-signatures).

## 2. 승인 기록을 이용한 장애 복구 예외

상태: **부분 검증 (로컬 kind admission fixture)**. 기존 fixture는 첫 컨테이너와 호출자 annotation만 비교했으므로 전체 Pod 결속을 보장하지 못했다. 이제 CI 발행 불변 ConfigMap의 전체 Pod spec·labels·annotations와 요청자를 비교한다. 지정 CI ServiceAccount의 정확한 Pod는 API server가 허용했고, sidecar·initContainer·주입 annotation 변조는 거절했다. 재현 명령과 관측 결과는 [복구 승인 기록](experiments/recovery-approval-local.md)에 남겼다. 승인 발행자의 실제 CI 파이프라인 RBAC·ArgoCD·감사 저장소·LN 결제는 이 fixture 범위 밖이므로 전체 통과가 아니다.

- 승인 저장소 쓰기 주체, 요청자 신원, 대상 워크로드·namespace, digest, 명세 해시, 정책 버전을 검증한다. 사용자 annotation만으로 승인으로 취급하지 않는다.
- 만료 전 신규 배포를 승인한 후 증거를 만료시킨다. 현재 신뢰 상태가 유효하고 추가 차단 사유가 없을 때만 기존 승인 설정의 재생성을 허용한다. 실행 중인 Pod는 유지한다.
- 새 digest·설정 변경·위조 승인·다른 워크로드의 승인 재사용·신뢰 철회는 차단해야 한다.
- Secret 참조·Vault 역할·권한 변경은 재승인 대상이며 비밀 값 자체는 명세 해시에 포함하지 않는다. 동일 역할·권한 내 자격증명 교체와 설정 변조를 구분한다. Kubernetes가 생성하는 필드 및 ConfigMap 내용을 처리하는 정규화 계약은 fixture 작성 시 구체화한다.
- 지정 CI identity만 배포 승인을 발행할 수 있어야 한다. 수집기 증거 서명을 승인 서명으로 재사용하는 공격은 거절한다. 승인 발행 직전 증거 TTL과 대상 커밋을 재확인한다. admission은 증거 TTL 자체가 아니라 변경 불가 대상에 묶인 최대 10분 execution lease와 1분 이내의 현재 신뢰 상태를 확인한다.
- 정책 변경·차단 취약점 확인 시 과거 승인 재사용을 거절한다. 차단 상태 반영 지연의 상한은 1분이며 신뢰 상태 자체가 1분 넘게 갱신되지 않으면 복구 예외도 거절한다. 캐시를 켠 상태에서 실제 경과 시간으로 확인한다.
- 배포 전후 ArgoCD 검사를 분리한다. 정상 전환 차이와 무단 drift, 최대 10분의 배포 후 검사, **발행 시에는 유효했으나 5분 ArgoCD 스냅샷이 만료한 뒤의 지연 Pod 생성**, lease 만료와 신뢰 상태 만료의 거절, 배포 직렬화, 실패한 배포를 참조하는 복구 배포를 확인한다. LN·DB 배포는 양방향 결제 성공도 필요하다.
- 실제 API 서버에서의 허용·거절과 감사 기록을 판정 기준으로 삼는다. 자체 판정 함수 테스트만으로 admission 검증 완료를 주장하지 않는다.

## 3. lnd Postgres 자격증명 교체

상태: **부분 검증 완료 (로컬 regtest/Vault/VSO fixture)**. regtest bitcoind, Postgres 주 lnd, bbolt 상대 lnd에서 채널과 양방향 결제를 확인했다. `lnd_old`에서 `lnd_new`로 소유권·자격증명을 전환하고 주 lnd를 재시작한 뒤 양방향 결제를 다시 성공시켰으며, `lnd_old`는 `NOLOGIN` 뒤 새 DB 연결이 거절됐다. 기존 static credential 전환 기록과 별도로, Vault database secrets engine의 20초 **dynamic** lease를 발급해 Postgres 접속, 만료 후 거절, 명시 revoke 후 거절을 확인했다. AppRole VSO는 같은 dynamic credential을 Kubernetes Secret으로 동기화했고, max-TTL로 renewal이 잘린 경우 새 lease를 재발급해 Secret을 동기화한 뒤에도 Postgres 접속이 유지됐다. Docker 재기동 후에는 database plugin을 Docker DNS 이름으로 연결해 VSO `Healthy/Ready/Synced`를 복구했고, 새 5분 dynamic lease를 주 lnd의 PostgreSQL DSN으로 전달해 재기동했다. 새 1,000,000 sat 채널에서 주→상대 10,000 sat 및 상대→주 7,000 sat 결제가 모두 성공했다. 자세한 관측은 [동적 lease 기록](experiments/lnd-rotation-dynamic-local.md)에 남겼다. 이 dynamic 검증은 in-memory Vault와 Docker lnd에 대한 로컬 Secret 전달로 수행했으므로 persistent file-storage/manual-unseal Vault와 실제 배포 rollout controller가 Secret을 직접 소비하는 단일 통합 경로는 아직 전체 통과가 아니다. 운영 Vault HA·자동 unseal은 별도 통합 범위다.

- regtest bitcoind, 주 lnd(Postgres), 상대 lnd(bbolt)를 준비한다. Vault 발급 자격증명을 주 노드에 전달하고 채널을 개설해 양방향 결제를 확인한다.
- 새로운 DB 자격증명을 발급해 반영한 뒤 주 노드를 계획 재시작한다. 새 DB 연결과 실제 양방향 결제 성공을 확인한다.
- 새 계정 발급·권한 확인 후 전환하고 결제 성공 뒤 기존 계정을 폐기한다. 실패 시 아직 유효한 기존 계정으로 되돌리는 경로와 이전 계정이 만료되어 롤백할 수 없는 경로를 각각 확인한다.
- 이전 자격증명으로 새 연결이 실패하는지 확인한다. 기존 연결 재사용을 자격증명 교체 성공으로 오인하지 않는다.
- 실패 경로: Vault 사용 불가, 잘못된 자격증명, 갱신 지연, 새 역할의 기존 테이블·시퀀스 권한 부족. 측정값은 복구 시간, 결제 결과, 이전 자격증명 거절 여부다.
- 정적 계정 두 개로 먼저 확인하는 경우 부분 실험으로만 기록한다. Vault·VSO·임대 만료까지 확인해야 전체 경로를 검증한 것이다.

## 4. 단일 요구사항의 OSCAL 연결

상태: **부분 검증 (로컬 OSCAL·C2P·Postgres fixture)**. OSCAL 1.2.3 Catalog, Profile, Component Definition, SSP, Assessment Plan, Assessment Results의 schema 검증과 `DEPLOY-REQ-4` 문서 간 trace, 실제 실험 1 VSA 파일 참조, 프로젝트 5상태 확장 매핑을 확인했다. C2P 0.5.0 Kyverno plugin으로 PolicyReport를 Assessment Results로 변환하고, 그 결과를 `ssdf_experiment4.oscal_requirement_projection`에 적재·조회했다. 이 PolicyReport는 이미 존재하는 resource의 평가 결과이므로 wrong-subject create 거절의 증거로 사용하지 않는다. 현재 Kyverno `scope` 필드와 C2P의 옛 `resources` 필드, 빈 control selection·placeholder Assessment Plan URL은 호환 adapter로 명시적으로 보완했다. runner는 `--c2p-root` 또는 `C2P_ROOT`로 지정한 pinned Linux checkout만 사용하며 개발자 절대 경로에 의존하지 않는다. Manyfast 조회 화면은 이 세션에 MCP 도구가 노출되지 않아 아직 실행하지 않았으므로 전체 통과로 표시하지 않는다.

- 실험 1의 이미지 검증 결과를 사용한다. DEPLOY-REQ-4에 연결할 세부 검사 하나를 선정하고 원문·적용 범위·평가 기준을 명시한다. 세부 검사 통과만으로 전체 요구사항을 충족했다고 표시하지 않는다.
- 버전을 고정한 Catalog·Profile·Component Definition·최소 SSP·Assessment Plan·Assessment Results를 준비하고 스키마 및 문서 간 참조를 검증한다. 이는 프로젝트 작성 콘텐츠이며 NIST 공식 Catalog라고 표시하지 않는다.
- C2P 예제를 바탕으로 통제·검사·Kyverno 정책의 ID 연결과 필요한 템플릿을 구현한다. 실제 Kyverno 결과를 Assessment Results로 변환한다. 생성 JSON이 스키마를 통과한 것만으로 실행 정책 검증을 대체하지 않는다.
- C2P 정책 생성 경로와 결과 변환 경로의 호환성 결과를 각각 기록한다. 선택한 검사에서 생성·실행·변환 중 하나가 실패하면 C2P 전체 연동은 통과로 표시하지 않는다. 수작업 정책·별도 변환기로 확인한 결과는 부분 검증으로 기록하고 대체 채택은 별도 설계 결정으로 남긴다.
- 독립적인 정상·실패·누락/수집 오류·미구현·적용 제외 fixture를 사용해 프로젝트의 5값 상태와 OSCAL 표현의 매핑을 확인한다. 만료는 새 시각의 현재 판정으로 확인하고 과거 평가 결과를 수정하지 않는다.
- CycloneDX SBOM·취약점 보고서·VSA를 외부 증거 참조로 연결한다. digest 불일치, 끊긴 참조, 잘못된 서명, 만료 증거가 정상으로 투영되지 않는지 확인한다.
- 조회 API·화면에서 요구사항 → 적용 Profile → 구현 컴포넌트 → 평가 결과 → 근거 증거를 추적한다. 초기 fixture 화면과 실제 admission 결과를 사용한 통합 화면은 결과 기록에서 구분한다.
- 완료 기준은 실제 검사 결과와 OSCAL 변환·Postgres 조회·화면 판정의 일치, 원문까지의 참조 추적, 5값 상태·TTL 의미 보존이다. 구현 전 API 필드, 확장 namespace, UUID/문서 버전 규칙을 고정한다.
- 승인·복구의 집행 검증은 실험 2가 담당한다. 실험 4에서는 해당 승인 기록의 대상·정책 버전 및 사용한 OSCAL 평가 결과 참조가 연결되는지 확인한다. 승인·복구 규칙 전체가 OSCAL 표준 필드에 들어간다고 주장하지 않는다.
- 참고: [NIST OSCAL 모델](https://pages.nist.gov/OSCAL/learn/concepts/layer/), [C2P Kyverno 예제](https://github.com/oscal-compass/compliance-to-policy).

## 결과 기록과 진행 조건

독립 cold-read에서 드러난 설계 빈틈 중 정책 변경·신규 취약점과 복구 예외의 관계, Secret 값 처리, 승인 발행 주체, 반영 지연 상한, DB 계정 폐기·롤백 순서는 인터뷰에서 결정했다. 남은 구현 계약은 ConfigMap·컨트롤러 필드 정규화, 증거·VSA·승인 데이터 형식, GHCR 경로·identity·권한 설정, DB 역할 권한 SQL이다. 실험 fixture와 함께 구체화하고 승인 TTL과 배포 완료 제한 시간의 상호작용도 검증한다.

네 선행 실험은 kind 삭제 후 전체 복구 드릴을 대체하지 않는다. SBOM은 실험 1에, OSCAL 연결은 실험 4에 포함한다. 실험 4는 실험 1의 실제 검사 결과를 재사용한다. 실험 2는 고정 fixture로 시작할 수 있지만 최종 통과에는 실험 1의 실제 증거 경로와 실험 3의 LN 결제 환경을 연결해야 한다. Fixture만으로 실행한 결과는 부분 검증으로 남긴다.

각 실험에 실행 명령, 고정 버전, 관측 결과, 실패 사례, 증거 위치를 남긴다. 비밀 값은 기록하지 않는다. 결과는 미실행·부분 검증·통과·실패 중 하나로 표시한다. 네 실험 통과 전 전체 Phase 구현으로 넘어가지 않는다. 실험 1의 현재 결과는 [로컬 실행 기록](experiments/sbom-vsa-local.md)을 기준으로 한다.
