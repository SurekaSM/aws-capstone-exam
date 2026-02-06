#####################################
# StreamLine Capstone - Single File #
#####################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

###############################
# Variables
###############################
variable "my_ip" {
  type        = string
  description = "CIDR allowed for SSH to web instances (e.g., 52.x.x.x/32)"
}

###############################
# VPC
###############################
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "streamline-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "streamline-igw"
  }
}

###############################
# Subnets
###############################
locals {
  azs           = ["us-east-1a", "us-east-1b"]
  public_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "streamline-public-${count.index + 1}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "streamline-private-${count.index + 1}"
    Tier = "private"
  }
}

###############################
# Route Tables
###############################
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "streamline-public-rt"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "streamline-private-rt"
  }
}

resource "aws_route_table_association" "private_assoc" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private_rt.id
}

###############################
# Security Groups
###############################
resource "aws_security_group" "alb_sg" {
  name   = "streamline-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
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
    Name = "streamline-alb-sg"
  }
}

resource "aws_security_group" "web_sg" {
  name   = "streamline-web-sg"
  {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "streamline-web-sg"
  }
}

resource "aws_security_group" "rds_sg" {
  name   = "streamline-rds-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "streamline-rds-sg"
  }
}

###############################
# Key Pair
###############################
resource "aws_key_pair" "kp" {
  key_name   = "streamline-key"
  public_key = file(pathexpand("~/.ssh/id_rsa.pub"))
}

###############################
# EC2 Instances
###############################
data "aws_ami" "al2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "web" {
  count                  = 2
  ami                    = data.aws_ami.al2.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[count.index].id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  key_name               = aws_key_pair.kp.key_name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd php git
    systemctl enable httpd
    systemctl start httpd
  EOF

  tags = {
    Name = "streamline-web-${count.index + 1}"
  }
}

###############################
# ALB
###############################
resource "aws_lb" "alb" {
  name               = "streamline-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb_sg.id]
}

resource "aws_lb_target_group" "tg" {
  name     = "streamline-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path = "/"
    matcher {
      http_code = "200-399"
    }
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_lb_target_group_attachment" "attach" {
  count            = 2
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}

###############################
# RDS
###############################
resource "aws_db_subnet_group" "db_subnets" {
  name       = "streamline-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "mysql" {
  identifier              = "streamline-mysql"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  db_name                 = "streamlinedb"
  username                = "admin"
  password                = "Admin12345!"
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  db_subnet_group_name    = aws_db_subnet_group.db_subnets.name
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
}

###############################
# Outputs
###############################
output "alb_dns" {
  value = aws_lb.alb.dns_name
}

output "ec2_ips" {
  value = aws_instance.web[*].public_ip
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}
