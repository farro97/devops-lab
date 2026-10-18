# -----------------------------------------------------------------------------
# VPC MODULE
# A reusable network: public + private subnets spread across availability
# zones, an Internet Gateway, and an optional NAT Gateway.
#
#   Internet
#      |
#   [Internet Gateway]
#      |
#   Public subnets  (load balancers, NAT Gateway)  -> route 0.0.0.0/0 to IGW
#      |
#   Private subnets (app containers, databases)    -> route 0.0.0.0/0 to NAT
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"

  # Only regular AZs, never opt-in Local Zones or Wavelength Zones.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # cidrsubnet() carves smaller ranges out of the VPC range.
  # With a /16 VPC and newbits = 8, each subnet is a /24 (256 addresses).
  #   public:  10.0.0.0/24,   10.0.1.0/24, ...
  #   private: 10.0.100.0/24, 10.0.101.0/24, ...
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 8, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 8, i + 100)]

  # One NAT for everything (cheap) or one per AZ (resilient).
  nat_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.az_count) : 0
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true # needed for RDS endpoints, ECS service discovery, etc.

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# --- Public subnets ----------------------------------------------------------

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Don't give every instance a public IP automatically. When you do want one
  # (e.g. the Phase 2 Ansible lab EC2), set associate_public_ip_address = true
  # on that instance so the choice is explicit.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-public-${local.azs[count.index]}"
    Tier = "public"
    # Lets the AWS Load Balancer Controller find these subnets in Phase 4 (EKS).
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private subnets ---------------------------------------------------------

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${var.name}-private-${local.azs[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# --- NAT Gateway (optional, costs money) -------------------------------------
# Lets things in private subnets reach the internet (e.g. to pull images)
# without being reachable from the internet. Billed hourly + per GB.

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${var.name}-nat-${count.index}" }

  depends_on = [aws_internet_gateway.this]
}

# One private route table per AZ, so each AZ can use its own NAT if you
# switch single_nat_gateway off later.
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

resource "aws_route" "private_nat" {
  count = local.nat_count > 0 ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- Free S3 gateway endpoint ------------------------------------------------
# Private-subnet traffic to S3 (including ECR image layers) skips the NAT,
# which saves NAT data charges. Gateway endpoints are free.

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "${var.name}-s3" }
}

# --- Lock down the default security group -----------------------------------
# AWS creates a default SG that allows all traffic between its members.
# Removing its rules is a common security-scanner finding (Checkov CKV2_AWS_12).

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-locked" }
}
