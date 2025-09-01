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
    cidr_blocks = ["0.0.0.0/0"]
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
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
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
  ami                   = "ami-0fc8aeaa301af7663"
  instance_type         = "t3.micro"
  subnet_id             = local.public_subnet_ids[0]
  key_name              = "bastion-key"
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.bastion_profile.name

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y unzip curl wget
              # AWS CLI v2 설치
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install
              # MariaDB 클라이언트 설치
              yum install -y mariadb105
              # git 설치
              sudo yum install -y git
              # kubectl 설치
              curl -LO https://dl.k8s.io/release/v1.33.0/bin/linux/amd64/kubectl
              chmod +x kubectl
              mv kubectl /usr/local/bin/
              # k9s 설치
              K9S_URL=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest \
                | grep "browser_download_url.*Linux_amd64.tar.gz" \
                | cut -d '"' -f 4 \
                | head -n 1)
              wget "$K9S_URL" -O k9s_Linux_amd64.tar.gz
              tar -xvf k9s_Linux_amd64.tar.gz
              mv k9s /usr/local/bin/
              rm -f k9s_Linux_amd64.tar.gz
              # AWS CLI 기본 설정
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
