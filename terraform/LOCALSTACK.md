# LocalStack deployment

This environment exercises the AWS control plane and the application path for
the distributed dataset reconciliation platform. The included generated folder
pairs stand in for partitions from two dataset versions, such as legacy and
migrated system exports.

The complete Terraform control plane can be created in one LocalStack Pro
apply. LocalStack must be running with its Pro license activated. The
repository's `.lstk/config.toml` allows the local frontend through LocalStack's
gateway CORS filter and selects the bundled PostgreSQL runtime.

LocalStack's Cognito emulator currently omits custom resource-server scopes
from OAuth access tokens. The local example disables method-level scope
enforcement while still requiring a valid Cognito JWT. Real AWS deployments
retain the secure default, `enforce_cognito_scope = true`.

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

RDS uses PostgreSQL 17. Start LocalStack from the repository root so `lstk`
loads the project configuration:

```bash
lstk start --persist --non-interactive
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

## What runs where

LocalStack runs the AWS-facing side of the application: API Gateway, SQS,
Lambda, S3, Secrets Manager, and PostgreSQL. The comparison workers are normal
Python processes. In AWS, an Auto Scaling group starts them on EC2; locally,
the benchmark starts the same worker entry point as child processes:

```bash
AWS_PROFILE=localstack \
AWS_DEFAULT_REGION=eu-west-1 \
AWS_ENDPOINT_URL=http://localhost:4566 \
AWS_EC2_METADATA_DISABLED=true \
scripts/.venv/bin/python scripts/benchmark_workers.py --workers 1,2,4
```

The benchmark owns temporary queues and stops its workers when each trial
finishes. It proves the comparison, PostgreSQL, S3, and outbox path; it is not
a background worker supervisor for the dashboard.

## Emulation boundaries

- API Gateway, native Cognito user-pool configuration, WAF, SQS, Lambda, DynamoDB, S3,
  EFS, RDS, CloudWatch alarms, and Auto Scaling resources can be provisioned.
- Auto Scaling is a control-plane emulation; it does not boot real EC2 worker
  virtual machines.
- EFS resources and mount targets are modeled, but no real ASG instance mounts
  the file system locally.
- LocalStack models the Cognito control plane, but its managed login should not
  be treated as proof of the real AWS OAuth browser flow.
- LocalStack creates its own default VPC. Terraform creates exactly one
  application VPC named `comparison-engine-vpc`.
