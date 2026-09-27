<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import { completeSignIn } from '$lib/auth';

	let error = $state('');

	onMount(async () => {
		try {
			await completeSignIn();
			window.location.replace(resolve('/'));
		} catch (cause) {
			error = cause instanceof Error ? cause.message : 'Sign-in could not be completed.';
		}
	});
</script>

<svelte:head><title>Signing in · Comparison Engine</title></svelte:head>

<main class="grid min-h-screen place-items-center bg-[#f5f6fa] px-6">
	<section
		class="w-full max-w-md rounded-[14px] bg-white p-8 text-center shadow-[6px_6px_54px_rgba(0,0,0,0.05)]"
	>
		<div
			class="mx-auto grid h-12 w-12 place-items-center rounded-xl bg-[#e7efff] text-lg font-extrabold text-[#4880ff]"
		>
			C
		</div>
		{#if error}
			<h1 class="mt-5 text-xl font-bold">Sign-in failed</h1>
			<p class="mt-2 text-sm leading-6 text-[#ef3826]">{error}</p>
			<a
				class="mt-6 inline-flex rounded-lg bg-[#4880ff] px-5 py-2.5 text-sm font-bold text-white"
				href={resolve('/')}>Return to dashboard</a
			>
		{:else}
			<h1 class="mt-5 text-xl font-bold">Completing sign-in</h1>
			<p class="mt-2 text-sm text-[#606060]">Exchanging the Cognito authorization code securely.</p>
			<div class="mx-auto mt-6 h-2 w-40 overflow-hidden rounded-full bg-[#edf0f7]">
				<div class="h-full w-2/3 animate-pulse rounded-full bg-[#4880ff]"></div>
			</div>
		{/if}
	</section>
</main>
