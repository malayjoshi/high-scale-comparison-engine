# Comparison Engine frontend

SvelteKit and Tailwind operations dashboard for submitting folder-pair jobs
and polling their progress.

## Local portfolio demo

Demo mode is the default while AWS and Microsoft Entra authentication are not
available. It exercises the same TypeScript API contract as live mode and
advances each folder pair independently.

```bash
npm install
npm run dev
```

Open <http://localhost:5173>. A four-pair sample starts automatically; edit
the folder names or add pairs to run it again.

## Live API mode

Copy `.env.example` to `.env` and set:

```dotenv
PUBLIC_DEMO_MODE=false
PUBLIC_API_BASE_URL=https://example.execute-api.eu-west-1.amazonaws.com/production
```

Live mode expects the Cognito OAuth flow to place an access token in browser
`sessionStorage` under `comparison-engine-access-token`. It calls:

- `POST /jobs` once for every folder pair;
- `GET /jobs/{job_id}` while the parent job is active.

The status endpoint is the remaining backend dependency and should return the
shape represented by `src/lib/types.ts`. OAuth completion and the status
Lambda should be connected when the AWS account is restored; demo mode does
not pretend those integrations have been validated locally.

## Checks

```bash
npm run check
npm test
npm run lint
npm run build
```
