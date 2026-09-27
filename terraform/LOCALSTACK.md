# LocalStack deployment

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

## Emulation boundaries

- API Gateway, native Cognito user-pool configuration, WAF, SQS, Lambda, DynamoDB, S3,
  EFS, RDS, CloudWatch alarms, and Auto Scaling resources can be provisioned.
- Auto Scaling is a control-plane emulation; it does not boot real EC2 worker
  virtual machines. Run `scripts/benchmark_workers.py` to exercise concurrent
  workers as local processes.
- EFS resources and mount targets are modeled, but no real ASG instance mounts
  the file system locally.
- LocalStack models the Cognito control plane, but its managed login should not
  be treated as proof of the real AWS OAuth browser flow.
- LocalStack creates its own default VPC. Terraform creates exactly one
  application VPC named `comparison-engine-vpc`.
