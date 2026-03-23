<script lang="ts">
	import { page } from '$app/stores';
	import { Shield } from 'lucide-svelte';

	let newPassword = $state('');
	let confirmPassword = $state('');
	let loading = $state(false);
	let success = $state(false);
	let error = $state('');

	const token = $derived($page.url.searchParams.get('token') ?? '');

	async function handleSubmit(e: Event) {
		e.preventDefault();
		error = '';

		if (newPassword !== confirmPassword) {
			error = 'Passwords do not match.';
			return;
		}

		loading = true;

		try {
			const res = await fetch('/api/auth/reset-password', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					token,
					password: newPassword,
					confirm_password: confirmPassword
				})
			});

			if (res.ok) {
				success = true;
			} else {
				const data = await res.json().catch(() => ({}));
				error = data.error || 'Something went wrong. Please try again.';
			}
		} catch {
			error = 'Network error. Please try again.';
		}

		loading = false;
	}
</script>

<svelte:head>
	<title>Reset Password — SyncVault</title>
</svelte:head>

<div class="min-h-screen bg-gray-50 flex items-center justify-center px-4">
	<div class="w-full max-w-sm">
		<!-- Logo -->
		<div class="flex flex-col items-center mb-8">
			<div class="flex items-center gap-2 mb-2">
				<Shield size={32} class="text-blue-500" />
				<span class="text-2xl font-bold text-gray-900">SyncVault</span>
			</div>
			<p class="text-sm text-gray-500">Set a new password</p>
		</div>

		<!-- Card -->
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
			{#if !token}
				<div class="text-center space-y-4">
					<p class="text-sm text-red-600">Invalid or missing reset token.</p>
					<a
						href="/forgot-password"
						class="inline-block text-sm text-blue-500 hover:text-blue-600 hover:underline"
					>
						Request a new reset link
					</a>
				</div>
			{:else if success}
				<div class="text-center space-y-4">
					<p class="text-sm text-gray-700">
						Password reset successfully. You can now sign in with your new password.
					</p>
					<a
						href="/login"
						class="inline-block text-sm text-blue-500 hover:text-blue-600 hover:underline"
					>
						Go to login
					</a>
				</div>
			{:else}
				{#if error}
					<div class="mb-4 rounded-md bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
						{error}
					</div>
				{/if}

				<form onsubmit={handleSubmit} class="space-y-4">
					<div>
						<label for="new-password" class="block text-sm font-medium text-gray-700 mb-1">
							New password
						</label>
						<input
							id="new-password"
							type="password"
							bind:value={newPassword}
							required
							autocomplete="new-password"
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900 placeholder-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
							placeholder="Enter new password"
						/>
					</div>

					<div>
						<label for="confirm-password" class="block text-sm font-medium text-gray-700 mb-1">
							Confirm new password
						</label>
						<input
							id="confirm-password"
							type="password"
							bind:value={confirmPassword}
							required
							autocomplete="new-password"
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900 placeholder-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
							placeholder="Confirm new password"
						/>
					</div>

					<button
						type="submit"
						disabled={loading}
						class="w-full bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white font-medium rounded-md px-4 py-2 text-sm transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
					>
						{loading ? 'Resetting…' : 'Reset password'}
					</button>
				</form>
			{/if}
		</div>

		<p class="mt-6 text-center text-xs text-gray-400">SyncVault — Open Source File Sync & Backup</p>
	</div>
</div>
