# Architecture and design decisions

This document explains why the comparison engine is shaped the way it is.
The short version: keep ingestion cheap, make work independently retryable,
and put durable state transitions in the database.

## Request path

```text
Native Cognito user ──managed login + PKCE──> client
                                                │
                                                ▼
                                      WAF + API Gateway
                                                │
                                     validate and SendMessage
                                                ▼
                                           input SQS
```

API Gateway integrates directly with SQS. A Lambda function in front of the
queue would add another runtime, permission boundary, and failure mode without
adding useful logic: the gateway already validates the JSON schema, verifies
the Cognito token, injects the authenticated subject, and maps the request to
`SendMessage`.

Only a successful SQS response becomes HTTP `202`. Integration-side 4xx and
other failures map to `400` and `500`, so the client is never told a job was
accepted when it was not queued.

Reads take a separate path. `GET /jobs/{job_id}` invokes a small Lambda that
loads the RDS-managed credentials from Secrets Manager, reads parent and pair
state from PostgreSQL, and returns the current snapshot. Completed pairs also
receive a 15-minute presigned S3 URL. The bucket stays private; the browser
gets permission for one result object and a short window instead of permanent
S3 credentials.

## Why the client flattens jobs

The original shape put a list of folder pairs in one message. That made one
worker responsible for a whole job and reduced the value of the queue.

The final contract sends one message per pair:

```text
job_id + source_folder + destination_folder + total_expected_pairs
```

This gives SQS a useful unit of work. Individual pairs can be retried, workers
can process the same parent job in parallel, and a partial client submission
can be resumed with the same job ID. PostgreSQL rejects conflicting ownership,
callback IDs, totals, and duplicate pair definitions.

## Worker lifecycle

```text
receive message
    │
    ▼
claim pair in PostgreSQL ── completed? ──> delete duplicate message
    │
    ├── busy? ──> release message briefly
    │
    ▼
renew SQS visibility + DB heartbeat
    │
    ▼
compare folder and files
    │
    ├── exact bytes equal ──> record identical, skip CSV parsing
    │
    └── different ──> compare schema, primary keys, and shared cells
    │
    ▼
write JSON to S3
    │
    ▼
commit pair state in PostgreSQL
    │
    ▼
delete SQS message
```

The SQS visibility timeout is a lease, not a lock. The database claim is the
source of truth. Updating both heartbeats allows recovery when a process dies
while preventing a healthy long-running comparison from being duplicated.

## Job completion and the transactional outbox

The last completed pair changes the parent job to `completed`. Publishing the
callback event directly after that commit would create a dual-write problem:

- the process can commit PostgreSQL and die before publishing; or
- it can publish and die before recording that it published.

Instead, the parent update and a unique outbox row commit in one transaction.
A small dispatcher thread claims rows with `FOR UPDATE SKIP LOCKED`, publishes
them to the completion SQS queue, and records success. Failed attempts use a
bounded quadratic backoff and can be claimed again.

The completion Lambda uses SQS partial-batch responses. One failed callback
does not force successful messages in the same batch to be retried.

## Callback safety

Clients submit a `callback_id`, never an arbitrary URL. DynamoDB maps that ID
to an enabled destination managed by Terraform. The Lambda:

- refuses unregistered or disabled IDs;
- requires HTTPS outside explicit local-development hosts;
- rejects embedded URL credentials;
- refuses redirects, preventing an approved host from redirecting to another
  destination;
- includes a stable event ID so receivers can deduplicate retries.

## Storage roles

| Store | Responsibility |
|---|---|
| EFS | Shared input files mounted by every worker |
| PostgreSQL | Job lifecycle, pair claims, heartbeats, result locations, outbox |
| S3 | Immutable per-pair JSON results, partitioned by date and job ID |
| DynamoDB | Small, independently managed callback allow-list |
| Instance storage | Atomic temporary JSON copy for local recovery/debugging |

The status response preserves the durable `s3://` location and adds a
short-lived browser URL at read time. URLs are never stored in PostgreSQL
because they expire and can always be regenerated from the durable location.

S3 result keys use this shape:

```text
comparison-results/
  completion_date=YYYY-MM-DD/
    job_id=<uuid>/
      <source>__<destination>.json
```

The layout remains friendly to later Athena/Glue analysis without making an
analytics stack part of the core comparison service.

## Scaling policy

Workers scale on:

```text
(visible messages + in-flight messages) / in-service workers
```

Including in-flight work avoids interpreting a busy but empty visible queue as
idle. Scale-out requires two consecutive periods above two pairs per worker.
Scale-in requires five periods below half a pair per worker, deliberately
favoring stability over fast contraction.

The input queue, callback queue, and their DLQs are separate. Comparison
capacity and callback reliability can therefore evolve independently.

## Network and identity boundaries

- Workers have no inbound security-group rules.
- SQS and Secrets Manager use interface VPC endpoints.
- S3 uses a gateway endpoint.
- EFS permits NFS only from the worker security group.
- RDS permits PostgreSQL only from the worker security group.
- Worker IAM grants access to the specific queues, buckets, and database
  secret required by the service.
- The status Lambda can read the database secret and result objects, but it
  cannot enqueue work or modify comparison state.
- WAF protects the regional API Gateway stage with managed rules and an IP
  rate limit.

## Evidence and limits

The full Terraform plan—76 resources—applies successfully to LocalStack Pro,
and a second plan is clean. Python and Go test suites cover job parsing,
idempotent worker behavior, outbox publication, result layout, callback
validation, and data/client utilities.

The local benchmark reached 3.73× throughput with four worker processes.
That demonstrates application-level parallelism. It does **not** claim that
LocalStack launched EC2 instances: its Auto Scaling support is control-plane
emulation. Real AWS is still required for the final infrastructure validation
listed in the project README.
