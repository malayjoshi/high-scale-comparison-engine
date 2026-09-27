<script lang="ts">
	import { onMount } from 'svelte';
	import { createComparisonApi } from '$lib/api';
	import {
		getCurrentUser,
		isCognitoConfigured,
		signOut,
		startSignIn,
		type AuthUser
	} from '$lib/auth';
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
	let authUser = $state<AuthUser | null>(null);
	let authBusy = $state(false);

	let progressPercent = $derived(
		job && job.totalPairs > 0 ? Math.round((job.completedPairs / job.totalPairs) * 100) : 0
	);
	let activePairs = $derived(job?.pairs.filter((pair) => pair.status === 'started').length ?? 0);
	let queuedPairs = $derived(job?.pairs.filter((pair) => pair.status === 'queued').length ?? 0);
	let resultCount = $derived(job?.pairs.filter((pair) => pair.resultLocation).length ?? 0);

	onMount(() => {
		authUser = getCurrentUser();
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
		if (api.mode === 'live' && !authUser) {
			error = 'Sign in with Cognito before submitting a comparison.';
			return;
		}
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

	async function login() {
		authBusy = true;
		error = '';
		try {
			await startSignIn();
		} catch (cause) {
			error = cause instanceof Error ? cause.message : 'Sign-in could not be started.';
			authBusy = false;
		}
	}

	function logout() {
		try {
			signOut();
		} catch (cause) {
			error = cause instanceof Error ? cause.message : 'Sign-out could not be started.';
		}
	}

	function userInitials(user: AuthUser | null) {
		if (!user) return api.mode === 'demo' ? 'MJ' : '?';
		return user.email
			.split(/[^A-Za-z0-9]+/)
			.filter(Boolean)
			.slice(0, 2)
			.map((part) => part[0]?.toUpperCase())
			.join('');
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
			queued: 'bg-[#e9edf7] text-[#667085]',
			started: 'bg-[#ebe4fd] text-[#6226ef]',
			completed: 'bg-[#d9f4ef] text-[#00a389]',
			failed: 'bg-[#fde5e2] text-[#ef3826]'
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

<div class="min-h-screen bg-[#f5f6fa] text-[#202224] lg:pl-[240px]">
	<aside
		class="fixed inset-y-0 left-0 z-30 hidden w-[240px] border-r border-[#e8e8e8] bg-white lg:flex lg:flex-col"
	>
		<div class="flex h-[70px] items-center px-10">
			<p class="text-xl font-extrabold tracking-tight text-[#4880ff]">
				Compari<span class="text-[#202224]">Stack</span>
			</p>
		</div>
		<nav class="flex-1 px-6 pt-3" aria-label="Primary navigation">
			<a
				class="flex h-[50px] items-center gap-4 rounded-md bg-[#4880ff] px-4 text-sm font-semibold text-white"
				href="#dashboard"
			>
				<svg
					viewBox="0 0 24 24"
					class="h-5 w-5"
					fill="none"
					stroke="currentColor"
					stroke-width="1.8"
					aria-hidden="true"
					><rect x="3" y="3" width="7" height="7" rx="1" /><rect
						x="14"
						y="3"
						width="7"
						height="7"
						rx="1"
					/><rect x="3" y="14" width="7" height="7" rx="1" /><rect
						x="14"
						y="14"
						width="7"
						height="7"
						rx="1"
					/></svg
				>
				Dashboard
			</a>
			<a class="nav-item" href="#jobs">
				<svg
					viewBox="0 0 24 24"
					class="h-5 w-5"
					fill="none"
					stroke="currentColor"
					stroke-width="1.8"
					aria-hidden="true"
					><path d="M4 7h16M4 12h10M4 17h16" /><circle cx="17" cy="12" r="3" /></svg
				>
				Comparison jobs
			</a>
			<a class="nav-item" href="#pipeline">
				<svg
					viewBox="0 0 24 24"
					class="h-5 w-5"
					fill="none"
					stroke="currentColor"
					stroke-width="1.8"
					aria-hidden="true"><path d="M4 18V6m6 12V9m6 9V3m4 15H2" /></svg
				>
				Performance
			</a>
			<div class="my-6 border-t border-[#e8e8e8]"></div>
			<p class="px-4 text-xs font-bold tracking-[0.3px] text-[#202224]/50 uppercase">System</p>
			<a class="nav-item mt-3" href="#pipeline">
				<svg
					viewBox="0 0 24 24"
					class="h-5 w-5"
					fill="none"
					stroke="currentColor"
					stroke-width="1.8"
					aria-hidden="true"
					><path
						d="M12 2v5m0 10v5M4.93 4.93l3.54 3.54m7.06 7.06 3.54 3.54M2 12h5m10 0h5M4.93 19.07l3.54-3.54m7.06-7.06 3.54-3.54"
					/><circle cx="12" cy="12" r="4" /></svg
				>
				Architecture
			</a>
		</nav>
		<div class="border-t border-[#e8e8e8] px-6 py-5">
			<div class="flex items-center gap-3 rounded-lg bg-[#f5f6fa] px-3 py-3">
				<span
					class={`h-2.5 w-2.5 rounded-full ${api.mode === 'demo' ? 'bg-[#ffb648]' : 'bg-[#00b69b]'}`}
				></span>
				<div>
					<p class="text-xs font-bold">{api.mode === 'demo' ? 'Local demo' : 'AWS connected'}</p>
					<p class="mt-0.5 text-[11px] text-[#606060]">eu-west-1</p>
				</div>
			</div>
		</div>
	</aside>

	<header
		class="sticky top-0 z-20 flex h-[70px] items-center justify-between border-b border-[#e8e8e8] bg-white px-4 sm:px-7 lg:px-8"
	>
		<div class="flex items-center gap-3 lg:hidden">
			<div
				class="grid h-9 w-9 place-items-center rounded-lg bg-[#4880ff] text-sm font-extrabold text-white"
			>
				C
			</div>
			<p class="font-extrabold text-[#4880ff]">Compari<span class="text-[#202224]">Stack</span></p>
		</div>
		<label
			class="hidden h-10 w-[330px] items-center gap-3 rounded-full border border-[#d5d5d5] bg-[#f5f6fa] px-4 md:flex"
		>
			<svg
				viewBox="0 0 24 24"
				class="h-4 w-4 text-[#202224]/50"
				fill="none"
				stroke="currentColor"
				stroke-width="1.8"
				aria-hidden="true"><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></svg
			>
			<input
				class="w-full border-0 bg-transparent text-sm outline-none placeholder:text-[#202224]/40"
				placeholder="Search jobs"
				aria-label="Search jobs"
			/>
		</label>
		<div class="ml-auto flex items-center gap-4 sm:gap-6">
			<button
				type="button"
				class="relative grid h-9 w-9 place-items-center rounded-full text-[#4880ff] hover:bg-[#f5f6fa]"
				aria-label="Notifications"
			>
				<svg
					viewBox="0 0 24 24"
					class="h-5 w-5"
					fill="none"
					stroke="currentColor"
					stroke-width="1.8"
					aria-hidden="true"
					><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9" /><path d="M10 21h4" /></svg
				>
				<span
					class="absolute top-0 right-0 grid h-4 min-w-4 place-items-center rounded-full bg-[#f93c65] px-1 text-[9px] font-bold text-white"
					>{queuedPairs}</span
				>
			</button>
			<div class="h-7 border-l border-[#e8e8e8]"></div>
			{#if api.mode === 'live' && !authUser}
				<button
					type="button"
					onclick={() => void login()}
					disabled={authBusy || !isCognitoConfigured()}
					class="rounded-lg bg-[#4880ff] px-4 py-2.5 text-sm font-bold text-white transition hover:bg-[#3d72e8] disabled:cursor-not-allowed disabled:opacity-50"
					>{authBusy ? 'Redirecting…' : 'Sign in'}</button
				>
			{:else}
				<div class="flex items-center gap-3">
					<div
						class="grid h-11 w-11 place-items-center rounded-full bg-[#e7efff] text-sm font-extrabold text-[#4880ff]"
					>
						{userInitials(authUser)}
					</div>
					<div class="hidden sm:block">
						<p class="max-w-44 truncate text-sm font-bold text-[#404040]">
							{authUser?.email ?? 'Malay Joshi'}
						</p>
						<button
							type="button"
							onclick={logout}
							class="text-left text-xs text-[#565656] hover:text-[#4880ff]"
							>{api.mode === 'demo' ? 'Demo administrator' : 'Sign out'}</button
						>
					</div>
				</div>
			{/if}
		</div>
	</header>

	<main id="dashboard" class="px-4 py-7 sm:px-7 lg:px-8">
		<section class="mb-7 flex flex-col justify-between gap-4 xl:flex-row xl:items-start">
			<div>
				<h1 class="text-3xl font-bold tracking-tight">Comparison Dashboard</h1>
				<p class="mt-2 text-sm leading-6 text-[#606060]">
					Track every folder pair as workers compare, persist, and publish durable results.
				</p>
			</div>
			{#if api.mode === 'demo'}<div
					class="flex max-w-lg gap-3 rounded-lg border border-[#ffb648]/25 bg-[#fff7e8] px-4 py-3 text-xs leading-5 text-[#805d1b]"
				>
					<svg
						viewBox="0 0 24 24"
						class="mt-0.5 h-4 w-4 shrink-0"
						fill="none"
						stroke="currentColor"
						stroke-width="1.8"
						aria-hidden="true"><circle cx="12" cy="12" r="9" /><path d="M12 8v5m0 3h.01" /></svg
					>
					<p>
						Demo mode follows the production API contract with simulated timings. Live mode connects
						the same interface to API Gateway.
					</p>
				</div>{/if}
		</section>

		<section class="mb-7 grid gap-5 sm:grid-cols-2 2xl:grid-cols-4">
			<div class="metric-card">
				<div>
					<p class="metric-label">Job progress</p>
					<p class="metric-value">{progressPercent}%</p>
					<p class="metric-caption">
						{job?.completedPairs ?? 0} of {job?.totalPairs ?? 0} pairs complete
					</p>
				</div>
				<span class="metric-icon bg-[#e5e4ff] text-[#8280ff]"
					><svg
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="1.8"
						aria-hidden="true"><path d="M4 19V9m5 10V5m5 14v-7m5 7V3" /></svg
					></span
				>
			</div>
			<div class="metric-card">
				<div>
					<p class="metric-label">Active workers</p>
					<p class="metric-value">{activePairs}</p>
					<p class="metric-caption">{queuedPairs} tasks waiting in queue</p>
				</div>
				<span class="metric-icon bg-[#fff3d6] text-[#fec53d]"
					><svg
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="1.8"
						aria-hidden="true"><path d="M8 7V3m8 4V3M6 11h12M5 7h14v14H5z" /></svg
					></span
				>
			</div>
			<div class="metric-card">
				<div>
					<p class="metric-label">Result objects</p>
					<p class="metric-value">{resultCount}</p>
					<p class="metric-caption">Encrypted JSON stored in S3</p>
				</div>
				<span class="metric-icon bg-[#d9f7e8] text-[#4ad991]"
					><svg
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="1.8"
						aria-hidden="true"
						><path d="M4 6c0-2 3.6-3 8-3s8 1 8 3-3.6 3-8 3-8-1-8-3Z" /><path
							d="M4 6v6c0 2 3.6 3 8 3s8-1 8-3V6m-16 6v6c0 2 3.6 3 8 3s8-1 8-3v-6"
						/></svg
					></span
				>
			</div>
			<div class="metric-card">
				<div>
					<p class="metric-label">Measured scaling</p>
					<p class="metric-value">3.73×</p>
					<p class="metric-caption">Throughput with 4 local workers</p>
				</div>
				<span class="metric-icon bg-[#ffded2] text-[#ff9066]"
					><svg
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="1.8"
						aria-hidden="true"><path d="m4 16 5-5 4 4 7-9" /><path d="M15 6h5v5" /></svg
					></span
				>
			</div>
		</section>

		<div id="jobs" class="grid gap-6 2xl:grid-cols-[minmax(0,1fr)_390px]">
			<section class="dashboard-card min-w-0">
				<div class="border-b border-[#e8e8e8] px-5 py-5 sm:px-6">
					<div class="flex flex-wrap items-start justify-between gap-3">
						<div>
							<div class="flex items-center gap-2">
								<h2 class="text-lg font-bold">Current comparison</h2>
								{#if polling}<span class="h-2 w-2 animate-pulse rounded-full bg-[#00b69b]"
									></span>{/if}
							</div>
							<p class="mt-1 font-mono text-xs text-[#7a7a7a]">
								{job ? shortId(job.jobId) : 'No job submitted'}
							</p>
						</div>
						{#if job}<span
								class={`rounded-[5px] px-4 py-1.5 text-xs font-bold ${job.status === 'completed' ? 'bg-[#d9f4ef] text-[#00a389]' : 'bg-[#ebe4fd] text-[#6226ef]'}`}
								>{job.status}</span
							>{/if}
					</div>
					<div class="mt-5 h-2 overflow-hidden rounded-full bg-[#edf0f7]">
						<div
							class="h-full rounded-full bg-[#4880ff] transition-[width] duration-500"
							style={`width: ${progressPercent}%`}
						></div>
					</div>
					<div class="mt-3 flex flex-wrap gap-x-6 gap-y-1 text-xs text-[#7a7a7a]">
						<span>Started {formatTime(job?.startedAt)}</span><span
							>Completed {formatTime(job?.completedAt)}</span
						><span>Failures {job?.failedPairs ?? 0}</span>
					</div>
				</div>
				<div class="overflow-x-auto">
					<table class="w-full min-w-[720px] text-left text-sm">
						<thead
							class="border-b border-[#e8e8e8] bg-[#fafbfd] text-xs font-bold tracking-[0.3px] text-[#202224]/65 uppercase"
							><tr
								><th class="px-6 py-4">Source</th><th class="px-6 py-4">Destination</th><th
									class="px-6 py-4">Status</th
								><th class="px-6 py-4">Completed</th><th class="px-6 py-4">Result</th></tr
							></thead
						><tbody class="divide-y divide-[#e8e8e8]"
							>{#each job?.pairs ?? [] as pair (`${pair.sourceFolder}:${pair.destinationFolder}`)}<tr
									class="transition hover:bg-[#f8f9fc]"
									><td class="px-6 py-4 font-mono text-xs font-semibold">{pair.sourceFolder}</td><td
										class="px-6 py-4 font-mono text-xs font-semibold">{pair.destinationFolder}</td
									><td class="px-6 py-4"
										><span
											class={`inline-flex min-w-[88px] justify-center rounded-[5px] px-3 py-1.5 text-xs font-bold capitalize ${statusClasses(pair.status)}`}
											>{pair.status}</span
										></td
									><td class="px-6 py-4 text-xs text-[#7a7a7a]">{formatTime(pair.completedAt)}</td
									><td class="max-w-[220px] truncate px-6 py-4 text-xs"
										>{#if pair.resultUrl}<a
												class="font-semibold text-[#4880ff] hover:underline"
												href={pair.resultUrl}
												target="_blank"
												rel="external noreferrer">View JSON</a
											>{:else}—{/if}</td
									></tr
								>{:else}<tr
									><td colspan="5" class="px-6 py-16 text-center text-sm text-[#7a7a7a]"
										>Submit a job to see pair-level progress.</td
									></tr
								>{/each}</tbody
						>
					</table>
				</div>
			</section>

			<aside class="dashboard-card p-5 sm:p-6">
				<div class="flex items-start justify-between gap-3">
					<div>
						<h2 class="text-lg font-bold">Submit comparison</h2>
						<p class="mt-1 text-xs leading-5 text-[#7a7a7a]">
							Each row becomes an independently retryable SQS message.
						</p>
					</div>
					<span class="rounded-md bg-[#eef2ff] px-2.5 py-1 text-xs font-bold text-[#4880ff]"
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
						><span class="mb-1.5 block text-xs font-bold text-[#404040]">Callback ID</span><input
							bind:value={callbackId}
							class="form-input"
							placeholder="client-demo"
						/></label
					>
					<div class="max-h-[420px] space-y-3 overflow-y-auto pr-1">
						{#each pairs as pair, index (pair)}<div
								class="rounded-xl border border-[#e8e8e8] bg-[#fafbfd] p-3"
							>
								<div class="mb-2 flex items-center justify-between">
									<span class="text-[11px] font-bold tracking-wider text-[#7a7a7a] uppercase"
										>Pair {index + 1}</span
									><button
										type="button"
										class="text-xs font-semibold text-[#a0a0a0] hover:text-[#ef3826] disabled:opacity-30"
										disabled={pairs.length === 1}
										onclick={() => removePair(index)}>Remove</button
									>
								</div>
								<div class="grid grid-cols-[1fr_auto_1fr] items-center gap-2">
									<input
										aria-label={`Pair ${index + 1} source folder`}
										bind:value={pair.sourceFolder}
										class="form-input min-w-0 px-2.5 py-2 text-xs"
										placeholder="folder_a"
									/><svg
										viewBox="0 0 24 24"
										class="h-4 w-4 text-[#a0a0a0]"
										fill="none"
										stroke="currentColor"
										stroke-width="1.8"
										aria-hidden="true"><path d="M5 12h14m-5-5 5 5-5 5" /></svg
									><input
										aria-label={`Pair ${index + 1} destination folder`}
										bind:value={pair.destinationFolder}
										class="form-input min-w-0 px-2.5 py-2 text-xs"
										placeholder="folder_b"
									/>
								</div>
							</div>{/each}
					</div>
					<button
						type="button"
						onclick={addPair}
						disabled={pairs.length >= 100}
						class="w-full rounded-lg border border-dashed border-[#b9c3da] py-2.5 text-xs font-bold text-[#4880ff] transition hover:border-[#4880ff] hover:bg-[#f7f9ff] disabled:opacity-40"
						>+ Add folder pair</button
					>
					{#if error}<p
							role="alert"
							class="rounded-lg bg-[#fde5e2] px-3 py-2 text-xs leading-5 text-[#ef3826]"
						>
							{error}
						</p>{/if}
					<button
						type="submit"
						disabled={submitting || (api.mode === 'live' && !authUser)}
						class="flex w-full items-center justify-center gap-2 rounded-lg bg-[#4880ff] px-4 py-3 text-sm font-bold text-white shadow-[0_6px_16px_rgba(72,128,255,0.2)] transition hover:bg-[#3d72e8] disabled:cursor-not-allowed disabled:opacity-60"
						>{submitting
							? 'Submitting…'
							: api.mode === 'live' && !authUser
								? 'Sign in to submit'
								: job
									? 'Run another comparison'
									: 'Start comparison'}</button
					>
				</form>
			</aside>
		</div>

		<section id="pipeline" class="dashboard-card mt-6 p-5 sm:p-6">
			<div class="mb-5 flex flex-wrap items-end justify-between gap-3">
				<div>
					<h2 class="text-lg font-bold">Durable job path</h2>
					<p class="mt-1 text-xs text-[#7a7a7a]">
						The browser polls status while processing and callback delivery stay asynchronous.
					</p>
				</div>
				<span class="text-xs text-[#a0a0a0]">1 second demo · 2–3 seconds production</span>
			</div>
			<div class="grid gap-3 text-center text-xs sm:grid-cols-3 xl:grid-cols-7">
				{#each ['WAF + API', 'SQS queue', 'Worker ASG', 'EFS input', 'RDS state', 'S3 results', 'Callback queue'] as step, index (step)}<div
						class="rounded-xl border border-[#e8e8e8] bg-[#fafbfd] px-3 py-4 font-semibold text-[#404040]"
					>
						<span
							class="mx-auto mb-2 grid h-7 w-7 place-items-center rounded-full bg-[#e7efff] text-[10px] font-extrabold text-[#4880ff]"
							>{index + 1}</span
						>{step}
					</div>{/each}
			</div>
		</section>
	</main>
</div>
