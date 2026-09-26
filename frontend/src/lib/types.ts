export type PairState = 'queued' | 'started' | 'completed' | 'failed';
export type JobState = 'started' | 'completed' | 'failed';

export interface FolderPairInput {
	sourceFolder: string;
	destinationFolder: string;
}

export interface SubmitJobInput {
	jobId: string;
	callbackId: string;
	pairs: FolderPairInput[];
}

export interface PairProgress extends FolderPairInput {
	status: PairState;
	startedAt?: string;
	completedAt?: string;
	resultLocation?: string;
	error?: string;
}

export interface JobProgress {
	jobId: string;
	status: JobState;
	totalPairs: number;
	completedPairs: number;
	failedPairs: number;
	startedAt: string;
	completedAt?: string;
	pairs: PairProgress[];
}

export interface ComparisonApi {
	readonly mode: 'demo' | 'live';
	submitJob(input: SubmitJobInput): Promise<JobProgress>;
	getJob(jobId: string): Promise<JobProgress>;
}
