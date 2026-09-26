<script lang="ts">
	import { onMount } from 'svelte';
	import { createComparisonApi } from '$lib/api';
	import type { FolderPairInput, JobProgress, PairState } from '$lib/types';

	const api = createComparisonApi();
	let pairs = $state<FolderPairInput[]>([
		{ sourceFolder: 'folder_a', destinationFolder: 'folder_b' },
		{ sourceFolder: 'folder_c', destinationFolder: 'folder_d' },
		{ sourceFolder: 'folder_e', destinationFolder: 'folder_f' },
		{ sourceFolder: 'folder_g', destinationFolder: 'folder_h' }
	]);
	let callbackId = $state('client-demo');
	let job = $state<JobProgress | null>(null);
	let submitting = $state(false);
	let polling = $state(false);
	let error = $state('');

	let progressPercent = $derived(
		job && job.totalPairs > 0 ? Math.round((job.completedPairs / job.totalPairs) * 100) : 0
	);
	let activePairs = $derived(job?.pairs.filter((pair) => pair.status === 'started').length ?? 0);
	let queuedPairs = $derived(job?.pairs.filter((pair) => pair.status === 'queued').length ?? 0);
	let resultCount = $derived(job?.pairs.filter((pair) => pair.resultLocation).length ?? 0);

	onMount(() => {
		if (api.mode === 'demo') void submitJob();
	});

	$effect(() => {
		if (!job || job.status === 'completed' || job.status === 'failed') return;
		const timer = window.setInterval(() => void refreshJob(), 1000);
		return () => window.clearInterval(timer);
	});

	async function submitJob() {
		if (submitting) return;
		error = '';
		const cleaned = pairs.map((pair) => ({
			sourceFolder: pair.sourceFolder.trim(),
			destinationFolder: pair.destinationFolder.trim()
		}));
		if (cleaned.some((pair) => !pair.sourceFolder || !pair.destinationFolder)) {
			error = 'Every folder pair needs both a source and destination.';
			return;
		}
		const unique = new Set(
			cleaned.map((pair) => `${pair.sourceFolder}\0${pair.destinationFolder}`)
		);
		if (unique.size !== cleaned.length) {
			error = 'Each source and destination pair must be unique.';
			return;
		}
		if (!callbackId.trim()) {
			error = 'Choose a registered callback ID.';
			return;
		}

		submitting = true;
		try {
			job = await api.submitJob({
				jobId: crypto.randomUUID(),
				callbackId: callbackId.trim(),
				pairs: cleaned
			});
		} catch (cause) {
			error = cause instanceof Error ? cause.message : 'The job could not be submitted.';
		} finally {
			submitting = false;
		}
	}

	async function refreshJob() {
		if (!job || polling) return;
		polling = true;
		try {
			job = await api.getJob(job.jobId);
			error = '';
		} catch (cause) {
			error = cause instanceof Error ? cause.message : 'Job status could not be refreshed.';
		} finally {
			polling = false;
		}
	}

	function addPair() {
		if (pairs.length >= 100) return;
		pairs.push({ sourceFolder: '', destinationFolder: '' });
	}

	function removePair(index: number) {
		if (pairs.length === 1) return;
		pairs.splice(index, 1);
	}

	function statusClasses(status: PairState) {
		return {
			queued: 'border-slate-600 bg-slate-800 text-slate-300',
			started: 'border-amber-400/40 bg-amber-400/10 text-amber-200',
			completed: 'border-teal-400/40 bg-teal-400/10 text-teal-200',
			failed: 'border-rose-400/40 bg-rose-400/10 text-rose-200'
		}[status];
	}

	function shortId(id: string) {
		return `${id.slice(0, 8)}…${id.slice(-4)}`;
	}

	function formatTime(value?: string) {
		if (!value) return '—';
		return new Intl.DateTimeFormat(undefined, {
			hour: '2-digit',
			minute: '2-digit',
			second: '2-digit'
		}).format(new Date(value));
	}
</script>

<svelte:head>
	<title>Comparison Engine · Operations</title>
	<meta
		name="description"
		content="Submit and monitor horizontally processed folder comparison jobs."
	/>
</svelte:head>

<div class="min-h-screen">
	<header class="border-b border-slate-800/90 bg-slate-950/60 backdrop-blur">
		<div class="mx-auto flex max-w-[1500px] items-center justify-between px-5 py-4 lg:px-8">
			<div class="flex items-center gap-3">
				<div
					class="grid h-10 w-10 place-items-center rounded-xl border border-teal-400/30 bg-teal-400/10 text-teal-300"
				>
					<svg
						viewBox="0 0 24 24"
						class="h-5 w-5"
						fill="none"
						stroke="currentColor"
						stroke-width="1.8"
						aria-hidden="true"
					>
						<path d="M4 7h16M4 12h10M4 17h16" />
						<circle cx="17" cy="12" r="3" />
					</svg>
				</div>
				<div>
					<p class="text-sm font-semibold tracking-wide text-white">Comparison Engine</p>
					<p class="text-xs text-slate-500">Distributed file analysis</p>
				</div>
			</div>
			<div class="flex items-center gap-3">
				<span class="hidden text-xs text-slate-500 sm:inline">eu-west-1</span>
				<span
					class="inline-flex items-center gap-2 rounded-full border border-slate-700 bg-slate-900 px-3 py-1.5 text-xs font-medium text-slate-200"
				>
					<span
						class={`h-2 w-2 rounded-full ${api.mode === 'demo' ? 'bg-amber-400' : 'bg-teal-400'}`}
					></span>
					{api.mode === 'demo' ? 'Local demo' : 'AWS connected'}
				</span>
			</div>
		</div>
	</header>

	<main class="mx-auto max-w-[1500px] px-5 py-7 lg:px-8">
		<section class="mb-7 flex flex-col justify-between gap-4 lg:flex-row lg:items-end">
			<div>
				<p class="mb-2 text-xs font-semibold tracking-[0.2em] text-teal-300 uppercase">
					Operations dashboard
				</p>
				<h1 class="text-3xl font-semibold tracking-tight text-white sm:text-4xl">
					Follow every folder pair.
				</h1>
				<p class="mt-2 max-w-2xl text-sm leading-6 text-slate-400">
					Submit one independently retryable task per pair, then watch workers claim, compare, and
					persist results.
				</p>
			</div>
			{#if api.mode === 'demo'}
				<p
					class="max-w-md rounded-lg border border-amber-400/20 bg-amber-400/5 px-4 py-3 text-xs leading-5 text-amber-100/80"
				>
					Demo mode uses the production API contract and simulated timing. Switch to the HTTP
					adapter when AWS authentication and the status endpoint are available.
				</p>
			{/if}
		</section>

		<section class="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
			<div class="rounded-xl border border-slate-800 bg-slate-900/70 p-5">
				<p class="text-xs font-medium tracking-wider text-slate-500 uppercase">Job progress</p>
				<div class="mt-3 flex items-baseline justify-between">
					<p class="text-3xl font-semibold text-white">{progressPercent}%</p>
					<p class="text-xs text-slate-500">
						{job?.completedPairs ?? 0}/{job?.totalPairs ?? 0} pairs
					</p>
				</div>
			</div>
			<div class="rounded-xl border border-slate-800 bg-slate-900/70 p-5">
				<p class="text-xs font-medium tracking-wider text-slate-500 uppercase">Active work</p>
				<div class="mt-3 flex items-baseline justify-between">
					<p class="text-3xl font-semibold text-amber-200">{activePairs}</p>
					<p class="text-xs text-slate-500">{queuedPairs} queued</p>
				</div>
			</div>
			<div class="rounded-xl border border-slate-800 bg-slate-900/70 p-5">
				<p class="text-xs font-medium tracking-wider text-slate-500 uppercase">Result objects</p>
				<div class="mt-3 flex items-baseline justify-between">
					<p class="text-3xl font-semibold text-teal-200">{resultCount}</p>
					<p class="text-xs text-slate-500">encrypted JSON</p>
				</div>
			</div>
			<div class="rounded-xl border border-slate-800 bg-slate-900/70 p-5">
				<p class="text-xs font-medium tracking-wider text-slate-500 uppercase">Measured scaling</p>
				<div class="mt-3 flex items-baseline justify-between">
					<p class="text-3xl font-semibold text-sky-200">3.73×</p>
					<p class="text-xs text-slate-500">4 local workers</p>
				</div>
			</div>
		</section>

		<div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_420px]">
			<section class="min-w-0 rounded-2xl border border-slate-800 bg-slate-900/60">
				<div class="border-b border-slate-800 px-5 py-5 sm:px-6">
					<div class="flex flex-wrap items-start justify-between gap-3">
						<div>
							<div class="flex items-center gap-2">
								<h2 class="font-semibold text-white">Current comparison</h2>
								{#if polling}<span class="h-1.5 w-1.5 animate-pulse rounded-full bg-teal-300"
									></span>{/if}
							</div>
							<p class="mt-1 font-mono text-xs text-slate-500">
								{job ? shortId(job.jobId) : 'No job submitted'}
							</p>
						</div>
						{#if job}<span
								class={`rounded-full border px-3 py-1 text-xs font-medium ${job.status === 'completed' ? 'border-teal-400/30 bg-teal-400/10 text-teal-200' : 'border-amber-400/30 bg-amber-400/10 text-amber-200'}`}
								>{job.status}</span
							>{/if}
					</div>
					<div class="mt-5 h-2 overflow-hidden rounded-full bg-slate-800">
						<div
							class="h-full rounded-full bg-teal-400 transition-[width] duration-500"
							style={`width: ${progressPercent}%`}
						></div>
					</div>
					<div class="mt-3 flex flex-wrap gap-x-6 gap-y-1 text-xs text-slate-500">
						<span>Started {formatTime(job?.startedAt)}</span><span
							>Completed {formatTime(job?.completedAt)}</span
						><span>Failures {job?.failedPairs ?? 0}</span>
					</div>
				</div>

				<div class="overflow-x-auto">
					<table class="w-full min-w-[720px] text-left text-sm">
						<thead
							class="border-b border-slate-800 bg-slate-950/30 text-xs tracking-wider text-slate-500 uppercase"
						>
							<tr
								><th class="px-6 py-3 font-medium">Source</th><th class="px-6 py-3 font-medium"
									>Destination</th
								><th class="px-6 py-3 font-medium">Status</th><th class="px-6 py-3 font-medium"
									>Completed</th
								><th class="px-6 py-3 font-medium">Result</th></tr
							>
						</thead>
						<tbody class="divide-y divide-slate-800/80">
							{#each job?.pairs ?? [] as pair (`${pair.sourceFolder}:${pair.destinationFolder}`)}
								<tr class="transition hover:bg-slate-800/30">
									<td class="px-6 py-4 font-mono text-xs text-slate-200">{pair.sourceFolder}</td>
									<td class="px-6 py-4 font-mono text-xs text-slate-200"
										>{pair.destinationFolder}</td
									>
									<td class="px-6 py-4"
										><span
											class={`rounded-full border px-2.5 py-1 text-xs font-medium ${statusClasses(pair.status)}`}
											>{pair.status}</span
										></td
									>
									<td class="px-6 py-4 text-xs text-slate-500">{formatTime(pair.completedAt)}</td>
									<td
										class="max-w-[220px] truncate px-6 py-4 font-mono text-xs text-slate-500"
										title={pair.resultLocation}>{pair.resultLocation ? 'S3 JSON' : '—'}</td
									>
								</tr>
							{:else}<tr
									><td colspan="5" class="px-6 py-16 text-center text-sm text-slate-500"
										>Submit a job to see pair-level progress.</td
									></tr
								>{/each}
						</tbody>
					</table>
				</div>
			</section>

			<aside class="rounded-2xl border border-slate-800 bg-slate-900/60 p-5 sm:p-6">
				<div class="flex items-start justify-between gap-3">
					<div>
						<h2 class="font-semibold text-white">Submit comparison</h2>
						<p class="mt-1 text-xs leading-5 text-slate-500">
							Each row becomes one independently retryable SQS message.
						</p>
					</div>
					<span class="rounded-md bg-slate-800 px-2 py-1 text-xs text-slate-400"
						>{pairs.length}/100</span
					>
				</div>

				<form
					class="mt-5 space-y-4"
					onsubmit={(event) => {
						event.preventDefault();
						void submitJob();
					}}
				>
					<label class="block"
						><span class="mb-1.5 block text-xs font-medium text-slate-400">Callback ID</span><input
							bind:value={callbackId}
							class="w-full rounded-lg border border-slate-700 bg-slate-950/70 px-3 py-2.5 text-sm text-white placeholder:text-slate-600"
							placeholder="client-demo"
						/></label
					>
					<div class="space-y-3">
						{#each pairs as pair, index (pair)}
							<div class="rounded-xl border border-slate-800 bg-slate-950/35 p-3">
								<div class="mb-2 flex items-center justify-between">
									<span class="text-[11px] font-semibold tracking-wider text-slate-600 uppercase"
										>Pair {index + 1}</span
									><button
										type="button"
										class="text-xs text-slate-600 transition hover:text-rose-300 disabled:opacity-30"
										disabled={pairs.length === 1}
										onclick={() => removePair(index)}>Remove</button
									>
								</div>
								<div class="grid grid-cols-[1fr_auto_1fr] items-center gap-2">
									<input
										aria-label={`Pair ${index + 1} source folder`}
										bind:value={pair.sourceFolder}
										class="min-w-0 rounded-md border border-slate-800 bg-slate-950 px-2.5 py-2 text-xs text-slate-200"
										placeholder="folder_a"
									/>
									<svg
										viewBox="0 0 24 24"
										class="h-4 w-4 text-slate-600"
										fill="none"
										stroke="currentColor"
										stroke-width="1.8"
										aria-hidden="true"><path d="M5 12h14m-5-5 5 5-5 5" /></svg
									>
									<input
										aria-label={`Pair ${index + 1} destination folder`}
										bind:value={pair.destinationFolder}
										class="min-w-0 rounded-md border border-slate-800 bg-slate-950 px-2.5 py-2 text-xs text-slate-200"
										placeholder="folder_b"
									/>
								</div>
							</div>
						{/each}
					</div>
					<button
						type="button"
						onclick={addPair}
						disabled={pairs.length >= 100}
						class="w-full rounded-lg border border-dashed border-slate-700 py-2 text-xs font-medium text-slate-400 transition hover:border-slate-500 hover:text-slate-200 disabled:opacity-40"
						>+ Add folder pair</button
					>
					{#if error}<p
							role="alert"
							class="rounded-lg border border-rose-400/20 bg-rose-400/5 px-3 py-2 text-xs leading-5 text-rose-200"
						>
							{error}
						</p>{/if}
					<button
						type="submit"
						disabled={submitting}
						class="flex w-full items-center justify-center gap-2 rounded-lg bg-teal-400 px-4 py-3 text-sm font-semibold text-slate-950 transition hover:bg-teal-300 disabled:cursor-wait disabled:opacity-60"
						>{submitting
							? 'Submitting…'
							: job
								? 'Run another comparison'
								: 'Start comparison'}</button
					>
				</form>
			</aside>
		</div>

		<section class="mt-6 rounded-2xl border border-slate-800 bg-slate-900/40 p-5 sm:p-6">
			<div class="mb-5 flex flex-wrap items-end justify-between gap-3">
				<div>
					<h2 class="font-semibold text-white">Durable job path</h2>
					<p class="mt-1 text-xs text-slate-500">
						The browser polls status; comparison and callback delivery remain asynchronous.
					</p>
				</div>
				<span class="text-xs text-slate-600"
					>Polling interval · 1 second demo / 2–3 seconds production</span
				>
			</div>
			<div class="grid gap-2 text-center text-xs sm:grid-cols-3 xl:grid-cols-7">
				{#each ['WAF + API Gateway', 'SQS work queue', 'Worker ASG', 'EFS input', 'RDS state', 'S3 results', 'Callback queue'] as step, index (step)}
					<div class="rounded-lg border border-slate-800 bg-slate-950/40 px-3 py-3 text-slate-300">
						<span class="mb-1 block text-[10px] font-semibold text-teal-400/70">0{index + 1}</span
						>{step}
					</div>
				{/each}
			</div>
		</section>
	</main>
</div>
