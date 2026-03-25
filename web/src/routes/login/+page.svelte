<script lang="ts">
	import { goto } from '$app/navigation';
	import { Shield } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { currentUser } from '$lib/stores';

	let username = $state('');
	let password = $state('');
	let error = $state('');
	let loading = $state(false);

	async function handleLogin(e: Event) {
		e.preventDefault();
		error = '';
		loading = true;
		const result = await api.login(username, password);
		if (result.ok) {
			const user = api.getUser();
			if (user) currentUser.set(user);
			goto('/dashboard', { replaceState: true });
		} else {
			error = result.error || 'Login failed';
		}
		loading = false;
	}
</script>

<svelte:head>
	<title>Login — SyncVault</title>
</svelte:head>

<div class="min-h-screen flex items-center justify-center px-4" style="background: var(--bg-base);">
	<div class="w-full max-w-sm">
		<!-- Logo -->
		<div class="flex flex-col items-center mb-8">
			<div class="w-12 h-12 rounded-2xl bg-blue-600 flex items-center justify-center mb-4">
				<Shield size={22} class="text-white" />
			</div>
			<h1 class="text-xl font-semibold text-white">SyncVault</h1>
			<p class="text-sm mt-1.5" style="color: var(--text-tertiary);">Sign in to your account</p>
		</div>

		<!-- Card -->
		<div class="rounded-xl border p-6" style="background: var(--bg-elevated); border-color: var(--border);">
			{#if error}
				<div class="mb-4 rounded-lg border px-4 py-3 text-sm text-red-400" style="background: rgba(239,68,68,0.08); border-color: rgba(239,68,68,0.20);">
					{error}
				</div>
			{/if}

			<form onsubmit={handleLogin} class="space-y-4">
				<div>
					<label for="username" class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Username</label>
					<input
						id="username"
						type="text"
						bind:value={username}
						required
						autocomplete="username"
						placeholder="Enter your username"
					/>
				</div>

				<div>
					<label for="password" class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Password</label>
					<input
						id="password"
						type="password"
						bind:value={password}
						required
						autocomplete="current-password"
						placeholder="Enter your password"
					/>
				</div>

				<button
					type="submit"
					disabled={loading}
					class="w-full bg-blue-600 hover:bg-blue-500 disabled:opacity-50 text-white font-medium rounded-lg px-4 py-2.5 text-sm transition-all duration-150 mt-2"
				>
					{loading ? 'Signing in…' : 'Sign in'}
				</button>

				<div class="text-center">
					<a href="/forgot-password" class="text-sm text-blue-400 hover:text-blue-300 transition-colors">
						Forgot Password?
					</a>
				</div>
			</form>
		</div>

		<p class="mt-6 text-center text-xs" style="color: var(--text-tertiary);">SyncVault — Open Source File Sync & Backup</p>
	</div>
</div>
