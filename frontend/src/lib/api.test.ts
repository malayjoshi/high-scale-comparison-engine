import { describe, expect, it } from 'vitest';
import { DemoComparisonApi } from './api';

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
