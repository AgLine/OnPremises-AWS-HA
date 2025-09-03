# 온프레미스 ↔ AWS 이중화 프로젝트 (진행중)
---
## 📌 프로젝트 개요
- **기간**: 2025.08 ~ 진행중
- **Backend**: `Spring Boot`
- **Frontend**: `React`
- **DB**: `MariaDB`, `AWS DMS`
- **lac**: `Terraform`
- **Cloud**: `AWS EKS`, `AWS Route53`
- **OnPremis**: `ESXi`
- **CI/CD**: `Jenkins`, `ArgoCD`
- **Monitoring**: `K9s`
---
## 🎯 프로젝트 목적
온프레미스 서버와 AWS 클라우드 환경을 연동하여 서비스의 **가용성 확보 및 안정적 이중화(Redundancy)**를 목표로 합니다.
- 온프레미스 서버 장애 시 AWS EKS 환경으로 자동 전환
- 트래픽 증가 시 클러스터 확장을 통한 서비스 안정화

---
## 👥 역할 분담
### 🙋‍♂️ 내 기여도
| 역할 | 상세 내용 |
|------|----------|
|AWS 환경셋팅|VPC, EIP, NAT Gateway 를 테라폼으로 구성|
|AWS EKS|Kubernetes 클러스터, 노드그룹 테라폼으로 생성|
|EKS AutoScaling|HPA-Pod AutoScaling, Karpenter-Node AutoScaling|
|AWS DMS|소스,타겟 엔드포인트생성후 태스크를 통해 동기화진행|
|AWS Route53| 온프레미스와 AWS로의 트래픽 분산|
|환경변수 관리|AWS CLI `aws configure` 자격 증명을 환경변수로 분리하여 보안 강화|
### 👥 팀 구성 및 역할 분담
- **본인** : AWS EKS, AWS DMS, AWS Route53
- **팀원** : ESXi
- **팀원** : Istio
- **팀원** : 데모앱, CI/CD

---
## 🛠 주요 기능

### 1. 서비스 이중화
- 온프레미스 장애 시 AWS EKS 환경으로 자동 전환
- 지속적인 트래픽 분산 및 클러스터 확장 가능

### 2. AWS DMS
- 소스엔드포인트 -> RDS
- 타겟엔드포인트 -> On-Premise DB
- 온프레미스 MariaDB → AWS RDS (MariaDB) 간 데이터 동기화

### 3. EKS AutoScaling
#### HPA
- Pod CPU/Memory 사용량 기반 자동 확장
- 트래픽 급증 상황에서 안정적으로 서비스 처리 가능
#### Karpenter
- 클러스터 리소스 부족 시 노드를 자동으로 생성 및 제거
- 필요 없는 리소스는 자동 축소하여 클라우드 비용 최적화

### 4. AWS Configure 환경변수 관리
- `aws configure` 자격 증명을 환경변수로 추출
- 코드와 자격 증명 정보를 분리하여 보안성 강화 및 재사용성 확보

---
## 📖 배운 점 & 느낀 점
### Terraform
- Terraform을 활용해 AWS 리소스를 코드로 관리하고, 근무 시간(09:00~18:00) 동안만 클러스터를 운영하도록 하였습니다.
- 이를 통해 불필요한 사용 시간 동안 발생할 수 있는 클라우드 비용을 약 60~70% 절감할 수 있었습니다.

### Karpenter
- 설치시 버전을 명시하지않으면 최신버전으로 설치된다고 알고있었습니다.하지만 버전이 맞지않은 에러가 발생했습니다.
- Helm 공식 차트에는 최신 Karpenter 버전이 제공되지 않아, OCI(OCI Registry)에서 helm upgrade로 설치하는 방법으로 해결했습니다.
---
## 📷 시스템 구조
<img width="1685" height="1032" alt="image" src="https://github.com/user-attachments/assets/9223db6e-a986-4a9f-adc8-f2af74a69a10" />
