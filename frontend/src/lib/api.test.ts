import { describe, expect, it } from 'vitest';
import { DemoComparisonApi, fromApi } from './api';

it('maps live API pair progress', () => {
	const completedAt = '2026-09-27T15:55:42.568608Z';
	const job = fromApi({
		job_id: '652f53ea-bccb-46e0-bf9f-6a5071b72f69',
		status: 'completed',
		total_pairs: 1,
		completed_pairs: 1,
		failed_pairs: 0,
		started_at: '2026-09-27T15:55:32.568608Z',
		completed_at: completedAt,
		pairs: [
			{
				sourceFolder: 'folder_a',
				destinationFolder: 'folder_b',
				status: 'completed',
				completedAt,
				resultLocation: 's3://results/folder_a__folder_b.json',
				resultUrl: 'https://results.example/folder_a__folder_b.json'
			}
		]
	});

	expect(job.pairs[0]).toMatchObject({
		sourceFolder: 'folder_a',
		destinationFolder: 'folder_b',
		status: 'completed',
		completedAt,
		resultUrl: 'https://results.example/folder_a__folder_b.json'
	});
});

describe('DemoComparisonApi', () => {
	it('advances folder pairs independently and completes the parent job', async () => {
		let now = Date.parse('2026-09-25T12:00:00Z');
		const api = new DemoComparisonApi(() => now);
		const input = {
			jobId: '2f99df62-186c-41ab-b35c-d253f277c250',
			callbackId: 'client-demo',
			pairs: [
				{ sourceFolder: 'folder_a', destinationFolder: 'folder_b' },
				{ sourceFolder: 'folder_c', destinationFolder: 'folder_d' }
			]
		};

		const started = await api.submitJob(input);
		expect(started.completedPairs).toBe(0);
		expect(started.pairs[0].status).toBe('started');

		now += 1400;
		const halfway = await api.getJob(input.jobId);
		expect(halfway.completedPairs).toBe(1);
		expect(halfway.pairs.map((pair) => pair.status)).toEqual(['completed', 'started']);

		now += 1400;
		const completed = await api.getJob(input.jobId);
		expect(completed.status).toBe('completed');
		expect(completed.completedPairs).toBe(2);
		expect(completed.pairs[1].resultLocation).toContain(input.jobId);
	});
});
