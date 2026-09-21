# 실험 1: 로컬 OCI SBOM·VSA 발행 기록

상태: **통과 (로컬 kind admission fixture)** (2026-09-21).

로컬 HTTP 레지스트리 `localhost:5001`에서 workload와 evidence 저장소를 분리해, CycloneDX SBOM과 VSA를 Cosign 정적 키로 서명·조회했다. 이 기록은 Kyverno admission, GHCR, keyless identity, Rekor 투명성 로그를 검증한 결과가 아니다.

## 관측 결과

- workload: `localhost:5001/ln-ssdf/alpine@sha256:c64c687cbea9300178b30c95835354e34c4e4febc4badfe27102879de0483b5e`
- SBOM: Syft 1.42.4가 CycloneDX 1.6, component 92개를 생성했다. 파일 SHA-256은 `53b3231a256aa024d5a5c1b416b173eb58743a5fbd753c64eb34c4355c111df2`이다.
- scan: 공식 `aquasec/trivy:0.74.0` 컨테이너(digest `sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969`)가 원격 레지스트리 manifest를 스캔했고 취약점은 0건이었다. 스캔 보고서 SHA-256은 `232fd7449275e44f2d192f92c155c855c52ecf48f66d91c2665ff842cd7ac3e4`이다.
- evidence repository: `localhost:5001/evidence/vsa:sha256-c64c687cbea9300178b30c95835354e34c4e4febc4badfe27102879de0483b5e.att`에 SBOM과 VSA DSSE envelope 두 개가 저장됐다.
- VSA input: [vsa-predicate.json](../../experiments/sbom-vsa/vsa-predicate.json). Cosign 3.1.3이 이를 `https://in-toto.io/Statement/v0.1`으로 감쌌고, subject digest, raw SBOM hash, scan-report hash를 확인했다. admission 정책은 VSA의 `urn:ln-ssdf:sbom:cyclonedx` input-attestation digest가 이 signed SBOM digest와 일치하는지도 요구한다.
- Cosign 3.1.3 `verify-attestation`은 별도 evidence repository와 시험용 공개키로 두 predicate 모두 성공했다. 로컬 키 방식이므로 transparency-log 검증은 명시적으로 생략했다.

## 실패와 제한

## API-server admission 재검증

`kind-ln-ssdf-e1`에서 정책 source를 다시 적용한 뒤 `--dry-run=server`로 admission을 재확인했다.

- `e1-valid-proof` 및 복원 뒤의 `e1-valid-restored`는 signed CycloneDX SBOM, PASS VSA, 유효 TTL 및 VSA의 CycloneDX input-attestation digest 결속을 모두 만족해 허용됐다.
- 존재하지 않는 image digest를 사용한 `e1-missing-proof`는 `no matching attestations`로 Kyverno mutate admission webhook에서 거절됐다.

Cosign 3 OCI 1.1 bundle은 이 Kyverno legacy verifier가 조회하지 못했다. 따라서 kind node 안에서 Cosign 2.4.1로 legacy attestation을 발행했다. 해당 runtime-compatible 형식으로 다음 `--dry-run=server` API-server 결과를 보존했다.

- `e1-current-valid`: trusted key, CycloneDX SBOM, `PASSED` VSA, 미래 `expiresAt`, VSA↔SBOM digest 결속으로 **허용**.
- `e1-failed-v2`: trusted SBOM과 `verificationResult: FAILED` VSA로 **거절**.
- `e1-expired-v2`: trusted SBOM과 과거 `expiresAt` VSA로 **거절**.
- `e1-untrusted-v2`: 다른 static key로 서명한 SBOM/VSA로 **거절**.
- `e1-missing-digest`: registry에 존재하지 않는 image digest로 **거절**(evidence lookup failure).

실패 요청 모두 `image attestations verification failed`로 API-server admission webhook에서 거절됐다. 각 실패 fixture는 별도 image digest를 사용해 정상 VSA가 실패 VSA를 가리는 것을 방지했다. 이전 PolicyReport의 `wrong-subject` pass 값은 background evaluation 결과이므로 이 admission 증거에 사용하지 않는다.

## 기존 실패와 제한

- Trivy의 Docker 소켓 소스는 Docker daemon이 다중 아키텍처 content digest를 내보내지 못해 실패했다. `--image-src remote --insecure`로 같은 registry manifest를 직접 읽어 성공시켰다.
- Alpine 3.20.10은 지원 종료 경고가 있어 품질 기준용 이미지가 아니라 경로 검증 fixture다.
- 이 fixture는 로컬 정적 key·insecure registry를 사용한다. GHCR, keyless identity, Rekor transparency log는 이 로컬 admission 실험의 범위 밖이다.
