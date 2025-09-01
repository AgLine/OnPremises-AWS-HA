##########################
# VPC, subnet
##########################

locals {
  vpc_id            = ""
  public_subnet_ids = ["", ""]
  private_subnet_ids = ["", ""]
}

# 1. Elastic IP for NAT
resource "aws_eip" "nat_eip" {

}

# 2. NAT Gateway (퍼블릭 서브넷에 생성해야 함)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = ""  # 퍼블릭 서브넷 중 하나
  tags = {
    Name = "my-nat-gw"
  }
}

# 3. 프라이빗 라우팅 테이블 NAT Gateway 라우팅
resource "aws_route" "private" {
  route_table_id         = ""
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}
