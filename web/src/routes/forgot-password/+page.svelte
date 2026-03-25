<script lang="ts">
	import { Shield } from 'lucide-svelte';

	let email = $state('');
	let loading = $state(false);
	let submitted = $state(false);
	let error = $state('');

	async function handleSubmit(e: Event) {
		e.preventDefault();
		error = '';
		loading = true;

		try {
			const res = await fetch('/api/auth/forgot-password', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ email })
			});

			if (res.ok) {
				submitted = true;
			} else {
				error = 'Something went wrong. Please try again.';
			}
		} catch {
			error = 'Network error. Please try again.';
		}

		loading = false;
	}
</script>

<svelte:head>
	<title>Forgot Password — SyncVault</title>
</svelte:head>

<div class="min-h-screen flex items-center justify-center px-4" style="background: var(--bg-base);">
	<div class="w-full max-w-sm">
		<!-- Logo -->
		<div class="flex flex-col items-center mb-8">
			<div class="w-12 h-12 rounded-2xl bg-blue-600 flex items-center justify-center mb-4">
				<Shield size={22} class="text-white" />
			</div>
			<h1 class="text-xl font-semibold text-white">SyncVault</h1>
			<p class="text-sm mt-1.5" style="color: var(--text-tertiary);">Reset your password</p>
		</div>

		<!-- Card -->
		<div class="rounded-xl border p-6" style="background: var(--bg-elevated); border-color: var(--border);">
			{#if submitted}
				<div class="text-center space-y-4">
					<p class="text-sm" style="color: var(--text-secondary);">
						If an account with this email exists, you will receive a reset link.
					</p>
					<a
						href="/login"
						class="inline-block text-sm text-blue-400 hover:text-blue-300 transition-colors"
					>
						Back to login
					</a>
				</div>
			{:else}
				{#if error}
					<div class="mb-4 rounded-lg border px-4 py-3 text-sm text-red-400" style="background: rgba(239,68,68,0.08); border-color: rgba(239,68,68,0.20);">
						{error}
					</div>
				{/if}

				<form onsubmit={handleSubmit} class="space-y-4">
					<p class="text-sm" style="color: var(--text-secondary);">
						Enter your email address and we will send you a link to reset your password.
					</p>

					<div>
						<label for="email" class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">
							Email address
						</label>
						<input
							id="email"
							type="email"
							bind:value={email}
							required
							autocomplete="email"
							placeholder="Enter your email address"
						/>
					</div>

					<button
						type="submit"
						disabled={loading}
						class="w-full bg-blue-600 hover:bg-blue-500 disabled:opacity-50 text-white font-medium rounded-lg px-4 py-2.5 text-sm transition-all duration-150 mt-2"
					>
						{loading ? 'Sending…' : 'Send reset link'}
					</button>

					<div class="text-center">
						<a
							href="/login"
							class="text-sm text-blue-400 hover:text-blue-300 transition-colors"
						>
							Back to login
						</a>
					</div>
				</form>
			{/if}
		</div>

		<p class="mt-6 text-center text-xs" style="color: var(--text-tertiary);">SyncVault — Open Source File Sync & Backup</p>
	</div>
</div>
