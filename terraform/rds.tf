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

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
    description     = "Allow EKS cluster to access RDS"
  }

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.101.0/24", "10.0.102.0/24"]
    description = "Allow from specific VPC subnets"
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
# RDS 파라미터 그룹
##########################

resource "aws_db_parameter_group" "mariadb_pg" {
  name   = "mariadb-pg-with-binlog"
  family = "mariadb10.6"

  parameter {
    name  = "binlog_format"
    value = "ROW"
  }

  parameter {
    name  = "max_connections"
    value = "150"
  }

  parameter {
    name  = "wait_timeout"
    value = "300"
  }

  tags = {
    Name = "mariadb-pg-with-binlog"
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
  instance_class          = "db.t4g.micro"
  db_name                 = "mydb"
  username                = "admin"
  password                = ""  # 테스트용. 운영 시 Secrets Manager 사용 권장
  skip_final_snapshot     = true
  publicly_accessible     = false
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  db_subnet_group_name    = aws_db_subnet_group.mariadb_subnet_group.name
  parameter_group_name     = aws_db_parameter_group.mariadb_pg.name
  backup_retention_period  = 7

  tags = {
    Name = "mariadb"
  }
}
