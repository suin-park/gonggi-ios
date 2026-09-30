# 실물 제품 3DGS — 1차 구현 기록 (2026-09-30)

기준: `PRODUCT_3DGS_CAPTURE_DESIGN_20260929.md` 방식 A(전체 사진으로 카메라 위치 → 제품 마스크로 제품만 학습).
대상: 움직이지 않는 무광 제품 1종. 사진 수·결과 용량 목표는 강제하지 않고 기록만 한다. VGGT 미사용.

## 작업 트리

| 역할 | 경로 | 브랜치 |
|---|---|---|
| iOS | `C:\projects\gonggi-ios-product3dgs` | `feat/product-3dgs-capture` |
| 서버/워커 | `C:\projects\whik\apps\cloud-wt-product-3dgs` | `feat/product-3dgs` |

다른 브랜치로 덮어쓰거나 초기화하지 말 것. 푸시·배포·유료 CI·이미지 빌드·Pod는 승인 후.

## 커밋 (로컬, 미푸시)

| 저장소 / 브랜치 | 커밋 | 내용 |
|---|---|---|
| gonggi-ios `feat/product-3dgs-capture` | d273ba9 | 촬영 모드·object.json·업로드 captureKind·보관함 출처·링크 공유 |
| 〃 | **a4b92da** | 기록 탭에 제품 3D 촬영 상시 노출, ActiveFlow 분리, 구현 문서 |
| whik cloud `feat/product-3dgs` | 5f49cbfc | 워커 object 경로 |
| 〃 | 9dd86710, 488c2b26 | 서버 object 작업·뷰어·공유 |
| 〃 | **fab5e361** | 로그인 게이트, 제품 이미지 torch 2.5.1 레시피, 마스크/품질 보완 |

## 연결된 흐름

1. 앱 **기록** 탭 제품 섹션: `사진으로 3D 만들기` → `제품 3D 촬영` (항상 표시, 내부 도구/DEBUG 게이트 없음). TestFlight에서도 바로 진입.
2. 촬영: 받침면 탭 → 상자 조정 → 제품 주위 걷기(방위×높이 커버리지) → 마침 → `object.json` 포함 패키지.
3. 서버: 기존 로그인 + video-gaussian 생성 권한(`requireVideoGaussianJobCreateAllowed`). **별도 내부 계정 목록 없음.** 새 크레딧/결제 정책 없음. 프로필 `object_capture_fastergs_v1`. 전용 RunPod 엔드포인트만 사용.
4. 워커: COLMAP(전체 사진) → SAM 2.1 마스크(제품 이미지) → 사전 판정 → Faster-GS 알파 → 잘라내기 → 실루엣 판정.
5. 결과: 출처 배지, 품질 판정, 궤도 뷰어, 공유 링크.

## SAM 2 / 제품 워커 이미지

| | 공간 `Dockerfile.cuda` | 제품 (같은 Dockerfile + build-arg) |
|---|---|---|
| Torch | 2.4.1+cu118 | **2.5.1+cu118** (SAM 2.1 선언과 정합) |
| SAM 2 | 설치 안 함 (`INSTALL_OBJECT_SAM2=0` → `NOT_IN_IMAGE`) | 필수 (`INSTALL_OBJECT_SAM2=1`, `GONGGI_REQUIRE_SAM2=1`) |
| Faster-GS/gsplat | 2.4.1 기준 빌드 | 동일 레시피에서 2.5.1에 대해 재컴파일 |

문서: `workers/video-gaussian/docs/PRODUCT_WORKER_IMAGE.md`, 레시피 포인터 `Dockerfile.cuda.object`.  
이미지 빌드·GPU 스모크는 **아직 미실행**.

## 품질 실패 구분

| 판정 | 시점 | 기준 | 처리 |
|---|---|---|---|
| mask_provider_unavailable | 학습 전 | SAM 상태 `INSTALL_FAILED` / `NOT_IN_IMAGE` / import·체크포인트 실패 | `OBJECT_MASK_PROVIDER_UNAVAILABLE` |
| mask_failed | 학습 전 | 상자 보이는 사진 중 30% 초과 마스크 실패 | `OBJECT_MASK_FAILED` |
| object_truncated | 학습 전 | **윗면·옆면·윗모서리만** 3장 미만(밑면·받침면 코너 요구 안 함) | `OBJECT_TRUNCATED` |
| (경고) many_masks_touch_frame_edge | 학습 전 | 가장자리 접촉 비율 > 0.35 (**advisory**, 작업 실패 아님, 미보정) | 기록만 |
| object_truncated / background_residue | 학습 후 | 실루엣 덮임/잔여 임계 | 결과 유지 + "품질 확인 필요" |

마스크: 상자 **중심이 아닌** 윗쪽/옆면 프롬프트 점 사용(다리 사이 빈 공간 오선택 완화).  
기록: `masks.frameCorrespondence`(photo↔maskFile↔status), 학습 훅 `view_alpha` + `objectMaskHooks.applied` / `photoMaskPairsSample`.

## 로컬 검증 (이 세션)

- 워커: `test_object_capture` + `test_dependency_pins` 통과.
- 서버: `objectCapture.test.ts` 8 통과.
- iOS: 코드·단위 테스트만 작성. **컴파일/Xcode/CI 미실행.**

## 확인하지 못한 것

- iOS 실기기 빌드·촬영, AR 상자 정렬.
- 제품 워커 이미지 빌드, torch 2.5.1에서 Faster-GS/gsplat GPU 동작, SAM 2 CUDA 추론.
- 서버 배포·전용 엔드포인트 env, 실제 1건 생성.
- compressed PLY, 뷰어 고도 제한, 턴테이블 미리보기.

## 남은 일 (승인 후 실행 순서 — 아래 「다음 실행 순서」 참고)

유료 CI / 이미지 빌드 / Pod / TestFlight / 운영 배포는 아직 하지 않음.

실제 제품 촬영 결과로 성공 여부를 판단한다. TestFlight 빌드만으로 검증 완료로 보고하지 않는다.
