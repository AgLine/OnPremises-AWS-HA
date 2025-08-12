provider "aws" {
  region = "ap-northeast-2"

  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key 
}

##########################
# VPC, subnet
##########################

locals {
  vpc_id            = "vpc-0c1efa92d2dcaab5d"
  public_subnet_ids = ["subnet-03c9ce4682ce31c58", "subnet-088dd7313097bb254"]
  private_subnet_ids = ["subnet-0b875e4592b547182", "subnet-0ee39c44989dfd65c"]
}

# 1. Elastic IP for NAT
resource "aws_eip" "nat_eip" {

}

# 2. NAT Gateway (퍼블릭 서브넷에 생성해야 함)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = "subnet-03c9ce4682ce31c58"  # 퍼블릭 서브넷 중 하나
  tags = {
    Name = "my-nat-gw"
  }
}

# 3. 프라이빗 라우팅 테이블 NAT Gateway 라우팅
resource "aws_route" "private" {
  route_table_id         = "rtb-0266cb8f8101876a9"
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

##########################
# Bastion 보안 그룹
##########################

resource "aws_security_group" "bastion_sg" {
  name        = "bastion-sg"
  description = "Allow SSH"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # 운영 시 제한 필요
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "bastion-sg"
  }
}
resource "aws_iam_role" "bastion_role" {
  name = "bastionRole"

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

resource "aws_iam_role_policy_attachment" "bastion_policy" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", # 컨테이너 이미지 접근 시 필요
    "arn:aws:iam::aws:policy/AdministratorAccess"
  ])
  role       = aws_iam_role.bastion_role.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "bastion_profile" {
  name = "bastionInstanceProfile"
  role = aws_iam_role.bastion_role.name
}

##########################
# Bastion EC2 인스턴스
##########################

resource "aws_instance" "bastion" {
  ami                         = "ami-0fc8aeaa301af7663"  # Amazon Linux 2023 AMI 2023.8.20250721.2 x86_64 HVM kernel-6.1
  instance_type               = "t3.micro"
  subnet_id                   = local.public_subnet_ids[0]
  key_name                    = "bastion-key"
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.bastion_profile.name

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y unzip curl
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install
              yum install -y mariadb105
              curl -LO https://dl.k8s.io/release/v1.33.0/bin/linux/amd64/kubectl
              chmod +x kubectl
              mv kubectl /usr/local/bin/
              mkdir -p /home/ec2-user/.aws
              cat > /home/ec2-user/.aws/credentials <<EOL
              [default]
              aws_access_key_id = ${var.aws_access_key_id}
              aws_secret_access_key = ${var.aws_secret_access_key}
              EOL
              cat > /home/ec2-user/.aws/config <<EOL
              [default]
              region = ap-northeast-2
              output = json
              EOL
              chown -R ec2-user:ec2-user /home/ec2-user/.aws
              EOF

  tags = {
    Name = "bastion"
  }
}

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
# EKS 노드 그룹 IAM Role
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
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  ])

  role       = aws_iam_role.eks_node_role.name
  policy_arn = each.value
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
# RDS 보안 그룹 (MariaDB용)
##########################

resource "aws_security_group" "rds_sg" {
  name   = "rds-sg"
  vpc_id = local.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]  # Bastion에서 접근 허용
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-sg"
  }
}

##########################
# RDS 서브넷 그룹
##########################

resource "aws_db_subnet_group" "mariadb_subnet_group" {
  name       = "mariadb-subnet-group"
  subnet_ids = local.private_subnet_ids

  tags = {
    Name = "mariadb-subnet-group"
  }
}

##########################
# RDS 인스턴스 (MariaDB)
##########################

resource "aws_db_instance" "mariadb" {
  identifier              = "mariadb-instance"
  allocated_storage       = 20
  engine                  = "mariadb"
  engine_version          = "10.6"
  instance_class          = "db.t3.micro"
  db_name                    = "mydb"
  username                = "admin"
  password                = "MySecurePass123!"  # 테스트용. 운영 시 Secrets Manager 사용 권장
  skip_final_snapshot     = true
  publicly_accessible     = false
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  db_subnet_group_name    = aws_db_subnet_group.mariadb_subnet_group.name

  tags = {
    Name = "mariadb"
  }
}

##########################
# Bastion에서 Kubeconfig 설정
##########################
resource "null_resource" "configure_bastion" {
  depends_on = [
    aws_eks_cluster.main,
    aws_instance.bastion,
    aws_eks_node_group.node_group
  ]

  connection {
    type        = "ssh"
    host        = aws_instance.bastion.public_ip
    user        = "ec2-user"
    private_key = file("C:/Users/kosa2/.ssh/bastion-key.pem")
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      # AWS CLI로 Kubeconfig 설정
      "until aws eks --region ap-northeast-2 describe-cluster --name my-eks-cluster --query cluster.status --output text | grep -q 'ACTIVE'; do echo 'Waiting for EKS cluster to become active...'; sleep 30; done",
      "aws eks update-kubeconfig --region ap-northeast-2 --name my-eks-cluster"
    ]
  }
}
