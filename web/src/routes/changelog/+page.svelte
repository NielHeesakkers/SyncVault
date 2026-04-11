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

<div class="p-6 max-w-2xl" style="background: var(--bg-base); min-height: 100%;">
	<div class="mb-6">
		<h1 class="text-base font-semibold" style="color: var(--text-primary);">Changelog</h1>
		<p class="text-sm mt-1" style="color: var(--text-tertiary);">
			Current version: <span class="font-mono text-blue-400">v{currentVersion}</span>
		</p>
	</div>

	{#if loading}
		<div class="space-y-4">
			{#each [1,2,3] as _}
				<div class="rounded-xl border p-5" style="background: var(--bg-elevated); border-color: var(--border);">
					<div class="skeleton h-4 rounded w-20 mb-4"></div>
					<div class="space-y-2">
						<div class="skeleton h-3 rounded w-full"></div>
						<div class="skeleton h-3 rounded w-4/5"></div>
						<div class="skeleton h-3 rounded w-3/5"></div>
					</div>
				</div>
			{/each}
		</div>
	{:else}
		<div class="space-y-4">
			{#each versions as ver}
				<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
					<div class="px-5 py-4 border-b flex items-center justify-between" style="border-color: var(--border);">
						<div class="flex items-center gap-2.5">
							<BookOpen size={15} class="text-blue-400" />
							<span class="text-sm font-semibold text-[var(--text-primary)]">v{ver.version}</span>
							{#if ver.version === currentVersion}
								<span class="text-[10px] font-semibold px-2 py-0.5 rounded-full" style="background: rgba(34,197,94,0.12); color: #4ade80; border: 1px solid rgba(34,197,94,0.20);">current</span>
							{/if}
						</div>
						<span class="text-xs" style="color: var(--text-tertiary);">{ver.date}</span>
					</div>
					<div class="px-5 py-4">
						<ul class="space-y-2">
							{#each ver.changes as change}
								<li class="flex items-start gap-2 text-sm" style="color: var(--text-secondary);">
									<span class="text-blue-500 mt-1.5 flex-shrink-0 text-xs">&#8226;</span>
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
