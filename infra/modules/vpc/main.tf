terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "code-keeper-${var.environment}-vpc"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "code-keeper-${var.environment}-igw"
    Environment = var.environment
  }
}

# Public Subnets
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  # Nothing launches in the public subnets (the NAT gateway holds the EIP and the
  # ALB is internet facing), so instances must not inherit a public address.
  map_public_ip_on_launch = false

  tags = {
    Name        = "code-keeper-${var.environment}-public-${count.index + 1}"
    Environment = var.environment
    Tier        = "Public"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "code-keeper-${var.environment}-nat-eip"
    Environment = var.environment
  }
}

# NAT Gateway for private subnets outbound internet access
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "code-keeper-${var.environment}-nat"
    Environment = var.environment
  }
  depends_on = [aws_internet_gateway.gw]
}

# Private Application Subnets
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name        = "code-keeper-${var.environment}-private-${count.index + 1}"
    Environment = var.environment
    Tier        = "Private"
  }
}

# Isolated Database Subnets
resource "aws_subnet" "database" {
  count             = length(var.database_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name        = "code-keeper-${var.environment}-database-${count.index + 1}"
    Environment = var.environment
    Tier        = "Database"
  }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name        = "code-keeper-${var.environment}-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name        = "code-keeper-${var.environment}-private-rt"
    Environment = var.environment
  }
}

resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "code-keeper-${var.environment}-database-rt"
    Environment = var.environment
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "database" {
  count          = length(aws_subnet.database)
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# Lock down the VPC default security group, which otherwise allows all traffic.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "code-keeper-${var.environment}-default-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# VPC Flow Logs for network forensics and anomaly detection.
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/code-keeper-${var.environment}/flow-logs"
  retention_in_days = 30

  tags = {
    Name        = "code-keeper-${var.environment}-vpc-flow-logs"
    Environment = var.environment
  }
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name_prefix        = "code-keeper-${var.environment}-vpc-flow-logs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role.json

  tags = {
    Name        = "code-keeper-${var.environment}-vpc-flow-logs-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name_prefix = "code-keeper-${var.environment}-vpc-flow-logs-"
  role        = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteFlowLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
      },
      {
        Sid      = "DescribeLogDelivery"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "logs:DescribeLogStreams"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id

  tags = {
    Name        = "code-keeper-${var.environment}-vpc-flow-log"
    Environment = var.environment
  }
}
