import { env } from '$env/dynamic/public';

const ACCESS_TOKEN_KEY = 'comparison-engine-access-token';
const ID_TOKEN_KEY = 'comparison-engine-id-token';
const PKCE_VERIFIER_KEY = 'comparison-engine-pkce-verifier';
const OAUTH_STATE_KEY = 'comparison-engine-oauth-state';

export interface AuthUser {
	email: string;
	subject: string;
}

interface CognitoConfig {
	authorizeUrl: string;
	tokenUrl: string;
	logoutUrl: string;
	clientId: string;
	redirectUri: string;
	logoutUri: string;
	scopes: string;
}

interface TokenResponse {
	access_token: string;
	id_token: string;
	expires_in: number;
	token_type: string;
}

interface JwtClaims {
	email?: string;
	sub?: string;
	exp?: number;
}

export function isCognitoConfigured(): boolean {
	return Boolean(env.PUBLIC_COGNITO_DOMAIN?.trim() && env.PUBLIC_COGNITO_CLIENT_ID?.trim());
}

export async function startSignIn(): Promise<void> {
	const config = getConfig();
	const verifier = randomUrlSafeString(64);
	const state = randomUrlSafeString(32);
	const challenge = await sha256Base64Url(verifier);

	sessionStorage.setItem(PKCE_VERIFIER_KEY, verifier);
	sessionStorage.setItem(OAUTH_STATE_KEY, state);

	const query = new URLSearchParams({
		client_id: config.clientId,
		response_type: 'code',
		redirect_uri: config.redirectUri,
		scope: config.scopes,
		state,
		code_challenge_method: 'S256',
		code_challenge: challenge
	});
	window.location.assign(`${config.authorizeUrl}?${query}`);
}

export async function completeSignIn(callbackUrl = window.location.href): Promise<AuthUser> {
	const config = getConfig();
	const callback = new URL(callbackUrl);
	const error = callback.searchParams.get('error');
	if (error) {
		throw new Error(callback.searchParams.get('error_description') || error);
	}

	const code = callback.searchParams.get('code');
	const state = callback.searchParams.get('state');
	const expectedState = sessionStorage.getItem(OAUTH_STATE_KEY);
	const verifier = sessionStorage.getItem(PKCE_VERIFIER_KEY);
	if (!code || !state || !expectedState || !verifier || state !== expectedState) {
		throw new Error('Cognito returned an invalid OAuth callback. Start sign-in again.');
	}

	const response = await fetch(config.tokenUrl, {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({
			grant_type: 'authorization_code',
			client_id: config.clientId,
			code,
			redirect_uri: config.redirectUri,
			code_verifier: verifier
		})
	});
	if (!response.ok) {
		throw new Error(`Cognito token exchange failed with status ${response.status}.`);
	}

	const tokens = (await response.json()) as TokenResponse;
	sessionStorage.setItem(ACCESS_TOKEN_KEY, tokens.access_token);
	sessionStorage.setItem(ID_TOKEN_KEY, tokens.id_token);
	sessionStorage.removeItem(PKCE_VERIFIER_KEY);
	sessionStorage.removeItem(OAUTH_STATE_KEY);

	const user = getCurrentUser();
	if (!user) throw new Error('Cognito did not return a usable identity token.');
	return user;
}

export function getAccessToken(): string | null {
	if (typeof sessionStorage === 'undefined') return null;
	// LocalStack's Cognito authorizer accepts an ID token when method-level
	// scopes are disabled. Real AWS uses the scoped access token.
	const token = sessionStorage.getItem(
		env.PUBLIC_COGNITO_USE_ID_TOKEN === 'true' ? ID_TOKEN_KEY : ACCESS_TOKEN_KEY
	);
	if (!token || isExpired(token)) return null;
	return token;
}

export function getCurrentUser(): AuthUser | null {
	if (typeof sessionStorage === 'undefined') return null;
	const token = sessionStorage.getItem(ID_TOKEN_KEY);
	if (!token || isExpired(token)) return null;
	const claims = decodeClaims(token);
	if (!claims.sub) return null;
	return { email: claims.email || 'Cognito user', subject: claims.sub };
}

export function signOut(): void {
	const config = getConfig();
	sessionStorage.removeItem(ACCESS_TOKEN_KEY);
	sessionStorage.removeItem(ID_TOKEN_KEY);
	const query = new URLSearchParams({ client_id: config.clientId, logout_uri: config.logoutUri });
	window.location.assign(`${config.logoutUrl}?${query}`);
}

function getConfig(): CognitoConfig {
	const domain = env.PUBLIC_COGNITO_DOMAIN?.trim().replace(/\/$/, '');
	const clientId = env.PUBLIC_COGNITO_CLIENT_ID?.trim();
	if (!domain || !clientId) {
		throw new Error('Cognito is not configured for this frontend.');
	}
	const origin = typeof window === 'undefined' ? '' : window.location.origin;
	const localStack = domain.endsWith('/_aws/cognito-idp');
	return {
		authorizeUrl: `${domain}/${localStack ? 'login' : 'oauth2/authorize'}`,
		tokenUrl: `${domain}/oauth2/token`,
		logoutUrl: localStack ? `${origin}/` : `${domain}/logout`,
		clientId,
		redirectUri: env.PUBLIC_COGNITO_REDIRECT_URI?.trim() || `${origin}/auth/callback`,
		logoutUri: env.PUBLIC_COGNITO_LOGOUT_URI?.trim() || `${origin}/`,
		scopes: env.PUBLIC_COGNITO_SCOPES?.trim() || 'openid email comparison-engine/jobs.write'
	};
}

function decodeClaims(token: string): JwtClaims {
	const payload = token.split('.')[1];
	if (!payload) return {};
	try {
		return JSON.parse(new TextDecoder().decode(base64UrlDecode(payload))) as JwtClaims;
	} catch {
		return {};
	}
}

function isExpired(token: string): boolean {
	const expiresAt = decodeClaims(token).exp;
	return !expiresAt || expiresAt * 1000 <= Date.now() + 10_000;
}

function randomUrlSafeString(byteLength: number): string {
	const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
	return base64UrlEncode(bytes);
}

async function sha256Base64Url(value: string): Promise<string> {
	const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
	return base64UrlEncode(new Uint8Array(digest));
}

function base64UrlEncode(bytes: Uint8Array): string {
	let binary = '';
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlDecode(value: string): Uint8Array {
	const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
	const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
	const binary = atob(padded);
	return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
