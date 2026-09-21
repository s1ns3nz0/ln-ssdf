# AI HANDOFF — ln-ssdf

이 문서는 **다른 AI 에이전트에게 이 프로젝트를 인계**하기 위한 자기완결 브리핑이다.
대화 맥락 없이 이 문서만으로 작업을 이어갈 수 있게 썼다.

작업 디렉토리: `~/orca/projects/lightning-labs/ln-ssdf`

현재 설계 기준은 이 문서와 [2026-09-21 인터뷰 결정](docs/design-decisions.md)이다. 상세 판정·TTL·배포 승인·복구 규칙은 인터뷰 결정 문서를 따른다. **합의는 구현 또는 기술 검증 완료를 뜻하지 않는다.**

---

## 0. 이 문서를 읽는 방법

- **§2 확정 결정은 재논의 대상이 아니다.** 각 항목에 근거를 붙였다. 뒤집으려면
  근거를 반박해야 하고, "일반적으로 더 낫다"는 이유로는 안 된다.
- **§3 미검증 목록은 사실로 단정하지 마라.** 사용자에게 보고할 때도 "확인 필요"를
  유지할 것. 이 프로젝트는 컴플라이언스 도구다 — 근거 없는 단정이 곧 제품 결함이다.
- **다음 작업은 [선행 실험](docs/preflight-experiments.md)이다.** OSCAL 연결을 포함한 네 실험을 검증한 뒤 §6의 Phase 0으로 진행한다.

---

## 1. 프로젝트가 뭔가

Lightning Labs의 **DevSecOps/Platform Engineer 포지션 지원용 포트폴리오**.
채용 공고(JD)의 요구사항과 지원자 배경을 하나의 동작하는 시스템으로 증명하는 게 목적이다.

### JD 원문 요약
역할:
- 내부 플랫폼을 구성하는 클라우드·클러스터 기술 운영
- **stateful 백엔드 서비스 운영 — 데이터베이스와 Bitcoin/LN 노드**
- observability 도구(logging/monitoring/tracing) 활용·운영·확장
- **operator, overlay network** 같은 수단으로 플랫폼 견고성·보안 개선
- dev 팀 통합 지원 — Helm 차트, 클라우드 리소스, k8s 라이프사이클

역량: Linux/네트워킹/보안/클라우드/IaC, 프로덕션 k8s 운영·트러블슈팅, observability 운영,
시스템 언어(Go/Python/Rust).
우대: **GitOps, DevSecOps, service mesh / postgresql, etcd / Bitcoin·Lightning 지식 /
오픈소스 기여 경험**.

대상 레포: `lightningnetwork/lnd`, `lightninglabs/lndinit`,
`lightninglabs/lndmon`, `lightninglabs/aperture`

### 지원자 배경 (서사 연결점)
컴플라이언스 자동화, **OSCAL Compass / Prowler 기여**, CKA/CKS.

### 한 줄 컨셉
**k8s 위 Lightning 플랫폼** — lnd 스택을 stateful 서비스로 실제 운영하고,
시크릿/크레덴셜 계층·관측·네트워크 정책·공급망 게이트(NIST SP 800-204D)를 붙인
내부 개발자 플랫폼.

---

## 2. 확정 결정 — 재논의 금지

각 항목의 **근거**를 반박하지 못하면 유지한다.

### 2.1 컨셉을 "SSDF 대시보드"에서 "LN 플랫폼"으로 전환
초기 설계는 Scorecard 결과를 Postgres에 넣고 Grafana로 보여주는 배치 ETL이었다.
**근거**: JD 5개 역할 중 4개가 운영이다. 배치 ETL은 k8s를 단순 실행 장소로 만들어
운영 실력 증거가 안 된다. SSDF는 폐기하지 않고 플랫폼의 공급망 게이트 컴포넌트로 강등.

### 2.2 스캔 대상 레포 4개 → 2개 (`lnd`, `aperture`)
이 제한은 **Scorecard 소스 저장소 평가**에만 적용한다. 이미지 취약점 검사와 admission 검증은 initContainer·sidecar·인프라를 포함한 실제 배포 이미지 전체가 대상이다. aperture는 실제 배포 전까지 배포 증거를 요구하지 않는다.

### 2.3 GitOps(ArgoCD)는 컷라인 위, Tilt와 역할 분리
**근거**: Tilt는 클러스터에 직접 apply, Argo는 git이 유일 진실. 같은 리소스를 둘 다
관리하면 Argo가 Tilt 변경을 drift로 보고 되돌린다.
→ **Tilt는 별도 개발 namespace의 `ssdf/`만 관리한다. 배포 검증 환경은 SSDF를 포함해 ArgoCD가 관리한다.** Git 관리 배포 명세 변경은 Argo에 한정하고, VSO·Kubernetes 컨트롤러·설정 Job은 담당 리소스에 한정한 권한을 가진다.

### 2.4 RV(Respond to Vulnerabilities)는 범위 밖
**근거**: SP 800-204D Appendix B, Table 3이 **RV.1~RV.3 제외를 명시**한다
("조직 정책 레벨이고 CI/CD 특정이 아님"). PW.1~PW.4, PW.7도 제외(설계 영역).
204D가 매핑하는 SSDF practice는 **12개뿐**: `PO.1~PO.5, PS.1~PS.3, PW.5, PW.6, PW.8, PW.9`.
→ 초기 문서에 있던 "PO/PS/PW/RV 매핑"은 **오류였고 수정됨**. 되돌리지 마라.

### 2.5 204D 1st-party / 3rd-party 2-트랙 분리
**근거**: 204D §4가 보안 조치를 두 갈래로 규정한다 —
(a) 1st-party 소프트웨어 개발·배포에 적용하는 내부 SSC 관행,
(b) 3rd-party 소프트웨어 조달·통합·배포에 적용하는 관행.
"lnd 레포의 Branch-Protection 점수"와 "내 ArgoCD가 drift 상태인가"는 같은 축에 못 올린다.

| | 1st-party | 3rd-party |
|---|---|---|
| 대상 | ln-ssdf 자신의 CI/CD + ArgoCD | lnd, aperture |
| 증거원 | GitHub Actions, cosign, ArgoCD API | OpenSSF Scorecard, trivy |
| 커버 | COMMIT-REQ, DEPLOY-REQ, GitOps-REQ | `PULL-PUSH_REQ-4` |

### 2.6 Kyverno admission 게이트 도입
**근거**: `DEPLOY-REQ-4` 원문 — *"only verified container images are admitted into the
environment and remain trusted during runtime... allow or block image deployment based on
organization-defined policies."* CI가 아니라 **클러스터 admission 요구사항**이다.
CI만으로는 이 요구사항을 만족할 수 없고, JD의 "operators로 보안 개선" 항목도 못 친다.

### 2.7 업스트림 이미지는 VSA 발행 후 검증
업스트림 이미지에 대한 내 검증 서명은 업스트림 빌드 출처 증명과 구분한다.
→ trivy 스캔 → **내가 VSA(Verification Summary Attestation) 발행** → Rekor 기록 →
Kyverno가 내 VSA와 발행 시각 검증.
**근거**: digest 핀 단독은 DEPLOY-REQ-4의 "scanned for vulnerabilities and attested for
findings" 및 "recency matters"를 절반만 만족한다. 미러 레지스트리는 이 규모에 과투자.

### 2.8 증거 상태는 5값, `no_evidence` 필수
`satisfied` / `not_satisfied` / `not_implemented` / `not_applicable` / **`no_evidence`**
**근거**: pass/fail 2값은 반드시 거짓말한다. 수집기가 ArgoCD API에 못 붙으면
`GitOps-REQ-4`는 `no_evidence`여야지 `satisfied`로 남으면 안 된다.
**증거에 TTL을 걸고 만료 시 자동 강등한다.** 오래된 데이터가 초록으로 렌더링되는 것이
컴플라이언스 대시보드의 표준 실패 모드다.

### 2.9 Rekor가 권위 저장소, Postgres는 projection
**근거**: 204D §5.1.1 — *"The storage location must be tamper-proof and protected using
robust access control."* Postgres는 DB 크레덴셜만 있으면 이력을 다시 쓴다.
- attestation류(VSA, 이미지 서명, SLSA provenance) → 건건이 Rekor
- 측정류(Scorecard 점수, ArgoCD 상태) → Postgres 해시 체인
  (`row_hash = H(prev_hash || row)`), **하루 1회 체인 헤드만 서명해 Rekor에 기록**
  (Certificate Transparency STH 패턴)
- 검증 잡이 Postgres projection hash chain을 재계산 → `ssdf_evidence_chain_tamper_detected` 메트릭

### 2.10 exporter는 사실만 내보낸다
```
ssdf_req_status{req="GitOps-REQ-4", practice="PS.3", track="first_party", status="satisfied"} 1
```
**근거**: 단일 커버리지 퍼센트를 내보내면 `no_evidence`가 숨는다.
`not_applicable`은 분모에서 **완전 제외**. 롤업은 Grafana 쿼리로. 롤업은 테이블이 아니라 VIEW.
**exporter에 가짜 정밀도를 굽지 않는다.**

### 2.11 정책 엔진은 Kyverno 단일 — `gate.rego` 폐기
**근거**: Kyverno가 admission에 들어온 이상 OPA/Conftest와 역할이 겹친다. 정책 엔진
둘을 동기화 상태로 유지하는 건 순수 비용. `kyverno apply`가 CI에서 **같은 정책 파일**을
돌린다 → 정책 하나, 집행 지점 둘(PR 시점 + 런타임).
`PULL-PUSH_REQ-4`가 OPA를 언급하지만 맥락이 SCM 설정 포스처 평가이고 같은 문장이
Scorecard도 지명한다 → Scorecard로 커버됨.
REQ 게이트는 공통 백엔드 판정을 소비한다. 필수 항목은 `satisfied`만 통과하며, 사유·범위가 Git에 기록된 적용 제외만 허용한다. 자세한 판정은 [인터뷰 결정](docs/design-decisions.md)을 따른다. Rego는 추가하지 않는다.

### 2.12 시크릿은 Vault (Sealed Secrets 아님)
lnd wallet seed는 git에 못 올리는데 `GitOps-REQ-3`은 git이 유일 진실이어야 한다고 요구한다.
- **transit auto-unseal**, 언실러도 영속 저장소를 사용하는 일반 Vault다. 언실러는 최초 기동·복구 시 수동 unseal하고 메인 Vault는 자동 unseal한다. dev 모드는 재시작 시 transit 키를 잃으므로 사용하지 않는다. 호스트 백업으로 kind 삭제 후 복원하며, 상세 범위는 [인터뷰 결정](docs/design-decisions.md)을 따른다.
- **database secrets engine 필수** — lnd/ssdf-collector에 단명 Postgres 크레덴셜 발급(TTL 1h)
  **근거**: Vault를 seed 보관용으로만 쓰면 Sealed Secrets보다 비싸기만 하다.
  204D §2.1이 직접 우려하는 항목("Stealing credentials from the build system")에 대응하고
  JD의 postgresql 항목을 정적 시크릿보다 강하게 친다.
- **VSO(Vault Secrets Operator)** 로 k8s Secret 동기화 → **lndinit은 무수정**
- lnd DB 자격증명 교체 시 짧은 계획 중단을 허용한다. 새 자격증명 반영·재시작·DB 재연결·결제 성공은 선행 실험과 Phase 2에서 검증한다.
- **GitOps 예외**: `vault operator init`은 일회성 out-of-band 작업이라 git에 못 넣는다.
  숨기지 말고 **Appendix B에 정식 예외로 기재.**

### 2.13 배제 확정
- **agentgateway(LF) L402 PR** — 지원자가 별도 진행 중인 실제 OSS 기여. 별도 repo에서
  독립 진행. 이 프로젝트에 **포함하지 마라.**

---

## 3. 미검증 — 사실로 단정 금지

| # | 항목 | 상태 | 해소 시점 |
|---|---|---|---|
| 1 | **204D §3 요구사항 반영** | 원문 읽기 완료. SBOM·신뢰 소스·SCM 통제·독립 리뷰의 구현 및 예외 정리는 미완료 | 설계·CI 구현 |
| 2 | **C2P Kyverno 프로젝트 호환성** | 공식 정책 생성·결과 변환 예제 존재 확인. 프로젝트 정책·버전에서 실행 미검증 | 선행 실험 4 |
| 3 | lnd remote signer 구성 (mainnet 경로 문서화용) | 미확인 | 문서 작성 시 |
| 4 | lnd HA가 `cluster.enable-leader-election` + etcd 전용인지 | 미확인 | Phase 9 |
| 5 | lnd postgres kvdb 백엔드의 regtest 안정성 | 완료 (2026-09-21, local kind) | Phase 2에서 채널·회전·재생성 드릴 통과 |

원문 확인은 구현 완료가 아니다. 번호 붙은 REQ만으로 전체 204D 충족을 주장하지 않는다.
PDF 원문: https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-204D.pdf
(§3은 문서 페이지 8~12 = PDF의 17~21번째 페이지)

**#2가 최대 기회**: 되면 `OSCAL component-definition → C2P generate → Kyverno 정책 →
집행 → assessment-results → req_status 적재` 경로가 열린다. 포트폴리오 연결고리가
"포맷 재사용"에서 **"기여한 OSS를 내 플랫폼의 정책 생성 엔진으로 실제 운용"** 으로 격상된다.
안 되면 Kyverno 정책 직접 작성하고 C2P는 결과 수집에만 사용.

---

## 4. 검증된 사실 (204D 원문 직접 확인)

PDF를 받아 읽고 확인한 것들. 인용해도 된다.

- 정식 명칭: *Strategies for the Integration of Software Supply Chain Security in
  DevSecOps CI/CD Pipelines*, 2024년 2월
- Appendix A(Table 2)가 CI/CD 보안 과업 → SSDF high-level practice 매핑 제공
- Appendix B(Table 3)가 제외 항목 정당화: PW.1~PW.4, PW.7 / RV.1~RV.3
- **번호 붙은 요구사항이 실재한다** (지어낸 매핑 불필요):
  - `PULL-PUSH_REQ-1` ~ `REQ-4` (§5.1.2) → PW.5, PS.1
  - `COMMIT-REQ-1`, `COMMIT-REQ-2` (§5.1.4) → PO.4, PW.8
  - `DEPLOY-REQ-1` ~ `REQ-5` (§5.2) → PO.1
  - `GitOps-REQ-1` ~ `REQ-4` (§5.2.1) → PS.3
- **`PULL-PUSH_REQ-4`가 OpenSSF Scorecard를 예시 도구로 직접 지명**
- §5.2.1이 **"Secure CD Pipeline — Case Study (GitOps)"** 로 ArgoCD/Flux를 직접 다룸
- 빌드 attestation 4종: Environment / Process / Materials / Artifacts
- Table 1 각주 b: *"VSA 같은 attestation을 붙인다고 artifact manager가 신뢰된다는 뜻은 아니다"*

---

## 5. 목표 아키텍처

```
[시크릿 계층]
Vault (StatefulSet, raft) ← transit auto-unseal ← 언실러 Vault (영속 저장소, 수동 unseal)
  ├─ kv: lnd seed/password  → VSO → k8s Secret → lndinit
  └─ database secrets engine → 단명 Postgres 크레덴셜 (TTL 1h)

[코어]
bitcoind (StatefulSet, regtest)
  └─ lnd (StatefulSet)
       ├─ initContainer: lndinit
       ├─ sidecar: lndmon → Prometheus
       └─ kvdb backend: postgres

같은 bitcoind에 연결한 상대 lnd (bbolt): 채널 개설·양방향 결제 드릴용

[데이터]
postgres (StatefulSet, PVC)
  ├─ db: lnd   -- channel state
  └─ db: ssdf  -- 컨포먼스 증거 원장

[공급망 게이트]
자체 이미지  → cosign keyless 서명 → Kyverno verifyImages     [DEPLOY-REQ-3/4]
업스트림     → trivy → VSA 발행 → Rekor → Kyverno 검증+신선도  [DEPLOY-REQ-4]
Git 관리 명세 → Argo가 변경; VSO·컨트롤러·Job은 담당 리소스 권한만 부여
메트릭: ssdf_admission_denied_total{policy,reason}

[GitOps]
ArgoCD app-of-apps, sync waves:
  wave0 vault(+언실러) → wave1 postgres, bitcoind → wave2 vault db-engine 설정 Job
  → wave3 lnd → wave4 observability → 이후 kyverno, ssdf
  (Vault가 Postgres 크레덴셜을 발급하므로 wave0. Vault 스토리지는 raft라 Postgres 무관)

[관측]
metrics: lndmon + postgres_exporter + ssdf exporter → Prometheus → Grafana
logs:    Loki/Promtail
traces:  OTel → Tempo (옵션)
알럿:    force-close / 피어 끊김 / PVC 80% / 백업 24h 정지 / attestation 신선도 /
         ArgoCD drift / no_evidence 발생 / 증거 변조 / Vault seal 상태
```

### DB 스키마 초안 (수정 필요)

아래는 초기 개념 예시다. 대상·트랙별 평가, 복수 증거 연결, 세부 검사, TTL, 정책 버전, 예외 및 승인을 반영한 최종 스키마는 아직 미확정이다. 이 4테이블을 그대로 구현하지 않는다.
```sql
evidence(id, observed_at, track, subject, subject_kind, claim jsonb,
         source, prev_hash, row_hash)     -- append-only 원장
req_status(req_id, status, evidence_id, evaluated_at, rationale)
req_practice(req_id, practice)            -- 정적, c2p-mapping.yaml에서 로드
checkpoint(at, head_hash, rekor_log_index)
-- 롤업은 VIEW. 테이블로 저장하지 마라 (낡는다)
```

---

## 6. 선행 실험 이후 작업 — Phase 0

**상태: 완료 (2026-09-21, 로컬 kind).** `local/kind-config.yaml`으로 control-plane 1대와 worker 2대를 만든 `ln-ssdf-phase0` cluster에서 `ssdf-postgres` StatefulSet, `data-ssdf-postgres-0` PVC, `lnd`·`ssdf` database와 `phase0-v1` schema marker를 확인했다. 클러스터·PVC·Helm release를 삭제한 뒤 Git 선언물과 새 runtime bootstrap credential만으로 재설치하는 드릴도 통과했다. 실행 절차와 bootstrap credential 경계는 [Phase 0 기록](docs/phase-0.md)에 있다.

### 선행
- **이 디렉토리는 git 레포가 아니다** (`git log` 실패). `git init` 필요 — 사용자 승인 후.

### 산출물
1. `local/kind-config.yaml` — **3노드** (control-plane 1 + worker 2)
   - 이유: anti-affinity 및 node drain 드릴이 Phase 8 런북에 필요
2. `charts/postgres/` — StatefulSet + PVC, DB 2개(`lnd`, `ssdf`) 초기화
3. `db/schema.sql` — 인터뷰 결정의 평가·증거 모델을 반영해 스키마 확정 후 작성

### 주의
Phase 0은 **부트스트랩 정적 시크릿**으로 시작한다. Phase 1에서 Vault 동적 크레덴셜로
전환한다. **임시임을 코드 주석과 커밋 메시지에 명시할 것.** 안 하면 영구화된다.

### 완료 기준
- `kind create cluster --config local/kind-config.yaml` 로 3노드 기동
- Postgres StatefulSet Running, PVC 바인딩
- 두 DB 생성 확인, `schema.sql` 적용 성공

---

## 7. 전체 Phase 지도

| Phase | 내용 | 비고 |
|---|---|---|
| **0** | kind 3노드 + Postgres(DB 2개) + schema | **완료** |
| **1** | Vault + 언실러 + VSO + database secrets engine | **완료**; 동적 전환·Raft snapshot 삭제/복원 드릴 통과 |
| 2 | bitcoind → lnd + lndinit(seed from Vault) + postgres 백엔드 | **완료** |
| 3 | Prometheus/Grafana + lndmon + postgres_exporter | **완료**; 재구축 후 scrape 게이트 통과 |
| 4 | ArgoCD 컷오버 + sync waves | **완료**; local Git source 재구축·drift self-heal 통과 |
| 5 | CI 컨트롤 + cosign 서명 | **부분 검증**; local CI 통과, GitHub OIDC 실행 대기 |
| 6 | Kyverno Audit + 격리 namespace 차단 테스트 (+ CI `kyverno apply`) | C2P 실태 확인 지점 |
| 7 | Scorecard + 전체 배포 이미지 VSA + 해시체인/Rekor 기록 | 검증 경로 준비 후 Enforce |
| 8 | 집계 + 알럿 + 런북 + NetworkPolicy + Appendix B | ← **컷라인** |
| 9 | 옵션: SCB 오퍼레이터, aperture, etcd HA, tracing, Cilium, Helm 공개 | |

### 순서 강제 조건 (뒤집으면 깨짐)
1. **0 → 1**: Vault database secrets engine이 Postgres에 role을 만들려면 Postgres가
   먼저 떠 있어야 한다
2. **1 → 2**: lnd seed가 Vault에 있어야 lndinit이 VSO 경유로 받는다
3. **5 → 6**: 서명 파이프라인 없이 admission을 켜면 자체 워크로드가 전부 차단된다
4. **4 → 6**: `GitOps-REQ-3`을 admission으로 강제하려면 Argo ServiceAccount가 먼저 존재해야 한다
5. **Phase 5는 클러스터 무관** — 막히면 여기로 도피

### Phase 검증 게이트 (통과 못 하면 다음으로 넘어가지 마라)
- **공통 (모든 Phase)**: 해당 Phase의 구축 대상과 영속 상태를 삭제한 뒤, Git의 선언물·명시된 외부 의존성·새 runtime secret 입력만으로 재생성한다. 그 뒤 해당 Phase의 기능 게이트를 다시 실행한다. 재생성할 수 없는 상태·수동 변경·보존해야 할 데이터는 범위와 복구 절차를 명시하고 별도 검증한다.
- **Phase 1**: 언실러 영속성·수동 unseal과 메인 Vault 자동 unseal 확인. Postgres 크레덴셜 갱신·만료 확인
- **Phase 2 — 완료 (2026-09-21, local kind)**: regtest bitcoind와 primary(Postgres)·peer(bbolt) lnd를 구성했다. Vault KV→VSO wallet Secret, Vault database lease→VSO DB Secret 경로로 primary를 구동해 1,000,000 sat 채널과 양방향 결제를 확인했다. 이전 lease를 Vault에서 명시 revoke하고 새 lease로 primary를 재기동한 뒤 기존 채널의 양방향 결제를 다시 통과했다. `ln-ssdf-phase0` cluster/PVC를 삭제·재생성해 Vault snapshot을 복원하고 새 regtest 체인·채널·양방향 결제를 다시 통과했다. 이 재생성 검증은 기존 채널 복구 주장이 아니라 새 체인에서의 설치 가능성 증명이다.
- **Phase 3 — 완료 (2026-09-21, local kind)**: Prometheus, Grafana, lndmon, postgres-exporter를 배포했다. exporter는 VSO가 동기화한 `postgres-observability` 동적 lease만 사용하고, Grafana는 ClusterIP 전용·익명 접근 비활성화·런타임 생성 관리자 Secret으로 설치한다. `ln-ssdf-phase0`을 삭제·재생성한 뒤 Vault snapshot 복원과 새 Phase 2 체인/채널 드릴을 거쳐, Prometheus가 primary lnd·peer lnd·lndmon·postgres-exporter 네 target에서 모두 `up == 1`임을 재확인했다. Grafana와 Prometheus PVC도 새 클러스터에서 바인딩됐다. 절차와 범위는 [Phase 3 기록](docs/phase-3.md)에 있다.
- **Phase 4 — 완료 (2026-09-21, local kind)**: checksum을 확인한 ArgoCD chart 10.9.2를 설치하고, PVC-backed in-cluster Git daemon의 `main`을 app-of-apps source로 사용했다. Vault→workloads→VSO resources→lnd→observability 파동의 Git source Application이 모두 같은 commit에서 `Synced`·`Healthy`가 됐다. commit된 probe ConfigMap 변경이 반영되고 out-of-band 변조가 self-heal되는 것을 확인했다. `phase4-rebuild-drill.sh`은 빈 local kind cluster에서 Phase 0~3 복원 뒤 이 게이트를 다시 통과한다. Git daemon은 인증 없는 로컬 fixture이므로 운영 source control 주장에는 사용할 수 없다. 자세한 범위는 [Phase 4 기록](docs/phase-4.md)에 있다.
- **Phase 5 — 부분 검증**: SHA-pinned GitHub Actions workflow가 Node·Helm 검증과 source-provenance 생성 계약을 갖고, `main` push 후에만 GitHub OIDC keyless Cosign bundle을 발행하도록 구성했다. local `ci-verify.sh`는 통과했지만 GitHub remote·protected branch·OIDC identity·Rekor bundle 검증은 아직 실행 증거가 없다. [Phase 5 기록](docs/phase-5.md)의 조건 전까지 완료로 주장하지 않는다.
- **Phase 6 — 완료 (2026-09-21, local kind)**: current Kyverno \`ValidatingPolicy\` API로 \`ssdf-system\`의 일반·init·ephemeral 컨테이너 digest를 Audit했고, 격리 namespace에서 mutable 일반 이미지와 init container를 API-server admission 단계에서 거절했다. Audit PolicyReport의 기존 SSDF 리소스는 모두 PASS다. [Phase 6 기록](docs/phase-6.md)에 범위가 있다.
- **Phase 7 — 명시적 보류**: \`ssdf-system\`의 실제 7개 runtime image는 versioned inventory에 모두 \`no_evidence\`로 기록됐다. [readiness gate](docs/phase-7.md)는 인벤토리 drift를 실패로, 미검증 evidence를 exit 3으로 처리한다. signed SBOM·VSA↔SBOM digest binding·trusted keyless issuer·transparency-log 검증 전에는 Enforce로 승격하지 않는다.
- **Phase 8 — 완료 (2026-09-21, local kind)**: evidence projection hash chain을 재계산하는 PostgreSQL verifier를 postgres-exporter metric과 Prometheus alert에 연결했다. 전용 fixture row를 trigger 우회로 변조해 verifier 실패→metric 1→firing alert를 확인했고, 원래 claim 복구 뒤 metric 0과 alert 해제까지 확인했다. 관측성 경로 NetworkPolicy도 GitOps로 적용하고 scrape gate를 재확인했다. Alertmanager 외부 전달, Rekor checkpoint 대조, namespace-wide default deny는 [Appendix B](docs/appendix-b.md)의 명시적 제한이다.

### 규모 현실
Phase 10개는 포트폴리오치고 크다. **Phase 0~4가 "돌아가는 플랫폼", 5~8이 "204D 컨포먼스".**
5~8을 못 끝내도 0~4만으로 JD 운영 항목은 대부분 증명된다. 컷라인은 8, **비상 탈출선은 4**.

### 줄여야 하면 이 순서로
1. Phase 7 VSA 발행 → 업스트림 digest 핀만 (단 DEPLOY-REQ-4가 반쯤 빈다)
2. Phase 1 database secrets engine → Vault는 seed kv만 (단 Vault 도입 비용 회수 실패)
3. Phase 2 lnd postgres 백엔드 → 기본 bbolt
4. Phase 3 Loki → metrics만

**Phase 5·6·8은 자를 수 없다.** 각각 "서명 없음" / "admission 없음(2-트랙 결정 무효)" /
"운영 증거 없음"이 된다.

---

## 8. 작업 규약

### 환경 제약 (`AGENTS.md` 발췌)
- 이 레포 안에서만 작업. 승인 없이 publish/deploy/merge/시크릿 변경/외부 접촉 금지
- **MVP 우선** — 확장·추상화·자동화·광택 전에 가장 작은 검증 가능한 조각부터
- 테스트·CI는 **Linux 우선, vendor-neutral**. 로컬 전용 라이브러리/서비스/OS 동작에 의존 금지
- 배포 산출물은 유지되는 Linux Docker 이미지에서 테스트, 가능하면 digest로 핀
- 코드·설정·사용자 가시 동작 변경 시 `sip`/`shower` 리뷰 후 인계

### 정직성 규약 (이 프로젝트 특유 — 중요)
이 프로젝트는 컴플라이언스 도구다. 도구가 거짓말하면 제품 결함이다.
- 수집 못 한 증거는 `no_evidence`. **절대 `satisfied`로 두지 마라**
- 데모 타협(regtest seed는 가치 0 / 언실러 수동 unseal·호스트 백업 / Postgres 단일 인스턴스)은
  **README와 `docs/appendix-b.md`에 명시**. 프로덕션이면 뭐가 달라지는지 같이 적을 것
- 미구현 항목은 204D Appendix B 방식으로 **정당화 문서를 만든다.** 예외 없는 척하는
  문서보다 예외를 찾아 정당화한 문서가 신뢰도가 높다
- 검증 안 한 것을 검증한 것처럼 보고하지 마라. §3 목록을 그대로 유지·갱신할 것

---

## 9. 참고 문서
- `HANDOFF.md` — 인터뷰 전 설계의 역사 기록; 현재 결정은 `docs/design-decisions.md` 참조
- `AGENTS.md` — 레포 작업 규약
- `docs/project.md` — harness 프로젝트 식별 정보
- SP 800-204D PDF —
  https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-204D.pdf
- SSDF(SP 800-218) — https://doi.org/10.6028/NIST.SP.800-218

작성: 2026-09-21
