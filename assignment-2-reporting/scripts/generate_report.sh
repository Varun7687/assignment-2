#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin"

BUCKET="northwind-reporting-reports-assignment-02"
TOPIC_ARN="arn:aws:sns:us-east-1:243772032585:nightly-report-ready-assignment-02"
REPORT_DIR="/var/lib/northwind"
REPORT_DATE="$(date -u +%Y-%m-%d)"
REPORT_FILE="${REPORT_DIR}/${REPORT_DATE}.txt"
OBJECT_KEY="reports/${REPORT_DATE}.txt"

mkdir -p "$REPORT_DIR"
chmod 700 "$REPORT_DIR"
umask 077

cat > "$REPORT_FILE" <<REPORT
Northwind Nightly Sales Report
=============================
Date (UTC): ${REPORT_DATE}
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
  --region us-east-1

PRESIGNED_URL="$(aws s3 presign "s3://${BUCKET}/${OBJECT_KEY}" \
  --expires-in 3600 \
  --region us-east-1)"

MESSAGE="Northwind report ready.

Report key: ${OBJECT_KEY}
S3 location: s3://${BUCKET}/${OBJECT_KEY}

Download link (valid for up to 1 hour):
${PRESIGNED_URL}"

aws sns publish \
  --topic-arn "$TOPIC_ARN" \
  --subject "Northwind report ready" \
  --message "$MESSAGE" \
  --region us-east-1

echo "Uploaded: s3://${BUCKET}/${OBJECT_KEY}"
echo "SNS notification sent with the report key and download link."
