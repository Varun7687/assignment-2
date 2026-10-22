# Northwind nightly reporting server - all Terraform, HTML, and EC2 setup in one file.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "northwind-reporting"
      ManagedBy = "terraform"
    }
  }
}

variable "aws_region" {
  description = "AWS region for all regional resources."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability Zone for this single-AZ learning deployment."
  type        = string
  default     = "us-east-1a"
}

variable "vpc_cidr" {
  description = "CIDR block for the Northwind VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the bastion and NAT Gateway subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private reporting-server subnet."
  type        = string
  default     = "10.0.2.0/24"
}

variable "admin_cidr" {
  description = "Your current public IPv4 address in CIDR notation, for example 203.0.113.10/32."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a valid IPv4 CIDR, preferably your address with /32."
  }
}

variable "key_pair_name" {
  description = "Existing EC2 key-pair name to use for both instances. Terraform does not create or store the private key."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the bastion and reporting server."
  type        = string
  default     = "t3.micro"
}

variable "bucket_name" {
  description = "Globally unique private S3 bucket name."
  type        = string
  default     = "northwind-reporting-reports"
}

variable "sns_topic_name" {
  description = "SNS topic name for report-ready notifications."
  type        = string
  default     = "nightly-report-ready"
}

variable "notification_email" {
  description = "Email address for the SNS subscription. The subscription must be confirmed from email after apply."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    error_message = "notification_email must be a valid email address."
  }
}

variable "cron_schedule" {
  description = "Five-field cron expression. Use every 15 minutes only for a short test window."
  type        = string
  default     = "0 0 * * *"
}

locals {
  reporting_user_data = <<-USERDATA
  #!/bin/bash
  set -euo pipefail
  umask 077
  export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  dnf install -y cronie awscli2
  install -d -m 700 /var/lib/northwind

  cat > /usr/local/bin/northwind-nightly-report.sh <<'REPORT_SCRIPT'
  #!/bin/bash
  set -euo pipefail
  umask 077
  export PATH="/usr/local/bin:/usr/bin:/bin"

  AWS_REGION="${var.aws_region}"
  BUCKET="${aws_s3_bucket.reports.bucket}"
  TOPIC_ARN="${aws_sns_topic.report_ready.arn}"
  REPORT_DIR="/var/lib/northwind"
  REPORT_DATE="$(date -u +%Y-%m-%d)"
  REPORT_FILE="$REPORT_DIR/$REPORT_DATE.txt"
  OBJECT_KEY="reports/$REPORT_DATE.txt"

  mkdir -p "$REPORT_DIR"

  cat > "$REPORT_FILE" <<REPORT
  Northwind Nightly Sales Report
  =============================
  Date (UTC): $REPORT_DATE
  Generated (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')
  Hostname: $(hostname)

  Disk Usage:
  $(df -h)

  Sample Sales Figures (fake data):
  Product A: INR 12000
  Product B: INR 8500
  Product C: INR 15000
  REPORT

  aws s3api put-object \
    --bucket "$BUCKET" \
    --key "$OBJECT_KEY" \
    --body "$REPORT_FILE" \
    --server-side-encryption AES256 \
    --content-type text/plain \
    --region "$AWS_REGION"

  PRESIGNED_URL="$(aws s3 presign "s3://$BUCKET/$OBJECT_KEY" \
    --expires-in 3600 \
    --region "$AWS_REGION")"

  printf -v MESSAGE 'Northwind report ready.\n\nReport key: %s\nS3 location: s3://%s/%s\n\nDownload link (valid for up to 1 hour):\n%s' \
    "$OBJECT_KEY" "$BUCKET" "$OBJECT_KEY" "$PRESIGNED_URL"

  aws sns publish \
    --topic-arn "$TOPIC_ARN" \
    --subject "Northwind report ready" \
    --message "$MESSAGE" \
    --region "$AWS_REGION"

  echo "Uploaded: s3://$BUCKET/$OBJECT_KEY"
  echo "SNS notification sent with the report key and download link."
  REPORT_SCRIPT

  chmod 700 /usr/local/bin/northwind-nightly-report.sh
  touch /var/log/northwind-nightly-report.log
  chmod 600 /var/log/northwind-nightly-report.log

  cat > /etc/cron.d/northwind-reporting <<'CRON'
  SHELL=/bin/bash
  PATH=/usr/local/bin:/usr/bin:/bin
  ${var.cron_schedule} root /usr/local/bin/northwind-nightly-report.sh >> /var/log/northwind-nightly-report.log 2>&1
  CRON

  chmod 644 /etc/cron.d/northwind-reporting
  systemctl enable --now crond
  USERDATA
}

data "aws_caller_identity" "current" {}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -------------------- Network --------------------

resource "aws_vpc" "northwind" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "northwind-reporting-vpc-assignment-02"
  }
}

resource "aws_internet_gateway" "northwind" {
  vpc_id = aws_vpc.northwind.id

  tags = {
    Name = "northwind-reporting-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.northwind.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "northwind-public-subnet"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.northwind.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "northwind-private-subnet"
    Tier = "private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.northwind.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.northwind.id
  }

  tags = {
    Name = "northwind-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.northwind]

  tags = {
    Name = "northwind-nat-eip"
  }
}

resource "aws_nat_gateway" "northwind" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  depends_on = [aws_internet_gateway.northwind]

  tags = {
    Name = "northwind-reporting-nat"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.northwind.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.northwind.id
  }

  tags = {
    Name = "northwind-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# -------------------- Security groups --------------------

resource "aws_security_group" "bastion" {
  name        = "northwind-bastion-sg"
  description = "SSH to the bastion only from the administrator address."
  vpc_id      = aws_vpc.northwind.id

  ingress {
    description = "SSH from the administrator public IP."
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "SSH from bastion to the private reporting subnet."
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  tags = {
    Name = "northwind-bastion-sg"
  }
}

resource "aws_security_group" "reporting" {
  name        = "northwind-reporting-sg"
  description = "SSH from the bastion and HTTPS egress for the private report server."
  vpc_id      = aws_vpc.northwind.id

  ingress {
    description     = "SSH only from the bastion security group."
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    description = "HTTPS to package repositories and AWS APIs through NAT."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "northwind-reporting-sg"
  }
}

# -------------------- Private subnet NACL --------------------

resource "aws_network_acl" "private" {
  vpc_id = aws_vpc.northwind.id

  tags = {
    Name = "northwind-private-nacl"
  }
}

resource "aws_network_acl_association" "private" {
  network_acl_id = aws_network_acl.private.id
  subnet_id      = aws_subnet.private.id
}

resource "aws_network_acl_rule" "private_ingress_ssh" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.public_subnet_cidr
  from_port      = 22
  to_port        = 22
}

resource "aws_network_acl_rule" "private_ingress_ephemeral_tcp" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_ingress_ephemeral_udp" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 120
  egress         = false
  protocol       = "udp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_egress_dns_udp" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = true
  protocol       = "udp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 53
  to_port        = 53
}

resource "aws_network_acl_rule" "private_egress_dns_tcp" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 53
  to_port        = 53
}

resource "aws_network_acl_rule" "private_egress_https" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 120
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "private_egress_ephemeral_tcp" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 130
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.public_subnet_cidr
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_egress_ephemeral_udp" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 140
  egress         = true
  protocol       = "udp"
  rule_action    = "allow"
  cidr_block     = var.public_subnet_cidr
  from_port      = 1024
  to_port        = 65535
}

# -------------------- S3 and SNS --------------------

resource "aws_s3_bucket" "reports" {
  bucket        = var.bucket_name
  force_destroy = false

  tags = {
    Name = "northwind-reporting-reports"
  }
}

resource "aws_s3_bucket_ownership_controls" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "reports_tls_only" {
  bucket = aws_s3_bucket.reports.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.reports.arn,
        "${aws_s3_bucket.reports.arn}/*"
      ]
      Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.reports]
}

resource "aws_sns_topic" "report_ready" {
  name = var.sns_topic_name
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.report_ready.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# -------------------- IAM --------------------

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "reporting" {
  name               = "northwind-reporting-role-assignment-02"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "reporting_permissions" {
  statement {
    sid    = "ReportObjectAccess"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject"
    ]

    resources = ["${aws_s3_bucket.reports.arn}/reports/*"]
  }

  statement {
    sid       = "PublishReportReadyNotification"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.report_ready.arn]
  }
}

resource "aws_iam_policy" "reporting_permissions" {
  name   = "northwind-reporting-permissions"
  policy = data.aws_iam_policy_document.reporting_permissions.json
}

resource "aws_iam_role_policy_attachment" "reporting_permissions" {
  role       = aws_iam_role.reporting.name
  policy_arn = aws_iam_policy.reporting_permissions.arn
}

resource "aws_iam_instance_profile" "reporting" {
  name = "northwind-reporting-instance-profile-assignment-02"
  role = aws_iam_role.reporting.name
}

# -------------------- EC2 --------------------

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.key_pair_name
  associate_public_ip_address = true

  user_data = <<-USERDATA
    #!/bin/bash
    set -euxo pipefail
    dnf install -y openssh-clients
  USERDATA

  tags = {
    Name = "northwind-bastion"
    Role = "bastion"
  }

  depends_on = [aws_route_table_association.public]
}

resource "aws_instance" "reporting" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.reporting.id]
  key_name               = var.key_pair_name
  iam_instance_profile   = aws_iam_instance_profile.reporting.name

  user_data = local.reporting_user_data

  root_block_device {
    encrypted = true
  }

  tags = {
    Name = "northwind-reporting-server"
    Role = "reporting"
  }

  depends_on = [
    aws_route_table_association.private,
    aws_iam_role_policy_attachment.reporting_permissions,
    aws_network_acl_association.private
  ]
}

output "vpc_id" {
  description = "Northwind VPC ID."
  value       = aws_vpc.northwind.id
}

output "public_subnet_id" {
  description = "Public subnet ID containing the bastion and NAT Gateway."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "Private subnet ID containing the reporting server."
  value       = aws_subnet.private.id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID. NAT Gateways incur AWS charges while running."
  value       = aws_nat_gateway.northwind.id
}

output "bastion_public_ip" {
  description = "Public IPv4 address for SSH to the bastion."
  value       = aws_instance.bastion.public_ip
}

output "reporting_private_ip" {
  description = "Private IPv4 address for the reporting server through the bastion."
  value       = aws_instance.reporting.private_ip
}

output "s3_bucket_name" {
  description = "Private versioned report bucket."
  value       = aws_s3_bucket.reports.bucket
}

output "sns_topic_arn" {
  description = "SNS topic ARN. Confirm the email subscription manually."
  value       = aws_sns_topic.report_ready.arn
}

output "reporting_role_arn" {
  description = "IAM role attached to the reporting instance profile."
  value       = aws_iam_role.reporting.arn
}

output "proxy_jump_ssh_command" {
  description = "SSH command from your computer through the bastion. Replace the key path."
  value       = "ssh -i PATH_TO_KEY.pem -J ec2-user@${aws_instance.bastion.public_ip} ec2-user@${aws_instance.reporting.private_ip}"
}
