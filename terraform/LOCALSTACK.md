# LocalStack deployment

The complete Terraform control plane can be created in one LocalStack Pro
apply. LocalStack must be running with its Pro license activated.

```bash
cp terraform/localstack.tfvars.example terraform/localstack.tfvars

AWS_PROFILE=localstack \
AWS_DEFAULT_REGION=eu-west-1 \
AWS_ENDPOINT_URL=http://localhost:4566 \
AWS_EC2_METADATA_DISABLED=true \
terraform -chdir=terraform init

AWS_PROFILE=localstack \
AWS_DEFAULT_REGION=eu-west-1 \
AWS_ENDPOINT_URL=http://localhost:4566 \
AWS_EC2_METADATA_DISABLED=true \
terraform -chdir=terraform apply -var-file=localstack.tfvars
```

RDS uses PostgreSQL 17. If LocalStack attempts to download another PostgreSQL
version, restart it with bundled database versions enabled before applying:

```bash
LOCALSTACK_RDS_PG_CUSTOM_VERSIONS=0 lstk restart --non-interactive
```

Verify idempotence with:

```bash
AWS_PROFILE=localstack \
AWS_DEFAULT_REGION=eu-west-1 \
AWS_ENDPOINT_URL=http://localhost:4566 \
AWS_EC2_METADATA_DISABLED=true \
terraform -chdir=terraform plan -detailed-exitcode -var-file=localstack.tfvars
```

Exit code `0` means there are no changes.

## Emulation boundaries

- API Gateway, Cognito/SAML configuration, WAF, SQS, Lambda, DynamoDB, S3,
  EFS, RDS, CloudWatch alarms, and Auto Scaling resources can be provisioned.
- Auto Scaling is a control-plane emulation; it does not boot real EC2 worker
  virtual machines. Run `scripts/benchmark_workers.py` to exercise concurrent
  workers as local processes.
- EFS resources and mount targets are modeled, but no real ASG instance mounts
  the file system locally.
- A real Microsoft Entra ID SAML login requires a reachable tenant and cannot
  be proven from an offline LocalStack deployment.
- LocalStack creates its own default VPC. Terraform creates exactly one
  application VPC named `comparison-engine-vpc`.
