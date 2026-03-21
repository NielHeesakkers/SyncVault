<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '$lib/api';
	import { BookOpen } from 'lucide-svelte';

	interface ChangelogVersion {
		version: string;
		date: string;
		changes: string[];
	}

	let currentVersion = $state('');
	let versions = $state<ChangelogVersion[]>([]);
	let loading = $state(true);

	onMount(async () => {
		try {
			const res = await api.get('/api/version');
			if (res.ok) {
				const data = await res.json();
				currentVersion = data.current_version;
				versions = data.changelog || [];
			}
		} finally {
			loading = false;
		}
	});
</script>

<svelte:head>
	<title>Changelog — SyncVault</title>
</svelte:head>

<div class="p-6 max-w-2xl">
	<div class="mb-6">
		<h1 class="text-xl font-semibold text-gray-900">Changelog</h1>
		<p class="text-sm text-gray-500 mt-1">Current version: <span class="font-mono font-medium text-blue-600">v{currentVersion}</span></p>
	</div>

	{#if loading}
		<div class="flex items-center justify-center py-16">
			<div class="w-7 h-7 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
		</div>
	{:else}
		<div class="space-y-6">
			{#each versions as ver}
				<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
					<div class="px-6 py-4 border-b border-gray-100 flex items-center justify-between">
						<div class="flex items-center gap-2">
							<BookOpen size={16} class="text-blue-500" />
							<span class="font-semibold text-gray-900">v{ver.version}</span>
							{#if ver.version === currentVersion}
								<span class="text-xs bg-green-100 text-green-700 px-2 py-0.5 rounded-full font-medium">current</span>
							{/if}
						</div>
						<span class="text-sm text-gray-500">{ver.date}</span>
					</div>
					<div class="px-6 py-4">
						<ul class="space-y-2">
							{#each ver.changes as change}
								<li class="flex items-start gap-2 text-sm text-gray-700">
									<span class="text-blue-400 mt-1.5 flex-shrink-0">&#8226;</span>
									{change}
								</li>
							{/each}
						</ul>
					</div>
				</div>
			{/each}
		</div>
	{/if}
</div>
