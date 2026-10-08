resource "aws_vpc" "runner" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.resource_prefix}-runner"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_internet_gateway" "runner" {
  vpc_id = aws_vpc.runner.id

  tags = {
    Name = "${var.resource_prefix}-runner"
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = startswith(var.availability_zone, var.aws_region)
      error_message = "availability_zone must belong to the reviewed AWS region."
    }
  }
}

resource "aws_subnet" "runner" {
  vpc_id                  = aws_vpc.runner.id
  cidr_block              = var.runner_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.resource_prefix}-runner"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route_table" "runner" {
  vpc_id = aws_vpc.runner.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.runner.id
  }

  tags = {
    Name = "${var.resource_prefix}-runner"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route_table_association" "runner" {
  subnet_id      = aws_subnet.runner.id
  route_table_id = aws_route_table.runner.id
}

resource "aws_security_group" "runner" {
  name        = "${var.resource_prefix}-runner-no-ingress"
  description = "No inbound access; outbound only for SSM, S3, Git and package endpoints"
  vpc_id      = aws_vpc.runner.id

  egress {
    description = "Required provider and package egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.resource_prefix}-runner-no-ingress"
  }

  lifecycle {
    prevent_destroy = true
  }
}
