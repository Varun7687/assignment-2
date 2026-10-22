aws_region          = "us-east-1"
availability_zone   = "us-east-1a"
vpc_cidr            = "10.0.0.0/16"
public_subnet_cidr  = "10.0.1.0/24"
private_subnet_cidr = "10.0.2.0/24"

# Replace with your current public IPv4 address. Do not use 0.0.0.0/0.
admin_cidr = "49.43.251.128/32"

# This key pair must already exist in EC2. Terraform will not create or download the private key.
key_pair_name = "northwind-project2-key"
instance_type = "t3.micro"

# S3 names are globally unique. Change this if the name is already taken.
bucket_name        = "northwind-reporting-reports-assignment-02"
sns_topic_name     = "nightly-report-ready-assignment-02"
notification_email = "varunkumarnethaji2201@gmail.com"

# Use every 15 minutes only for a short validation window; switch to an approved nightly time afterward.
cron_schedule = "0 0 * * *"
