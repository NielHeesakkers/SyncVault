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

<div class="min-h-screen bg-gray-50 flex items-center justify-center px-4">
	<div class="w-full max-w-sm">
		<!-- Logo -->
		<div class="flex flex-col items-center mb-8">
			<div class="flex items-center gap-2 mb-2">
				<Shield size={32} class="text-blue-500" />
				<span class="text-2xl font-bold text-gray-900">SyncVault</span>
			</div>
			<p class="text-sm text-gray-500">Reset your password</p>
		</div>

		<!-- Card -->
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
			{#if submitted}
				<div class="text-center space-y-4">
					<p class="text-sm text-gray-700">
						If an account with this email exists, you will receive a reset link.
					</p>
					<a
						href="/login"
						class="inline-block text-sm text-blue-500 hover:text-blue-600 hover:underline"
					>
						Back to login
					</a>
				</div>
			{:else}
				{#if error}
					<div class="mb-4 rounded-md bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
						{error}
					</div>
				{/if}

				<form onsubmit={handleSubmit} class="space-y-4">
					<p class="text-sm text-gray-600">
						Enter your email address and we will send you a link to reset your password.
					</p>

					<div>
						<label for="email" class="block text-sm font-medium text-gray-700 mb-1">
							Email address
						</label>
						<input
							id="email"
							type="email"
							bind:value={email}
							required
							autocomplete="email"
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900 placeholder-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
							placeholder="Enter your email address"
						/>
					</div>

					<button
						type="submit"
						disabled={loading}
						class="w-full bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white font-medium rounded-md px-4 py-2 text-sm transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
					>
						{loading ? 'Sending…' : 'Send reset link'}
					</button>

					<div class="text-center">
						<a
							href="/login"
							class="text-sm text-blue-500 hover:text-blue-600 hover:underline"
						>
							Back to login
						</a>
					</div>
				</form>
			{/if}
		</div>

		<p class="mt-6 text-center text-xs text-gray-400">SyncVault — Open Source File Sync & Backup</p>
	</div>
</div>
