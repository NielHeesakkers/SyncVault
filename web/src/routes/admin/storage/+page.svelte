<script lang="ts">
	import { onMount } from 'svelte';
	import { HardDrive, User, FolderTree } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes } from '$lib/utils';
	import StorageBar from '$lib/components/StorageBar.svelte';

	interface StorageOverview {
		total: number;
		used: number;
		available: number;
	}

	interface UserStorage {
		id: string;
		username: string;
		storage_used: number;
		storage_quota?: number;
	}

	interface TeamStorage {
		id: string;
		name: string;
		size: number;
	}

	let overview = $state<StorageOverview | null>(null);
	let users = $state<UserStorage[]>([]);
	let teams = $state<TeamStorage[]>([]);
	let loading = $state(true);

	onMount(loadStorage);

	async function loadStorage() {
		loading = true;
		try {
			const [overviewRes, usersRes, teamsRes] = await Promise.all([
				api.get('/api/admin/storage'),
				api.get('/api/admin/storage/users'),
				api.get('/api/teams')
			]);

			if (overviewRes.ok) {
				overview = await overviewRes.json();
			}
			if (usersRes.ok) {
				const data = await usersRes.json();
				users = (data.users || data || []).sort(
					(a: UserStorage, b: UserStorage) => b.storage_used - a.storage_used
				);
			}
			if (teamsRes.ok) {
				const data = await teamsRes.json();
				const teamList = data.teams || data || [];
				const teamSizes: TeamStorage[] = [];
				try {
					const now = new Date().toISOString();
					const filesRes = await api.get(`/api/files/history?at=${now}`);
					if (filesRes.ok) {
						const filesData = await filesRes.json();
						const allFiles = filesData.files || [];
						for (const t of teamList) {
							const teamFolder = allFiles.find((f: any) => f.name === 'Team-' + t.name && f.is_dir);
							teamSizes.push({ id: t.id, name: t.name, size: teamFolder?.size || 0 });
						}
					} else {
						for (const t of teamList) {
							teamSizes.push({ id: t.id, name: t.name, size: 0 });
						}
					}
				} catch {
					for (const t of teamList) {
						teamSizes.push({ id: t.id, name: t.name, size: 0 });
					}
				}
				teams = teamSizes.sort((a, b) => b.size - a.size);
			}
		} catch {
			showToast('Failed to load storage data', 'error');
		} finally {
			loading = false;
		}
	}
</script>

<svelte:head>
	<title>Storage — SyncVault Admin</title>
</svelte:head>

<div class="p-6 space-y-5" style="background: var(--bg-base); min-height: 100%;">
	<div>
		<h1 class="text-base font-semibold" style="color: var(--text-primary);">Storage</h1>
		<p class="text-sm mt-1" style="color: var(--text-tertiary);">System-wide storage usage overview.</p>
	</div>

	{#if loading}
		<div class="space-y-5">
			{#each [1,2] as _}
				<div class="rounded-xl border p-6" style="background: var(--bg-elevated); border-color: var(--border);">
					<div class="skeleton h-4 rounded w-32 mb-4"></div>
					<div class="skeleton h-2 rounded w-full mb-3"></div>
					<div class="flex gap-8">
						<div class="skeleton h-10 rounded w-24"></div>
						<div class="skeleton h-10 rounded w-24"></div>
						<div class="skeleton h-10 rounded w-24"></div>
					</div>
				</div>
			{/each}
		</div>
	{:else}
		<!-- Overall storage -->
		<div class="rounded-xl border p-6" style="background: var(--bg-elevated); border-color: var(--border);">
			<div class="flex items-center gap-3 mb-5">
				<div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: rgba(59,130,246,0.15);">
					<HardDrive size={16} class="text-blue-400" />
				</div>
				<h2 class="text-sm font-semibold text-[var(--text-primary)]">Total Storage</h2>
			</div>
			{#if overview}
				<StorageBar used={overview.used} total={overview.total} />
				<div class="grid grid-cols-3 gap-4 mt-5">
					<div class="text-center">
						<p class="text-xl font-bold" style="color: var(--text-primary);">{formatBytes(overview.used)}</p>
						<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">Used</p>
					</div>
					<div class="text-center">
						<p class="text-xl font-bold text-green-400">{formatBytes(overview.available)}</p>
						<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">Available</p>
					</div>
					<div class="text-center">
						<p class="text-xl font-bold" style="color: var(--text-primary);">{formatBytes(overview.total)}</p>
						<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">Total</p>
					</div>
				</div>
			{:else}
				<p class="text-sm" style="color: var(--text-tertiary);">Storage data unavailable.</p>
			{/if}
		</div>

		<!-- Per user -->
		<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
			<div class="px-5 py-4 border-b flex items-center gap-2" style="border-color: var(--border);">
				<User size={15} class="text-blue-400" />
				<h2 class="text-sm font-semibold text-[var(--text-secondary)]">Storage by User</h2>
			</div>
			{#if users.length === 0}
				<div class="text-center py-10 text-sm" style="color: var(--text-tertiary);">No user data available.</div>
			{:else}
				<table class="min-w-full">
					<thead>
						<tr style="border-bottom: 1px solid var(--border);">
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">User</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Used</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: var(--text-tertiary);">Quota</th>
						</tr>
					</thead>
					<tbody>
						{#each users as user}
							<tr class="storage-row">
								<td class="px-4 py-3.5">
									<div class="flex items-center gap-2">
										<div class="w-7 h-7 rounded-full bg-blue-600/20 flex items-center justify-center text-blue-400 text-[10px] font-bold flex-shrink-0">
											{user.username[0].toUpperCase()}
										</div>
										<span class="text-sm font-medium text-[var(--text-secondary)]">{user.username}</span>
									</div>
								</td>
								<td class="px-4 py-3.5">
									<span class="text-sm text-[var(--text-secondary)]">{formatBytes(user.storage_used)}</span>
								</td>
								<td class="px-4 py-3.5 hidden md:table-cell">
									{#if user.storage_quota}
										<div class="w-40">
											<StorageBar used={user.storage_used} total={user.storage_quota} />
										</div>
									{:else}
										<span class="text-sm" style="color: var(--text-tertiary);">Unlimited</span>
									{/if}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			{/if}
		</div>

		<!-- Per team -->
		{#if teams.length > 0}
		<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
			<div class="px-5 py-4 border-b flex items-center gap-2" style="border-color: var(--border);">
				<FolderTree size={15} class="text-blue-400" />
				<h2 class="text-sm font-semibold text-[var(--text-secondary)]">Storage by Team</h2>
			</div>
			<table class="min-w-full">
				<thead>
					<tr style="border-bottom: 1px solid var(--border);">
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Team</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Used</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: var(--text-tertiary);">% of total</th>
					</tr>
				</thead>
				<tbody>
					{#each teams as team}
						<tr class="storage-row">
							<td class="px-4 py-3.5">
								<div class="flex items-center gap-2">
									<FolderTree size={14} class="text-blue-400" />
									<span class="text-sm font-medium text-[var(--text-secondary)]">{team.name}</span>
								</div>
							</td>
							<td class="px-4 py-3.5">
								<span class="text-sm text-[var(--text-secondary)]">{formatBytes(team.size)}</span>
							</td>
							<td class="px-4 py-3.5 hidden md:table-cell">
								{#if overview?.used && overview.used > 0}
									<div class="flex items-center gap-2">
										<div class="flex-1 max-w-24 rounded-full h-1.5" style="background: var(--border);">
											<div
												class="h-1.5 bg-blue-500 rounded-full"
												style="width: {Math.min(100, (team.size / overview.used) * 100).toFixed(1)}%"
											></div>
										</div>
										<span class="text-xs" style="color: var(--text-tertiary);">
											{((team.size / overview.used) * 100).toFixed(1)}%
										</span>
									</div>
								{:else}
									<span class="text-xs" style="color: var(--text-tertiary);">—</span>
								{/if}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
		{/if}
	{/if}
</div>

<style>
	.storage-row {
		border-bottom: 1px solid var(--border);
	}
	.storage-row:hover {
		background: var(--bg-hover);
	}
	.storage-row:last-child {
		border-bottom: none;
	}
</style>
