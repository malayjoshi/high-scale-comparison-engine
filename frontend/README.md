# Comparison Engine frontend

SvelteKit and Tailwind operations dashboard for submitting folder-pair jobs
and polling their progress.

## Local portfolio demo

Demo mode is the default when AWS is unavailable. It exercises the same
TypeScript API contract as live mode and advances each folder pair
independently without requiring authentication.

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
PUBLIC_COGNITO_DOMAIN=https://comparison-engine.auth.eu-west-1.amazoncognito.com
PUBLIC_COGNITO_CLIENT_ID=exampleclientid
PUBLIC_COGNITO_REDIRECT_URI=http://localhost:5173/auth/callback
PUBLIC_COGNITO_LOGOUT_URI=http://localhost:5173/
PUBLIC_COGNITO_SCOPES=openid email comparison-engine/jobs.write comparison-engine/jobs.read
PUBLIC_STATUS_API_ENABLED=true
```

For the deployed LocalStack stack, use
`PUBLIC_COGNITO_DOMAIN=http://localhost:4566/_aws/cognito-idp`. The frontend
automatically selects LocalStack's login and token endpoint paths.

Live mode uses Cognito managed login with the OAuth authorization-code flow and
PKCE. The frontend generates the verifier and state, exchanges the returned
code, keeps the short-lived tokens in session storage, and sends the access
token as a bearer token to API Gateway. No client secret or password is stored
by the Svelte application.

The frontend calls:

- `POST /jobs` once for every folder pair;
- `GET /jobs/{job_id}` while the parent job is active.

The status Lambda reads PostgreSQL and returns the shape represented by
`src/lib/types.ts`. Completed rows include a 15-minute presigned S3 URL, which
the dashboard exposes as **View JSON**. Keep `PUBLIC_STATUS_API_ENABLED=true`
for the deployed LocalStack or AWS stack. Setting it to `false` is only useful
for UI work without a status backend; submitted rows then remain queued in the
browser session.

## Checks

```bash
npm run check
npm test
npm run lint
npm run build
```
