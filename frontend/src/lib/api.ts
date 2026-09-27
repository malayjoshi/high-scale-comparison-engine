import { env } from '$env/dynamic/public';
import { getAccessToken, getCurrentUser } from './auth';
import type {
	ComparisonApi,
	FolderPairInput,
	JobProgress,
	PairProgress,
	PairState,
	SubmitJobInput
} from './types';

interface RawPairProgress {
	source_folder: string;
	destination_folder: string;
	status: PairState;
	timestamp_start?: string;
	comparison_completed_at?: string;
	result_location?: string;
	error?: string;
}

interface RawJobProgress {
	job_id: string;
	status: 'started' | 'completed' | 'failed';
	total_pairs: number;
	completed_pairs: number;
	failed_pairs: number;
	started_at: string;
	completed_at?: string;
	pairs: RawPairProgress[];
}

export class HttpComparisonApi implements ComparisonApi {
	readonly mode = 'live' as const;
	private readonly queuedJobs = new Map<string, JobProgress>();

	constructor(
		private readonly baseUrl: string,
		private readonly token: () => string | null,
		private readonly statusApiEnabled = true
	) {}

	async submitJob(input: SubmitJobInput): Promise<JobProgress> {
		const timestamp = new Date().toISOString();
		for (const pair of input.pairs) {
			await this.request('/jobs', {
				method: 'POST',
				body: JSON.stringify({
					job_id: input.jobId,
					source_folder: pair.sourceFolder,
					destination_folder: pair.destinationFolder,
					total_expected_pairs: input.pairs.length,
					timestamp,
					callback_id: input.callbackId,
					...(env.PUBLIC_COGNITO_USE_ID_TOKEN === 'true'
						? { user_id: getCurrentUser()?.subject }
						: {})
				})
			});
		}

		const queued: JobProgress = {
			jobId: input.jobId,
			status: 'started',
			totalPairs: input.pairs.length,
			completedPairs: 0,
			failedPairs: 0,
			startedAt: timestamp,
			pairs: input.pairs.map((pair) => ({ ...pair, status: 'queued' }))
		};
		this.queuedJobs.set(input.jobId, queued);
		return queued;
	}

	async getJob(jobId: string): Promise<JobProgress> {
		if (!this.statusApiEnabled) {
			const queued = this.queuedJobs.get(jobId);
			if (!queued) throw new Error(`Job ${jobId} was not found in this browser session.`);
			return queued;
		}
		const response = await this.request(`/jobs/${encodeURIComponent(jobId)}`);
		return fromApi(await response.json());
	}

	private async request(path: string, init: RequestInit = {}): Promise<Response> {
		const accessToken = this.token();
		if (!accessToken) {
			throw new Error('No Cognito access token is available for live mode.');
		}

		const response = await fetch(`${this.baseUrl.replace(/\/$/, '')}${path}`, {
			...init,
			headers: {
				Authorization: `Bearer ${accessToken}`,
				'Content-Type': 'application/json',
				...init.headers
			}
		});
		if (!response.ok) {
			const detail = (await response.text()).trim();
			throw new Error(`API returned ${response.status}${detail ? `: ${detail}` : ''}`);
		}
		return response;
	}
}

export class DemoComparisonApi implements ComparisonApi {
	readonly mode = 'demo' as const;
	private readonly jobs = new Map<string, { input: SubmitJobInput; startedAt: number }>();

	constructor(private readonly now: () => number = Date.now) {}

	async submitJob(input: SubmitJobInput): Promise<JobProgress> {
		if (input.pairs.length === 0) throw new Error('Add at least one folder pair.');
		this.jobs.set(input.jobId, { input: structuredClone(input), startedAt: this.now() });
		return this.getJob(input.jobId);
	}

	async getJob(jobId: string): Promise<JobProgress> {
		const record = this.jobs.get(jobId);
		if (!record) throw new Error(`Job ${jobId} was not found.`);

		const elapsed = Math.max(0, this.now() - record.startedAt);
		const completedPairs = Math.min(record.input.pairs.length, Math.floor(elapsed / 1400));
		const completed = completedPairs === record.input.pairs.length;
		const startedAt = new Date(record.startedAt).toISOString();
		const pairs = record.input.pairs.map((pair, index) =>
			this.demoPair(pair, index, completedPairs, elapsed, record.startedAt, jobId)
		);

		return {
			jobId,
			status: completed ? 'completed' : 'started',
			totalPairs: pairs.length,
			completedPairs,
			failedPairs: 0,
			startedAt,
			completedAt: completed
				? new Date(record.startedAt + pairs.length * 1400).toISOString()
				: undefined,
			pairs
		};
	}

	private demoPair(
		pair: FolderPairInput,
		index: number,
		completedPairs: number,
		elapsed: number,
		startedAt: number,
		jobId: string
	): PairProgress {
		if (index < completedPairs) {
			return {
				...pair,
				status: 'completed',
				startedAt: new Date(startedAt + index * 1400).toISOString(),
				completedAt: new Date(startedAt + (index + 1) * 1400).toISOString(),
				resultLocation: `s3://comparison-engine-results/comparison-results/job_id=${jobId}/${pair.sourceFolder}__${pair.destinationFolder}.json`
			};
		}
		if (index === completedPairs && elapsed >= index * 1400) {
			return {
				...pair,
				status: 'started',
				startedAt: new Date(startedAt + index * 1400).toISOString()
			};
		}
		return { ...pair, status: 'queued' };
	}
}

export function createComparisonApi(): ComparisonApi {
	const baseUrl = env.PUBLIC_API_BASE_URL?.trim();
	const demoMode = env.PUBLIC_DEMO_MODE !== 'false' || !baseUrl;
	if (demoMode) return new DemoComparisonApi();

	return new HttpComparisonApi(baseUrl, getAccessToken, env.PUBLIC_STATUS_API_ENABLED !== 'false');
}

function fromApi(raw: RawJobProgress): JobProgress {
	return {
		jobId: raw.job_id,
		status: raw.status,
		totalPairs: raw.total_pairs,
		completedPairs: raw.completed_pairs,
		failedPairs: raw.failed_pairs,
		startedAt: raw.started_at,
		completedAt: raw.completed_at,
		pairs: raw.pairs.map((pair) => ({
			sourceFolder: pair.source_folder,
			destinationFolder: pair.destination_folder,
			status: pair.status,
			startedAt: pair.timestamp_start,
			completedAt: pair.comparison_completed_at,
			resultLocation: pair.result_location,
			error: pair.error
		}))
	};
}
