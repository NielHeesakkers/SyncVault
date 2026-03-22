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
			goto('/files', { replaceState: true });
		} else {
			error = result.error || 'Login failed';
		}

		loading = false;
	}
</script>

<svelte:head>
	<title>Login — SyncVault</title>
</svelte:head>

<div class="min-h-screen bg-gray-50 flex items-center justify-center px-4">
	<div class="w-full max-w-sm">
		<!-- Logo -->
		<div class="flex flex-col items-center mb-8">
			<div class="flex items-center gap-2 mb-2">
				<Shield size={32} class="text-blue-500" />
				<span class="text-2xl font-bold text-gray-900">SyncVault</span>
			</div>
			<p class="text-sm text-gray-500">Sign in to your account</p>
		</div>

		<!-- Card -->
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
			{#if error}
				<div class="mb-4 rounded-md bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
					{error}
				</div>
			{/if}

			<form onsubmit={handleLogin} class="space-y-4">
				<div>
					<label for="username" class="block text-sm font-medium text-gray-700 mb-1">
						Username
					</label>
					<input
						id="username"
						type="text"
						bind:value={username}
						required
						autocomplete="username"
						class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900 placeholder-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						placeholder="Enter your username"
					/>
				</div>

				<div>
					<label for="password" class="block text-sm font-medium text-gray-700 mb-1">
						Password
					</label>
					<input
						id="password"
						type="password"
						bind:value={password}
						required
						autocomplete="current-password"
						class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900 placeholder-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						placeholder="Enter your password"
					/>
				</div>

				<button
					type="submit"
					disabled={loading}
					class="w-full bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white font-medium rounded-md px-4 py-2 text-sm transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
				>
					{loading ? 'Signing in…' : 'Sign in'}
				</button>
			</form>
		</div>

		<p class="mt-6 text-center text-xs text-gray-400">SyncVault — Open Source File Sync & Backup</p>
	</div>
</div>
