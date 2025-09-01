##########################
# EKS 클러스터 IAM Role
##########################

resource "aws_iam_role" "eks_role" {
  name = "eksClusterRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_attach" {
  role       = aws_iam_role.eks_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

##########################
# EKS 클러스터
##########################

resource "aws_eks_cluster" "main" {
  name     = "my-eks-cluster"
  role_arn = aws_iam_role.eks_role.arn

  vpc_config {
    subnet_ids = local.private_subnet_ids
  }

  depends_on = [aws_iam_role_policy_attachment.eks_attach]
}

##########################
# EKS 노드 그룹 IAM Role & Instance Profile
##########################

resource "aws_iam_role" "eks_node_role" {
  name = "eksNodeGroupRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_policy" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  ])

  role       = aws_iam_role.eks_node_role.name
  policy_arn = each.value
}

# Karpenter에서 참조할 EKS 노드 인스턴스 프로파일을 명시적으로 생성
resource "aws_iam_instance_profile" "eks_node_profile" {
  name = "eksNodeGroupProfile"
  role = aws_iam_role.eks_node_role.name
}

##########################
# EKS Managed Node Group
##########################

resource "aws_eks_node_group" "node_group" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "my-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = local.private_subnet_ids

  scaling_config {
    desired_size = 1
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.small"]

  disk_size = 20

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_policy,
    aws_eks_cluster.main
  ]

  tags = {
    Name = "eks-node-group"
  }
}

##########################
# LBC IAM
##########################
data "aws_eks_cluster" "cluster" {
  name = aws_eks_cluster.main.name
}

data "aws_eks_cluster_auth" "cluster" {
  name = aws_eks_cluster.main.name
}

data "tls_certificate" "eks_cluster" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc_provider" {
  url           = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_cluster.certificates[0].sha1_fingerprint]
}

resource "aws_iam_policy" "lbc_policy" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  description = "Policy for AWS Load Balancer Controller"
  policy      = file("iam_policy_lbc.json")
}

resource "aws_iam_role" "lbc_sa_role" {
  name = "lbc-sa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Federated = aws_iam_openid_connect_provider.oidc_provider.arn },
      Action    = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = {
          "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lbc_attach" {
  role       = aws_iam_role.lbc_sa_role.name
  policy_arn = aws_iam_policy.lbc_policy.arn
}

##########################
# LBC 설치
##########################
resource "null_resource" "install_lbc" {
  depends_on = [
    aws_instance.bastion,
    aws_eks_cluster.main,
    aws_eks_node_group.node_group,
    aws_iam_role_policy_attachment.lbc_attach
  ]

  connection {
    type        = "ssh"
    host        = aws_instance.bastion.public_ip
    user        = "ec2-user"
    private_key = file("C:/.ssh/bastion-key.pem")
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "until aws eks --region ap-northeast-2 describe-cluster --name my-eks-cluster --query cluster.status --output text | grep -q 'ACTIVE'; do echo 'Waiting for EKS cluster to become active...'; sleep 30; done",
      "aws eks update-kubeconfig --region ap-northeast-2 --name my-eks-cluster",
      "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash",
      "helm repo add eks https://aws.github.io/eks-charts",
      "helm repo update",

      "kubectl create ns kube-system || true",

      # 기존 설치 완전히 정리
      "echo 'Cleaning up existing installation...'",
      "helm uninstall aws-load-balancer-controller -n kube-system || true",
      "kubectl delete deployment aws-load-balancer-controller -n kube-system || true",
      "kubectl delete serviceaccount aws-load-balancer-controller -n kube-system || true",
      "kubectl delete secrets -l name=aws-load-balancer-controller -n kube-system || true",

      <<-EOT
      cat <<EOF | kubectl apply -f -
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: aws-load-balancer-controller
        namespace: kube-system
        annotations:
          eks.amazonaws.com/role-arn: ${aws_iam_role.lbc_sa_role.arn}
        labels:
          app.kubernetes.io/name: aws-load-balancer-controller
          app.kubernetes.io/component: controller
      EOF
      EOT
      ,
      
      # Helm으로 설치 (서비스 어카운트는 생성하지 않고 기존 것 사용)
      "helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=my-eks-cluster --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller --set region=ap-northeast-2 --set vpcId=${local.vpc_id}"
    ]
  }
}

############################################
# Metrics Server Helm 설치
############################################
resource "null_resource" "install_metrics_server" {
  depends_on = [
    null_resource.install_karpenter
  ]

  connection {
    type        = "ssh"
    host        = aws_instance.bastion.public_ip
    user        = "ec2-user"
    private_key = file("C:/.ssh/bastion-key.pem")
  }

  provisioner "remote-exec" {
    inline = [
      "helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/",
      "helm repo update",
      "helm upgrade --install metrics-server metrics-server/metrics-server --namespace kube-system",
      "echo 'Metrics Server installation complete.'"
    ]
  }
}

############################################
# Karpenter IAM Role & Policy
############################################
resource "aws_iam_role" "karpenter_controller_role" {
  name = "KarpenterControllerRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Federated = aws_iam_openid_connect_provider.oidc_provider.arn
      },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = {
          "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
        }
      }
    }]
  })
}

data "aws_caller_identity" "current" {}

resource "aws_iam_policy" "karpenter_controller_policy" {
  name   = "KarpenterControllerPolicy"
  policy = templatefile("karpenter-controller-policy.json", {
    AWS_PARTITION  = "aws"
    AWS_ACCOUNT_ID = data.aws_caller_identity.current.account_id
    AWS_REGION     = "ap-northeast-2"
    CLUSTER_NAME   = aws_eks_cluster.main.name
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller_attach" {
  role       = aws_iam_role.karpenter_controller_role.name
  policy_arn = aws_iam_policy.karpenter_controller_policy.arn
}

############################################
# 서브넷과 보안그룹에 Karpenter 태그 추가
############################################
resource "aws_ec2_tag" "private_subnet_tags" {
  count       = length(local.private_subnet_ids)
  resource_id = local.private_subnet_ids[count.index]
  key         = "karpenter.sh/discovery"
  value       = aws_eks_cluster.main.name
}

# EKS 클러스터의 보안그룹에 태그 추가
resource "aws_ec2_tag" "cluster_security_group_tag" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = aws_eks_cluster.main.name
}

############################################
# Karpenter Helm 설치
############################################
resource "null_resource" "install_karpenter" {
  depends_on = [
    aws_instance.bastion,
    aws_eks_cluster.main,
    aws_eks_node_group.node_group,
    null_resource.install_lbc,
    aws_ec2_tag.private_subnet_tags,
    aws_ec2_tag.cluster_security_group_tag
  ]

  connection {
    type        = "ssh"
    host        = aws_instance.bastion.public_ip
    user        = "ec2-user"
    private_key = file("C:/.ssh/bastion-key.pem")
  }

  provisioner "remote-exec" {
    inline = [
      <<EOT
      # LBC deployment가 준비될 때까지 기다립니다.
      kubectl wait --namespace=kube-system deployment/aws-load-balancer-controller --for=condition=Available=True --timeout=5m
      
      helm repo add karpenter https://charts.karpenter.sh/
      helm repo update
      kubectl create namespace karpenter || true
      
      # Karpenter v1.6.0 설치
      helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.6.0 \
        --namespace karpenter \
        --create-namespace \
        --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${aws_iam_role.karpenter_controller_role.arn}" \
        --set "settings.clusterName=${aws_eks_cluster.main.name}" \
        --set "settings.clusterEndpoint=${aws_eks_cluster.main.endpoint}" \
        --set "settings.defaultInstanceProfile=${aws_iam_instance_profile.eks_node_profile.name}" \
        --set "tolerations[0].key=karpenter.sh/unschedulable" \
        --set "tolerations[0].operator=Exists" \
        --set "tolerations[0].effect=NoSchedule" \
        --set "replicas=1" \
        --set "topologySpreadConstraints[0].maxSkew=2" \
        --set "topologySpreadConstraints[0].topologyKey=topology.kubernetes.io/zone" \
        --set "topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway" \
        --set "topologySpreadConstraints[0].labelSelector.matchLabels.app\\.kubernetes\\.io/name=karpenter"
      EOT
    ]
  }
}

############################################
# Karpenter v1.6.0 NodePool & EC2NodeClass 생성
############################################
resource "null_resource" "karpenter_nodepool" {
  depends_on = [null_resource.install_karpenter]
  
  connection {
    type        = "ssh"
    host        = aws_instance.bastion.public_ip
    user        = "ec2-user"
    private_key = file("C:/.ssh/bastion-key.pem")
  }
  
  provisioner "remote-exec" {
    inline = [
      <<-EOT
      echo "Waiting for Karpenter controller to become available..."
      kubectl wait --namespace=karpenter deployment/karpenter --for=condition=Available=True --timeout=10m

      echo "Waiting for Karpenter CRDs to be established..."
      # CRD가 등록될 때까지 대기
      kubectl wait --for condition=established --timeout=300s crd/nodepools.karpenter.sh
      kubectl wait --for condition=established --timeout=300s crd/ec2nodeclasses.karpenter.k8s.aws

      # CRD 상태 확인
      echo "Checking CRD status..."
      kubectl get crd | grep karpenter

      # API 버전 확인
      echo "Checking available API versions..."
      kubectl api-resources | grep -E "(nodepool|ec2nodeclass)"

      # 추가 대기 시간
      sleep 30

      # EC2NodeClass 생성 (v1 API)
      echo "Creating EC2NodeClass..."
      cat <<EOF | kubectl apply -f -
      apiVersion: karpenter.k8s.aws/v1
      kind: EC2NodeClass
      metadata:
        name: default
      spec:
        # AMI 설정
        amiSelectorTerms:
          - alias: al2023@latest # Karpenter가 제공하는 AL2023 AMI 사용
        
        # 서브넷 선택
        subnetSelectorTerms:
          - tags:
              karpenter.sh/discovery: "${aws_eks_cluster.main.name}"
        
        # 보안 그룹 선택
        securityGroupSelectorTerms:
          - tags:
              karpenter.sh/discovery: "${aws_eks_cluster.main.name}"
        
        # IAM 인스턴스 프로파일
        instanceProfile: "${aws_iam_instance_profile.eks_node_profile.name}"
        
        # 사용자 데이터 스크립트
        userData: |
          #!/bin/bash
          /etc/eks/bootstrap.sh ${aws_eks_cluster.main.name}
          
          # 추가 설정
          echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
          sysctl -p /etc/sysctl.conf
        
        # 블록 디바이스 매핑
        blockDeviceMappings:
          - deviceName: /dev/xvda
            ebs:
              volumeSize: 20Gi
              volumeType: gp3
              deleteOnTermination: true
        
        # 메타데이터 서비스 설정
        metadataOptions:
          httpEndpoint: enabled
          httpProtocolIPv6: disabled
          httpPutResponseHopLimit: 2
          httpTokens: required
      EOF

      # EC2NodeClass 생성 확인
      if kubectl get ec2nodeclass default; then
        echo "EC2NodeClass created successfully"
      else
        echo "Failed to create EC2NodeClass"
        exit 1
      fi

      # 잠시 대기
      sleep 10

      # NodePool 생성 (v1 API)
      echo "Creating NodePool..."
      cat <<EOF | kubectl apply -f -
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: default
      spec:
        # 노드클래스 참조
        template:
          metadata:
            labels:
              intent: apps
              nodepool: default
          spec:
            # 노드 요구사항
            requirements:
              - key: kubernetes.io/arch
                operator: In
                values: ["amd64"]
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["on-demand"]
              - key: node.kubernetes.io/instance-type
                operator: In
                values: ["t3.small"]
            
            # EC2NodeClass 참조
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: default
        
        # 리소스 제한
        limits:
          cpu: 20
          memory: 40Gi
        
        # 노드 축출 정책
        disruption:
          # 빈 노드 축출 시간
          consolidationPolicy: WhenEmptyOrUnderutilized
          consolidateAfter: 5m
      EOF

      # NodePool 생성 확인
      if kubectl get nodepool default; then
        echo "NodePool created successfully"
      else
        echo "Failed to create NodePool"
        exit 1
      fi

      echo "Waiting for resources to be created..."
      sleep 15

      echo "Karpenter v1.6.0 NodePool and EC2NodeClass created successfully"

      # 생성된 리소스 확인
      echo "Checking created resources..."
      kubectl get nodepools -o wide
      kubectl get ec2nodeclasses -o wide

      EOT
    ]
  }
}

############################################
# HPA Pod limits5 테스트용
############################################
resource "null_resource" "hpa_pod" {
  depends_on = [
    null_resource.karpenter_nodepool,
    null_resource.install_metrics_server
  ]

  connection {
    type        = "ssh"
    host        = aws_instance.bastion.public_ip
    user        = "ec2-user"
    private_key = file("C:/.ssh/bastion-key.pem")
  }

  provisioner "remote-exec" {
    inline = [
      # 샘플 앱 배포
      <<-EOT
      cat <<EOF | kubectl apply -f -
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: php-apache
      spec:
        selector:
          matchLabels:
            run: php-apache
        replicas: 1
        template:
          metadata:
            labels:
              run: php-apache
          spec:
            containers:
            - name: php-apache
              image: registry.k8s.io/hpa-example
              ports:
              - containerPort: 80
              resources:
                limits:
                  cpu: 500m
                  memory: 256Mi
                requests:
                  cpu: 200m
                  memory: 128Mi
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: php-apache
        labels:
          run: php-apache
      spec:
        ports:
        - port: 80
        selector:
          run: php-apache
      EOF
      EOT
      ,
      # HPA 설정
      "kubectl autoscale deployment php-apache --cpu-percent=50 --min=1 --max=5"
    ]
  }
}
