# 온프레미스 ↔ AWS 이중화 프로젝트 
## 📌 프로젝트 개요
- **기간**: 2025.08 ~ 2025.09
- **Backend**: `Spring Boot`
- **Frontend**: `React`
- **DB**: `MariaDB`, `AWS DMS`
- **lac**: `Terraform`
- **Cloud (AWS)**: `EKS`, `Route53`, `ALB`, `CloudWatch`, `Lambda`
- **OnPremis**: `ESXi`
- **CI/CD**: `Jenkins`, `ArgoCD`
- **Monitoring**: `K9s`
---
## 🎯 프로젝트 목적
온프레미스 서버와 AWS 클라우드 환경을 연동하여 서비스의 **가용성 확보 및 안정적 이중화(Redundancy)** 를 목표로 합니다.
- 온프레미스 서버 장애 발생 시 AWS EKS 환경으로 자동 전환(Failover)
- 트래픽 급증 시 EKS 클러스터의 동적 확장을 통한 안정적인 서비스 운영

---
## 👥 역할 분담
### 🙋‍♂️ 내 기여도
| 역할 | 상세 내용 |
|------|----------|
|AWS 환경셋팅|`Terraform`을 사용하여 VPC, Subnet, NAT Gateway 등 전체 네트워크 환경 구성|
|AWS EKS|`Terraform`을 활용하여 Kubernetes 클러스터 및 노드 그룹 생성 자동화|
|EKS AutoScaling|HPA를 통한 Pod 단위 스케일링, Karpenter를 이용한 노드 단위 스케일링 구성|
|AWS DMS|소스(RDS), 타겟(On-Premise) 엔드포인트를 구성하고 복제 태스크를 생성하여 데이터 동기화|
|보안|`aws configure` 자격 증명을 환경변수로 분리하여 보안 강화 및 관리 효율 증대|
|AWS Route53| 호스팅 영역에 A 레코드를 생성하여 ALB와 도메인을 연결하고 트래픽 라우팅 설정|
|ALB|가중치 기반 라우팅 규칙을 설정하여 트래픽 분산 (AWS 60%, On-premise 40%)|
|AWS CloudWatch|`RequestCount` 지표를 기준으로 온프레미스 장애 감지용 경보 생성|
|AWS Lambda| CloudWatch 경보 발생 시 ALB 리스너 규칙을 자동으로 변경하여 Failover 수행|
### 👥 팀 구성 및 역할 분담
- **본인** : AWS 인프라 총괄 (EKS, DMS, Route 53 등)
- **팀원** : On-Premise 환경 구축 (ESXi)
- **팀원** : Istio
- **팀원** : 데모 애플리케이션 개발 및 CI/CD 파이프라인 구축

---
## 🛠 주요 기능

### 1. 서비스 이중화 및 자동 Failover
- 온프레미스 장애 발생 시 CloudWatch 경보와 Lambda를 통해 트래픽을 AWS EKS 환경으로 자동 전환합니다.
- 평상시에는 Route 53과 ALB를 통해 온프레미스와 AWS 환경으로 트래픽을 지속적으로 분산합니다.

### 2. AWS DMS
- 소스 엔드포인트를 RDS, 타겟 엔드포인트를 On-Premise로 설정합니다
- DMS 복제 태스크를 통해 온프레미스 MariaDB와 AWS RDS(MariaDB) 간 데이터를 실시간으로 동기화하여 데이터 정합성을 유지합니다.

### 3. EKS AutoScaling
#### HPA
- Pod의 CPU/Memory 사용량에 따라 Pod 수를 자동으로 확장/축소하여 트래픽 변화에 유연하게 대응합니다.
#### Karpenter
- 클러스터의 리소스 부족을 감지하여 필요한 만큼 노드(EC2)를 자동으로 프로비저닝하고, 유휴 시에는 제거하여 비용을 최적화합니다.

### 4. AWS 자격 증명 보안 강화
- `aws configure` 로 설정된 Access Key를 코드에 하드코딩하지 않고 환경변수로 분리했습니다.
- 이를 통해 코드와 자격 증명을 분리하여 보안성을 강화하고 재사용성을 확보했습니다.

### 5. AWS Route 53 기반 DNS 라우팅
- 도메인 호스팅 영역을 생성하고, A 레코드(별칭)를 통해 사용자의 요청이 AWS ALB로 라우팅되도록 구성했습니다.

### 6. ALB를 이용한 트래픽 분산
- 하나의 리스너 규칙 내에 온프레미스와 AWS 대상 그룹을 모두 등록하고, 가중치(Weight) 를 On-Premise 40: AWS 60으로 설정하여 트래픽을 분산 처리합니다.

### 7. CloudWatch를 통한 장애 감지
-  ALB의 RequestCount가 특정 임계치 이상으로 증가하는 것을 감지하는 경보를 생성합니다.
- 경보 상태(ALARM) 가 되면 `increase-aws-traffic` Lambda 함수를 실행하고, 정상 상태(OK) 로 복귀하면 `reset-default-traffic` Lambda 함수를 실행하도록 설정했습니다.

### 8. AWS Lambda
- `increase-aws-traffic` 가중치(Weight)를 On-Premise 0: AWS 100 으로 변경하여 AWS가 모든트래픽을 처리합니다.
- `reset-default-traffic` 가중치(Weight)를 On-Premise 40: AWS 60 으로 변경하여 On-Premise와 AWS가 트래픽을 분산처리합니다.
---
## 📖 배운 점 & 느낀 점
### Terraform
- Terraform을 활용해 인프라를 코드로 관리하고 특정 시간(09:00~18:00)에만 EKS 클러스터가 동작하도록 자동화했습니다.
- 이를 통해 개발 및 테스트 단계에서 발생하는 불필요한 클라우드 비용을 약 60~70% 절감하며 IaC의 비용 최적화 효과를 직접 경험했습니다.

### Karpenter
- `helm install` 시 버전을 명시하지 않으면 최신 버전이 설치될 것으로 예상했으나, EKS 클러스터 버전과 호환되지 않는 오류가 발생했습니다.
- 원인은 Helm 공식 차트가 최신 버전을 지원하지 않았기 때문이었습니다. OCI(Open Container Initiative) 레지스트리 경로(oci://public.ecr.aws/karpenter/...)를 사용하여 정확한 버전을 명시적으로 설치함으로써 문제를 해결했습니다.
- https://velog.io/@agline/EKS-HPA-Karpenter-autoscailing

### AWS DMS
- 안정적인 복제를 위해 binlog_format=ROW 설정이 필수였지만, RDS 파라미터 그룹에서 변경해도 적용되지 않았습니다.
- 근본적인 원인은 비용 절감을 위해 비활성화했던 '자동 백업' 기능이었습니다. RDS는 자동 백업이 활성화되어야 Binlog가 정상 기록된다는 점을 파악하고, 백업 기능을 활성화하여 성공적으로 파라미터 변경 및 데이터 동기화를 완료했습니다.

### AWS ALB
- 가중치 기반 라우팅 규칙을 테스트할 때, 우선순위가 높은 AWS 측으로만 트래픽이 고정되는 현상이 발생했습니다.
- 초기에는 AWS와 On-premise에 대한 규칙을 별개로 생성했던 것이 원인이었습니다. ALB의 가중치 라우팅은 하나의 규칙 내에 여러 대상 그룹을 등록해야 한다는 것을 깨닫고, 규칙을 하나로 통합하여 의도한 대로 트래픽이 분산되도록 수정했습니다.

---
## 📷 시스템 구조
<img width="1685" height="1032" alt="image" src="https://github.com/user-attachments/assets/9223db6e-a986-4a9f-adc8-f2af74a69a10" />
