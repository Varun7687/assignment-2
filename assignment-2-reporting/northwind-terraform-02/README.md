# Northwind Reporting Server — Terraform

This Terraform project creates the complete single-AZ learning setup. All Terraform resources, the HTML report, the EC2 bootstrap script, the report-generation script, and the cron configuration are embedded in `main.tf`, so no separate template or shell-script files are required.

- Custom VPC `10.0.0.0/16`
- Public subnet for a bastion and NAT Gateway
- Private subnet for the reporting server with no public IP
- Internet Gateway, public/private route tables, NAT Gateway, and Elastic IP
- Bastion and reporting security groups
- Custom private-subnet network ACL with SSH, DNS, HTTPS, and return-traffic rules
- Private encrypted and versioned S3 bucket
- SNS topic and email subscription
- EC2 IAM role limited to `reports/*` S3 objects and SNS publish
- Amazon Linux reporting server with a styled HTML report, unique S3 keys, presigned download links, and cron schedule

## Important before applying

1. Confirm the AWS account and region.
2. Check whether resources from the deleted project still exist. Do not create duplicate NAT Gateways or duplicate billable resources.
3. Confirm the CIDRs do not overlap another connected network.
4. Confirm your EC2 key pair already exists. Terraform does not create or store your private key.
5. Replace the example admin CIDR, bucket name, and email.
6. NAT Gateway, EC2, Elastic IP, and data-processing charges may apply.

## Apply

Run these commands from this directory on a machine with Terraform and AWS credentials configured. The credentials are used by Terraform only; the reporting instance uses its IAM role.

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your real values.
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out northwind.tfplan
terraform apply northwind.tfplan
```

Terraform creates an SNS email subscription, but the recipient must click the AWS confirmation link. Wait for confirmation before testing notifications.

## Connect and test

After apply:

```bash
terraform output
```

Use the `proxy_jump_ssh_command` output from your computer after replacing `PATH_TO_KEY.pem`. On the reporting server:

```bash
sudo systemctl status crond
cat /home/ec2-user/northwind-reporting/generate_report.sh
sudo cat /etc/cron.d/northwind-reporting
sudo tail -n 50 /home/ec2-user/northwind-reporting/generate_report.log
aws sts get-caller-identity --region us-east-1
```

Run one manual HTML report test as `ec2-user`:

```bash
/home/ec2-user/northwind-reporting/generate_report.sh
```

Confirm the matching `.html` object under `reports/` in S3 and the SNS email. The email includes a presigned download link that is valid for approximately one hour. For three distinct test objects, run the script three times or temporarily set `cron_schedule = "*/15 * * * *"`, apply, wait for approved test runs, and then change it back to the approved nightly schedule.

The IAM policy intentionally does not grant `s3:ListBucket`; an `aws s3 ls` AccessDenied response is expected. Verify known objects in the S3 console or with `aws s3api head-object` using the exact key. The complete HTML report and all reporting-server setup are embedded directly in `main.tf`.

## GitHub safety

Do not commit `terraform.tfvars`, `.terraform/`, Terraform state, private keys, account credentials, unredacted IPs, or live presigned URLs. Commit `main.tf`, `terraform.tfvars.example`, and a redacted project README instead.

## Cleanup

Only after saving required evidence and receiving approval:

```bash
terraform destroy
```

Because the S3 bucket uses `force_destroy = false`, remove or retain report objects according to the assignment before destroying. Confirm the NAT Gateway and Elastic IP are gone; they can continue to incur charges.
