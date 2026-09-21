# HANDOFF — ln-ssdf

> 이 문서는 인터뷰 전 설계의 역사 기록이다. 실행 기준은 [AI-HANDOFF.md](AI-HANDOFF.md)와 [인터뷰 결정](docs/design-decisions.md)이다. 아래의 언실러 dev 모드, Tilt/Argo 경계, `not_satisfied`만 차단하는 게이트, Phase 6 Enforce 순서는 최신 합의로 대체되었다.

## 목적
Lightning Labs DevSecOps/Platform Engineer 포지션 지원용 포트폴리오 프로젝트.
지원자 배경(컴플라이언스 자동화, OSCAL Compass/Prowler 기여, CKA/CKS)과 JD 요구사항을
하나로 엮는다.

## 한 줄 컨셉
**k8s 위 Lightning 플랫폼** — lnd 스택을 stateful 서비스로 실제 운영하고,
시크릿/크레덴셜 계층·관측·네트워크 정책·공급망 게이트(NIST SP 800-204D)를 붙인
내부 개발자 플랫폼.

## 왜 이 컨셉인가
원본 JD 5개 역할 중 4개가 **운영**이다:
- stateful 백엔드 서비스(DB + **Bitcoin/LN 노드**) 관리
- observability 도구 운영·확장
- **operator**, **overlay network**로 견고성/보안 개선
- Helm 차트·k8s 라이프사이클로 dev팀 지원

초기 설계(CronJob → Postgres → exporter → Grafana)는 배치 ETL이라 k8s가 단순 실행
장소에 불과했다. "레포를 스캔했다"가 아니라 "그들 스택을 운영했다"가 되어야 함.

## 배제 확정
- **agentgateway(LF) L402 PR**: 지원자가 별도 진행 중인 실제 OSS 기여. 별도 fork/repo에서
  독립 진행, 이 프로젝트에 포함 안 함.

---

# 기준 문서: NIST SP 800-204D

*Strategies for the Integration of Software Supply Chain Security in DevSecOps
CI/CD Pipelines* (2024-02). 원문 검증 완료.

## 확인된 사실 — SSDF 전체가 아니다

204D Appendix A(Table 2)가 매핑하는 SSDF practice는 **12개뿐**:

```
PO.1  PO.2  PO.3  PO.4  PO.5
PS.1  PS.2  PS.3
PW.5  PW.6  PW.8  PW.9
```

Appendix B(Table 3)가 제외를 명시:
- **PW.1~PW.4, PW.7** — 보안 설계·리뷰·재사용. CI/CD가 아니라 설계 영역
- **RV.1~RV.3** — 취약점 관리는 조직 정책 레벨, CI/CD 특정 아님

→ **RV는 이 프로젝트 범위 밖이다.** 초기 문서의 "PO/PS/PW/RV 매핑"은 오류였다.

## 204D는 번호 붙은 요구사항을 직접 준다

| 그룹 | 요구사항 | 대응 SSDF |
|---|---|---|
| 5.1.2 PULL-PUSH | `PULL-PUSH_REQ-1` ~ `REQ-4` | PW.5, PS.1 |
| 5.1.4 Commits | `COMMIT-REQ-1`, `COMMIT-REQ-2` | PO.4, PW.8 |
| 5.2 CD | `DEPLOY-REQ-1` ~ `REQ-5` | PO.1 |
| 5.2.1 GitOps | `GitOps-REQ-1` ~ `REQ-4` | PS.3 |
| 5.1.1 Secure Build | Environment/Process/Materials/Artifacts attestation | PO.5, PW.6 |
| 5.1.3 Updates | 키 관리·서명 프레임워크 | PS.2 |

**`PULL-PUSH_REQ-4`가 OpenSSF Scorecard를 예시 도구로 직접 지명한다.**

---

# 아키텍처

## 1. 시크릿/크레덴셜 계층 — Vault

lnd wallet seed는 git에 못 올린다. 그런데 `GitOps-REQ-3`은 git이 유일 진실이어야
한다고 요구한다. 이 충돌을 Vault로 푼다.

```
Vault (StatefulSet, raft 스토리지, PVC)
  ├─ transit auto-unseal ← 언실러 Vault (dev 모드, 무상태)
  ├─ kv: lnd wallet seed / password       → VSO → k8s Secret → lndinit
  └─ database secrets engine              → 단명 Postgres 크레덴셜 (TTL 1h, 자동 회전)
                                             lnd, ssdf-collector가 소비
```

**auto-unseal 방식**: kind 안에는 클라우드 KMS가 없다. 클라우드 KMS를 쓰면 로컬 재현성이
깨지고 `AGENTS.md`의 vendor-neutral 규칙과 충돌한다. → **transit auto-unseal**,
언실러 Vault는 dev 모드로 in-cluster.
README·Appendix B에 명시할 것: *"언실러는 dev 모드 데모 타협. 프로덕션 경로는
클라우드 KMS auto-unseal."* 언실러는 상태를 안 가지므로 메인 Vault에 dev 모드를
쓰는 것과는 완전히 다른 선택이다.

**database secrets engine이 핵심이다.** Vault를 seed 보관용으로만 쓰면 Sealed Secrets보다
비싸기만 하다. 단명 Postgres 크레덴셜 발급까지 하면:
- JD "Database administration: postgresql" + "stateful backend services"를 정적 시크릿보다
  강하게 침
- 204D §2.1이 직접 우려하는 항목에 대응 — *"Stealing credentials from the build system"*
- 크레덴셜 회전이 런북 드릴 소재로 추가됨

**동기화**: VSO(Vault Secrets Operator). HashiCorp 자체라 부품이 하나로 끝난다.
ESO도 가능하나 다른 백엔드로 갈 계획이 없으므로 VSO. 어느 쪽이든 **lndinit은 무수정.**

**GitOps 예외**: `vault operator init`(루트 토큰·언실 키 생성)은 본질적으로 일회성
out-of-band 작업이라 git에 못 넣는다. `GitOps-REQ-3`의 정식 예외 → **Appendix B에 기재**.
예외를 찾아 정당화한 문서가 예외 없는 척하는 문서보다 신뢰도가 높다.

## 2. 코어 — LN 스택 운영
```
bitcoind (StatefulSet, regtest/signet)
  └─ lnd (StatefulSet)
       ├─ initContainer: lndinit  → VSO가 심은 k8s Secret에서 wallet create/unlock
       ├─ sidecar: lndmon         → Prometheus 메트릭
       └─ kvdb backend: postgres  → Vault 발급 단명 크레덴셜로 접속
```
`lndinit`, `lndmon`은 Lightning Labs 자체 도구 — 정확히 이 용도로 만들어진 물건.

**정직성 조항**: regtest seed는 가치가 0이다. README에 명시. 실제 자금을 지키는 척하면
안 된다. 대신 mainnet 경로를 문서화 — seed를 노드에서 분리(lnd remote signer, **미검증**),
HSM/KMS 백엔드. 데모와 프로덕션의 차이는 말로 주장하는 것보다 문서로 구분하는 게
설득력 있다.

## 3. 데이터 — Postgres 1대, DB 2개
```
postgres (StatefulSet, PVC)
  ├─ db: lnd    -- lnd kvdb backend (channel state)
  └─ db: ssdf   -- 컨포먼스 증거 원장
```
의도적 통합. StatefulSet 1개면 백업·복구·HA 스토리도 1개라 운영 증명이 선명해진다.
프로덕션이면 분리해야 함 — SSDF 가용성이 lnd 핵심 DB에 묶이는 구조. README에 명시.

## 4. 204D 2-트랙

204D §4는 보안 조치를 두 갈래로 나눈다. 섞으면 범주 오류 — 분리한다.

| | **1st-party** (내 파이프라인) | **3rd-party** (업스트림) |
|---|---|---|
| 대상 | ln-ssdf 자신의 CI/CD + ArgoCD | lnd, aperture |
| 증거원 | GitHub Actions, cosign, ArgoCD API | OpenSSF Scorecard, trivy |
| 커버 | COMMIT-REQ, DEPLOY-REQ, GitOps-REQ | `PULL-PUSH_REQ-4` |

**최대 소득**: `GitOps-REQ-4`(drift 감지 → 자동 resync 또는 알림)는 **런타임 클러스터
요구사항**이다. ArgoCD sync_status를 Prometheus로 뽑으면 그게 곧 204D 컨포먼스 측정.
"SSDF는 CI 얘기, k8s는 별개"였던 단절이 여기서 붙는다.

## 5. Admission 게이트 — 두 트랙 합류점

`DEPLOY-REQ-4` 원문: *"only verified container images are admitted into the environment
and remain trusted during runtime... allow or block image deployment based on
organization-defined policies."* → CI가 아니라 **클러스터 admission 요구사항**.

```
자체 빌드 이미지 (ssdf-collector, ssdf-exporter)
  → cosign keyless 서명
  → Kyverno verifyImages 검증                    [DEPLOY-REQ-3/4]

업스트림 이미지 (lnd, bitcoind)
  → 내 서명이 있을 수 없음 (남이 빌드)
  → trivy 스캔 → 내가 VSA 발행 → Rekor 기록
  → Kyverno가 내 VSA + 발행 시각 검증            [DEPLOY-REQ-4 "recency matters"]

모든 워크로드
  → Argo ServiceAccount 외 쓰기 거부             [GitOps-REQ-3]
```
메트릭: `ssdf_admission_denied_total{policy,reason}`

**서명 키는 sigstore keyless (Fulcio/Rekor).** 204D §5.1.3이 "online key를 클라이언트
신뢰 대상에 쓰지 말라"고 걱정하는 문제를 키리스가 구조적으로 해소 → HSM 미도입의
정당한 근거.

업스트림 검증은 **VSA 발행** 채택. digest 핀 단독은 DEPLOY-REQ-4의 "scanned and attested
for findings"를 절반만 만족해서 기각. 미러 레지스트리는 과투자.

## 6. 정책 엔진 — Kyverno 단일

`policy/gate.rego`(OPA/Conftest) **폐기**. Kyverno가 admission에 들어오면서 역할이
겹치고, 정책 엔진 두 개를 동기화 상태로 유지하는 건 순수 비용이다.

- 매니페스트 보안 기본값 검사 → CI에서 `kyverno apply`, 런타임에 admission.
  **정책 파일 하나, 집행 지점 둘.** 동기화 문제 자체가 소멸
- 서사도 낫다: *"같은 정책을 merge 전에도, 런타임에도 강제한다"*
- 매니페스트 기본값 검사는 204D §5 → **PW.9** 매핑 유지
- REQ 회귀 차단만 별도 스크립트(`req_status` 조회 → `not_satisfied` 있으면 exit 1).
  Rego 불필요

`PULL-PUSH_REQ-4`가 OPA를 언급하긴 하나 맥락이 **SCM 설정 포스처 평가**이고 같은 문장이
Scorecard도 지명한다. Scorecard로 커버됨.

## 7. 증거 모델

### 상태 어휘 — 5값
pass/fail 2값으로 두면 반드시 거짓말한다.

| 상태 | 의미 |
|---|---|
| `satisfied` | 구현됨 + 증거 수집됨 + 증거 통과 |
| `not_satisfied` | 구현됨 + 증거 수집됨 + 증거 실패 |
| `not_implemented` | 범위 내인데 안 만듦 |
| `not_applicable` | 정당화된 제외 → Appendix B행 |
| **`no_evidence`** | 구현 주장하나 수집기가 확인 못 함 |

`no_evidence`가 핵심. ArgoCD API에 못 붙으면 `GitOps-REQ-4`는 `no_evidence`여야지
`satisfied` 유지가 되면 안 된다. **증거에 TTL을 걸고 만료 시 자동 강등.**
오래된 데이터가 초록으로 렌더링되는 것이 컴플라이언스 대시보드의 표준 실패 모드다.

OSCAL assessment-results 어휘와 대체로 대응 — C2P 연동 시 그대로 쓸 수 있다.

### tamper-proof — Postgres는 자격이 없다
204D §5.1.1: *"The storage location must be tamper-proof and protected using robust
access control."* Postgres는 DB 크레덴셜만 있으면 이력을 다시 쓴다.

**Rekor가 권위 저장소, Postgres는 조회용 projection.** 전부 Rekor에 넣으면 비싸므로 분리:
- **attestation류**(VSA, 이미지 서명, SLSA provenance) → 건건이 Rekor
- **측정류**(Scorecard 점수, ArgoCD 상태) → Postgres 해시 체인
  (`row_hash = H(prev_hash || row)`), **하루 1회 체인 헤드만 서명해 Rekor에 기록**
  (Certificate Transparency STH 패턴)

부수 효과: 검증 잡이 Postgres를 Rekor 체크포인트와 대조 → `ssdf_evidence_tamper_detected`
메트릭. **런북 보안 드릴 추가**: Postgres 행을 손으로 고침 → 탐지 → 알럿.

### 스키마
```sql
evidence(id, observed_at, track, subject, subject_kind, claim jsonb,
         source, prev_hash, row_hash)     -- append-only 원장
req_status(req_id, status, evidence_id, evaluated_at, rationale)
req_practice(req_id, practice)            -- 정적, c2p-mapping.yaml에서 로드
checkpoint(at, head_hash, rekor_log_index)
```
**롤업은 테이블이 아니라 VIEW.** 저장하면 낡는다.

### exporter는 사실만 내보낸다
단일 퍼센트를 내보내면 `no_evidence`가 숨는다.
```
ssdf_req_status{req="GitOps-REQ-4", practice="PS.3", track="first_party", status="satisfied"} 1
```
`not_applicable`은 분모에서 완전 제외. `no_evidence > 0`이면 알럿. 롤업은 Grafana 쿼리로.
**exporter에 가짜 정밀도를 굽지 않는다.**

## 8. 관측 — 3축
- **metrics**: lndmon + postgres_exporter + ssdf exporter → Prometheus → Grafana
- **logs**: lnd/bitcoind → Loki/Promtail
- **traces**: OTel → Tempo (옵션, 후순위)
- **알럿**: force-close 감지, 피어 끊김, PVC 80%, 백업 24h 정지, attestation 신선도 초과,
  ArgoCD drift 지속, `no_evidence` 발생, 증거 변조 탐지, Vault seal 상태

## 9. 네트워크
default-deny NetworkPolicy, lnd p2p 포트만 허용. Cilium + Hubble은 옵션.

## 10. 플랫폼 운영
- **GitOps**: ArgoCD app-of-apps + sync waves
  ```
  wave0 vault(+언실러)  →  wave1 postgres, bitcoind  →  wave2 vault db-engine 설정 Job
  →  wave3 lnd  →  wave4 observability  →  이후 kyverno, ssdf
  ```
  Vault가 Postgres 크레덴셜을 발급하므로 wave0. Vault 자체 스토리지는 raft(자체 PVC)라
  Postgres에 의존하지 않는다.
- **Tilt ↔ ArgoCD 경계**: Tilt는 직접 apply, Argo는 git이 유일 진실. 같은 리소스를 둘 다
  관리하면 Argo가 Tilt 변경을 drift로 보고 되돌린다.
  → Tilt: `ssdf/` 파이썬만 / ArgoCD: 인프라 차트 전부. Argo app에서 `ssdf-*` 제외
- **Helm**: lnd 차트를 values schema 붙여 공개 (공식 차트 없음 → OSS 기여 각도)
- **런북**: `docs/runbooks/` — 실제 드릴 수행 후 Grafana 스크린샷 첨부

---

# 빌드 순서

| Phase | 내용 | 비고 |
|---|---|---|
| **0** | kind 3노드 + Postgres(DB 2개) + schema | 부트스트랩 정적 시크릿(임시) |
| **1** | Vault + 언실러 + VSO + database secrets engine | Postgres 크레덴셜 동적 전환 |
| **2** | bitcoind → lnd + lndinit(seed from Vault) + postgres 백엔드 | |
| **3** | Prometheus/Grafana + lndmon + postgres_exporter | |
| **4** | ArgoCD 컷오버 + sync waves | GitOps-REQ-4 메트릭 공짜 확보 |
| **5** | CI 컨트롤 + cosign 서명 | 클러스터 무관, **병렬 가능** |
| **6** | Kyverno admission (+ CI `kyverno apply`) | 두 트랙 합류점. C2P 실태 확인 지점 |
| **7** | Scorecard(3rd-party) + VSA 발행 + 해시체인/Rekor 체크포인트 | |
| **8** | 집계 + 알럿 + 런북 + NetworkPolicy + Appendix B | ← **컷라인** |
| 9 | 옵션 | SCB 오퍼레이터, aperture, etcd HA, tracing, Cilium, Helm 공개 |

## 순서 강제 조건 (뒤집으면 깨짐)
1. **0 → 1**: Vault database secrets engine이 Postgres에 role을 만들려면 Postgres가
   먼저 떠 있어야 한다. Phase 0은 정적 시크릿으로 시작하고 Phase 1에서 동적 전환.
   임시 시크릿임을 커밋 메시지·코드에 명시할 것
2. **1 → 2**: lnd seed가 Vault에 있어야 lndinit이 VSO 경유로 받는다
3. **5 → 6**: 서명 파이프라인 없이 admission 켜면 내 워크로드가 전부 차단된다.
   cosign 서명(DEPLOY-REQ-3)이 admission 검증(DEPLOY-REQ-4)의 전제조건
4. **4 → 6**: `GitOps-REQ-3`을 admission으로 강제하려면 Argo ServiceAccount가
   먼저 존재해야 정책을 쓸 수 있다
5. **Phase 5는 클러스터 무관** — GitHub Actions 설정 + 서명뿐. 0~4 진행 중 병렬 가능,
   클러스터에서 막히면 여기로 도피

## Phase 검증 게이트
- **Phase 1**: Vault 재시작 → 자동 unseal 확인. Postgres 크레덴셜 TTL 만료 후 자동 갱신 확인
- **Phase 2**: 채널 개설 → Postgres에 channel state 적재 확인.
  "lnd postgres 백엔드 안정성" 미검증 항목이 여기서 해소된다
- **Phase 6**: Audit 모드 → Enforce 승격. 미서명 이미지 배포 시도 → 차단 확인
- **Phase 8**: Postgres 행 수동 변조 → 검증 잡 탐지 → 알럿 확인

## 더 줄여야 하면 (이 순서로)
1. Phase 7 VSA 발행 → 업스트림은 digest 핀만. 단 DEPLOY-REQ-4가 반쯤 빈다
2. Phase 1 database secrets engine → Vault는 seed kv만. 단 Vault 도입 비용 회수가 안 됨
3. Phase 2 lnd postgres 백엔드 → 기본 bbolt. Postgres는 ssdf DB 전용
4. Phase 3 Loki → metrics만

**Phase 5·6·8은 자를 수 없다.** 자르면 각각 "서명 없음" / "admission 없음(2-트랙 결정
무효)" / "운영 증거 없음"이 된다.

---

# 미결 / 검증 필요

1. **C2P 실태** — OSCAL Compass Compliance-to-Policy의 Kyverno 플러그인이 현재 어떤 형태로
   정책 생성을 지원하는지 **미확인(기억 기반, 단정 불가)**. Phase 6 진입 시 실제 레포로 확인.
   - 되면: OSCAL component-definition → C2P generate → Kyverno 정책 → 집행 →
     assessment-results → `req_status` 적재. 포트폴리오 연결고리가 "포맷 재사용"에서
     **"기여한 OSS를 내 플랫폼의 정책 생성 엔진으로 실제 운용"** 으로 격상
   - 안 되면: Kyverno 정책 직접 작성, C2P는 결과 수집(assessment-results)에만 사용
2. **lnd remote signer** — mainnet 경로 문서화용. 지원 여부·구성 미검증
3. **lnd HA 메커니즘** — `cluster.enable-leader-election` + etcd 백엔드 조합인지, postgres
   백엔드로도 리더 선출 가능한지. JD의 "etcd"가 이걸 가리킬 가능성 높아 맞추면 차별화 큼.
   Phase 9라 급하지 않음
4. **lnd postgres kvdb 백엔드의 regtest 안정성** → Phase 2 검증 게이트에서 해소

---

# 리포 구조 (제안, 미스캐폴딩)
```
ln-ssdf/
├── charts/
│   ├── vault/             # StatefulSet(raft) + 언실러 + VSO
│   ├── postgres/          # StatefulSet, PVC, 2 DB init
│   ├── bitcoind/
│   ├── lnd/               # lndinit initContainer + lndmon sidecar
│   ├── observability/     # Prometheus, Grafana, Loki, PrometheusRule
│   ├── kyverno/           # admission 정책 A/B/C (CI에서도 kyverno apply로 재사용)
│   ├── ssdf-collector/    # CronJob (scorecard + trivy + VSA 발행 + 체크포인트)
│   └── ssdf-exporter/     # Deployment + Service + ServiceMonitor
├── ssdf/
│   ├── collect.py
│   ├── vsa_issue.py
│   ├── checkpoint.py      # 해시체인 헤드 → Rekor
│   ├── verify.py          # Postgres ↔ Rekor 대조
│   ├── c2p-mapping.yaml   # 204D REQ → SSDF 12 practice
│   └── repos.yaml         # lnd, aperture
├── db/schema.sql
├── local/{kind-config.yaml, Tiltfile}
├── gitops/                # ArgoCD app-of-apps, sync waves
├── docs/{architecture.md, appendix-b.md, runbooks/}
└── .github/workflows/     # ci-controls, sign, kyverno-apply, scorecard-ssdf
```

# 참고
- 로컬 개발: kind 3노드 + Tilt. 적용 범위는 "플랫폼 운영" 경계 참조
- 작업 위치: `~/orca/projects/lightning-labs/ln-ssdf`
- 개정 이력
  - 2026-09-21 (1) SSDF 단독 → LN 플랫폼 + SSDF 컴포넌트, 스캔 4→2 레포
  - 2026-09-21 (2) GitOps를 컷라인 위로 복원, Tilt↔ArgoCD 경계, kind 3노드
  - 2026-09-21 (3) 204D 원문 검증 → RV 제외 확인, 2-트랙 분리, Kyverno admission,
    업스트림 VSA 채택
  - 2026-09-21 (4) 증거 모델 확정(5-상태 / 해시체인+Rekor 체크포인트 / 4테이블 /
    사실만 내보내기), `gate.rego` 폐기 → Kyverno 단일, Vault 도입(transit auto-unseal +
    database secrets engine + VSO), Phase 0~9 재배치
