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

<div class="min-h-screen flex items-center justify-center px-4" style="background: #0a0a0b;">
	<div class="w-full max-w-sm">
		<!-- Logo -->
		<div class="flex flex-col items-center mb-8">
			<div class="w-12 h-12 rounded-2xl bg-blue-600 flex items-center justify-center mb-4">
				<Shield size={22} class="text-white" />
			</div>
			<h1 class="text-xl font-semibold text-white">SyncVault</h1>
			<p class="text-sm mt-1.5" style="color: rgba(255,255,255,0.40);">Set a new password</p>
		</div>

		<!-- Card -->
		<div class="rounded-xl border p-6" style="background: #111113; border-color: rgba(255,255,255,0.07);">
			{#if !token}
				<div class="text-center space-y-4">
					<p class="text-sm text-red-400">Invalid or missing reset token.</p>
					<a
						href="/forgot-password"
						class="inline-block text-sm text-blue-400 hover:text-blue-300 transition-colors"
					>
						Request a new reset link
					</a>
				</div>
			{:else if success}
				<div class="text-center space-y-4">
					<p class="text-sm" style="color: rgba(255,255,255,0.60);">
						Password reset successfully. You can now sign in with your new password.
					</p>
					<a
						href="/login"
						class="inline-block text-sm text-blue-400 hover:text-blue-300 transition-colors"
					>
						Go to login
					</a>
				</div>
			{:else}
				{#if error}
					<div class="mb-4 rounded-lg border px-4 py-3 text-sm text-red-400" style="background: rgba(239,68,68,0.08); border-color: rgba(239,68,68,0.20);">
						{error}
					</div>
				{/if}

				<form onsubmit={handleSubmit} class="space-y-4">
					<div>
						<label for="new-password" class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.50);">
							New password
						</label>
						<input
							id="new-password"
							type="password"
							bind:value={newPassword}
							required
							autocomplete="new-password"
							placeholder="Enter new password"
						/>
					</div>

					<div>
						<label for="confirm-password" class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.50);">
							Confirm new password
						</label>
						<input
							id="confirm-password"
							type="password"
							bind:value={confirmPassword}
							required
							autocomplete="new-password"
							placeholder="Confirm new password"
						/>
					</div>

					<button
						type="submit"
						disabled={loading}
						class="w-full bg-blue-600 hover:bg-blue-500 disabled:opacity-50 text-white font-medium rounded-lg px-4 py-2.5 text-sm transition-all duration-150 mt-2"
					>
						{loading ? 'Resetting…' : 'Reset password'}
					</button>
				</form>
			{/if}
		</div>

		<p class="mt-6 text-center text-xs" style="color: rgba(255,255,255,0.20);">SyncVault — Open Source File Sync & Backup</p>
	</div>
</div>
