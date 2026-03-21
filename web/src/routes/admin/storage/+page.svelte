<script lang="ts">
	import { onMount } from 'svelte';
	import { HardDrive, FolderOpen, User, Settings2 } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes } from '$lib/utils';
	import StorageBar from '$lib/components/StorageBar.svelte';

	interface StorageOverview {
		total: number;
		used: number;
		available: number;
	}

	interface FolderStorage {
		id: string;
		name: string;
		path?: string;
		size: number;
	}

	interface UserStorage {
		id: string;
		username: string;
		storage_used: number;
		storage_quota?: number;
	}

	let overview = $state<StorageOverview | null>(null);
	let folders = $state<FolderStorage[]>([]);
	let users = $state<UserStorage[]>([]);
	let loading = $state(true);

	interface RetentionPolicy {
		folder_id: string;
		max_versions: number;
		algorithm: 'fifo' | 'intelliversioning';
		daily_days: number;
		weekly_weeks: number;
		monthly_months: number;
		yearly_keep_forever: boolean;
	}

	let retentionPolicies = $state<Record<string, RetentionPolicy>>({});
	let savingRetention = $state<Record<string, boolean>>({});

	onMount(loadStorage);

	async function loadStorage() {
		loading = true;
		try {
			const [overviewRes, foldersRes, usersRes] = await Promise.all([
				api.get('/api/admin/storage'),
				api.get('/api/admin/storage/folders'),
				api.get('/api/admin/storage/users')
			]);

			if (overviewRes.ok) {
				const data = await overviewRes.json();
				overview = data;
			}
			if (foldersRes.ok) {
				const data = await foldersRes.json();
				folders = (data.folders || data || []).sort(
					(a: FolderStorage, b: FolderStorage) => b.size - a.size
				);
			}
			if (usersRes.ok) {
				const data = await usersRes.json();
				users = (data.users || data || []).sort(
					(a: UserStorage, b: UserStorage) => b.storage_used - a.storage_used
				);
			}
		} catch {
			showToast('Failed to load storage data', 'error');
		} finally {
			loading = false;
		}
	}
	function getRetention(folderId: string): RetentionPolicy {
		return retentionPolicies[folderId] ?? {
			folder_id: folderId,
			max_versions: 32,
			algorithm: 'fifo',
			daily_days: 7,
			weekly_weeks: 4,
			monthly_months: 12,
			yearly_keep_forever: true
		};
	}

	function setRetentionField<K extends keyof RetentionPolicy>(
		folderId: string,
		field: K,
		value: RetentionPolicy[K]
	) {
		const current = getRetention(folderId);
		retentionPolicies = { ...retentionPolicies, [folderId]: { ...current, [field]: value } };
	}

	async function saveRetention(folderId: string) {
		const policy = getRetention(folderId);
		savingRetention = { ...savingRetention, [folderId]: true };
		try {
			const payload: Record<string, string> = {
				[`retention.${folderId}.max_versions`]: String(policy.max_versions),
				[`retention.${folderId}.algorithm`]: policy.algorithm,
				[`retention.${folderId}.daily_days`]: String(policy.daily_days),
				[`retention.${folderId}.weekly_weeks`]: String(policy.weekly_weeks),
				[`retention.${folderId}.monthly_months`]: String(policy.monthly_months),
				[`retention.${folderId}.yearly_keep_forever`]: policy.yearly_keep_forever ? 'true' : 'false'
			};
			const res = await api.put('/api/admin/settings', payload);
			if (res.ok) {
				showToast('Retention policy saved', 'success');
			} else {
				showToast('Failed to save retention policy', 'error');
			}
		} finally {
			savingRetention = { ...savingRetention, [folderId]: false };
		}
	}

</script>

<svelte:head>
	<title>Storage — SyncVault Admin</title>
</svelte:head>

<div class="p-6 space-y-6">
	<div>
		<h1 class="text-xl font-semibold text-gray-900">Storage</h1>
		<p class="text-sm text-gray-500 mt-1">System-wide storage usage overview.</p>
	</div>

	{#if loading}
		<div class="flex items-center justify-center py-16">
			<div class="w-7 h-7 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
		</div>
	{:else}
		<!-- Overall storage -->
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
			<div class="flex items-center gap-3 mb-5">
				<div class="p-2 bg-blue-50 rounded-lg">
					<HardDrive size={22} class="text-blue-500" />
				</div>
				<h2 class="text-base font-semibold text-gray-900">Total Storage</h2>
			</div>
			{#if overview}
				<StorageBar used={overview.used} total={overview.total} />
				<div class="grid grid-cols-3 gap-4 mt-5">
					<div class="text-center">
						<p class="text-2xl font-bold text-gray-900">{formatBytes(overview.used)}</p>
						<p class="text-xs text-gray-500 mt-0.5">Used</p>
					</div>
					<div class="text-center">
						<p class="text-2xl font-bold text-green-600">{formatBytes(overview.available)}</p>
						<p class="text-xs text-gray-500 mt-0.5">Available</p>
					</div>
					<div class="text-center">
						<p class="text-2xl font-bold text-gray-900">{formatBytes(overview.total)}</p>
						<p class="text-xs text-gray-500 mt-0.5">Total</p>
					</div>
				</div>
			{:else}
				<p class="text-sm text-gray-400">Storage data unavailable.</p>
			{/if}
		</div>

		<!-- Per folder -->
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
			<div class="px-6 py-4 border-b border-gray-200 flex items-center gap-2">
				<FolderOpen size={18} class="text-yellow-500" />
				<h2 class="text-base font-semibold text-gray-900">Storage by Folder</h2>
			</div>
			{#if folders.length === 0}
				<div class="text-center py-10 text-gray-400 text-sm">No folder data available.</div>
			{:else}
				<table class="min-w-full divide-y divide-gray-200">
					<thead class="bg-gray-50">
						<tr>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Folder</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Size</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">% of total</th>
						</tr>
					</thead>
					<tbody class="bg-white divide-y divide-gray-200">
						{#each folders as folder}
							<tr class="hover:bg-gray-50">
								<td class="px-4 py-3">
									<div class="flex items-center gap-2">
										<FolderOpen size={16} class="text-yellow-400" />
										<div>
											<p class="text-sm font-medium text-gray-900">{folder.name}</p>
											{#if folder.path}
												<p class="text-xs text-gray-400">{folder.path}</p>
											{/if}
										</div>
									</div>
								</td>
								<td class="px-4 py-3">
									<span class="text-sm font-medium text-gray-900">{formatBytes(folder.size)}</span>
								</td>
								<td class="px-4 py-3 hidden md:table-cell">
									{#if overview?.used}
										<div class="flex items-center gap-2">
											<div class="flex-1 max-w-24 bg-gray-200 rounded-full h-1.5">
												<div
													class="h-1.5 bg-blue-400 rounded-full"
													style="width: {Math.min(100, (folder.size / overview.used) * 100).toFixed(1)}%"
												></div>
											</div>
											<span class="text-xs text-gray-500">
												{((folder.size / overview.used) * 100).toFixed(1)}%
											</span>
										</div>
									{/if}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			{/if}
		</div>

		<!-- Per user -->
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
			<div class="px-6 py-4 border-b border-gray-200 flex items-center gap-2">
				<User size={18} class="text-blue-500" />
				<h2 class="text-base font-semibold text-gray-900">Storage by User</h2>
			</div>
			{#if users.length === 0}
				<div class="text-center py-10 text-gray-400 text-sm">No user data available.</div>
			{:else}
				<table class="min-w-full divide-y divide-gray-200">
					<thead class="bg-gray-50">
						<tr>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">User</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Used</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Quota</th>
						</tr>
					</thead>
					<tbody class="bg-white divide-y divide-gray-200">
						{#each users as user}
							<tr class="hover:bg-gray-50">
								<td class="px-4 py-3">
									<div class="flex items-center gap-2">
										<div class="w-7 h-7 rounded-full bg-blue-100 flex items-center justify-center text-blue-600 text-xs font-bold flex-shrink-0">
											{user.username[0].toUpperCase()}
										</div>
										<span class="text-sm font-medium text-gray-900">{user.username}</span>
									</div>
								</td>
								<td class="px-4 py-3">
									<span class="text-sm text-gray-900">{formatBytes(user.storage_used)}</span>
								</td>
								<td class="px-4 py-3 hidden md:table-cell">
									{#if user.storage_quota}
										<div class="w-40">
											<StorageBar used={user.storage_used} total={user.storage_quota} />
										</div>
									{:else}
										<span class="text-sm text-gray-400">Unlimited</span>
									{/if}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			{/if}
		</div>

		<!-- Retention / versioning settings -->
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
			<div class="px-6 py-4 border-b border-gray-200 flex items-center gap-2">
				<Settings2 size={18} class="text-purple-500" />
				<h2 class="text-base font-semibold text-gray-900">Retention &amp; Versioning</h2>
			</div>
			{#if folders.length === 0}
				<div class="text-center py-10 text-gray-400 text-sm">No folders available.</div>
			{:else}
				<div class="divide-y divide-gray-100">
					{#each folders as folder}
						{@const policy = getRetention(folder.id)}
						<div class="px-6 py-5 space-y-4">
							<div class="flex items-center gap-2 mb-1">
								<FolderOpen size={15} class="text-yellow-400" />
								<span class="text-sm font-semibold text-gray-900">{folder.name}</span>
							</div>

							<!-- Max versions -->
							<div>
								<label class="block text-xs font-medium text-gray-600 mb-1">
									Max versions: <span class="font-bold text-gray-800">{policy.max_versions}</span>
								</label>
								<input
									type="range"
									min="1" max="32"
									value={policy.max_versions}
									onchange={(e) => setRetentionField(folder.id, 'max_versions', Number((e.target as HTMLInputElement).value))}
									class="w-full accent-blue-500"
								/>
								<div class="flex justify-between text-xs text-gray-400 mt-0.5"><span>1</span><span>32</span></div>
							</div>

							<!-- Rotation algorithm -->
							<div>
								<label class="block text-xs font-medium text-gray-600 mb-1">Rotation algorithm</label>
								<select
									value={policy.algorithm}
									onchange={(e) => setRetentionField(folder.id, 'algorithm', (e.target as HTMLSelectElement).value as 'fifo' | 'intelliversioning')}
									class="w-full rounded-md border border-gray-300 px-3 py-1.5 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
								>
									<option value="fifo">FIFO (first in, first out)</option>
									<option value="intelliversioning">Intelliversioning (smart thinning)</option>
								</select>
							</div>

							<!-- Retention schedule -->
							<div class="grid grid-cols-2 gap-3">
								<div>
									<label class="block text-xs font-medium text-gray-600 mb-1">Keep daily (days)</label>
									<input
										type="number" min="0" max="365"
										value={policy.daily_days}
										onchange={(e) => setRetentionField(folder.id, 'daily_days', Number((e.target as HTMLInputElement).value))}
										class="w-full rounded-md border border-gray-300 px-3 py-1.5 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
									/>
								</div>
								<div>
									<label class="block text-xs font-medium text-gray-600 mb-1">Keep weekly (weeks)</label>
									<input
										type="number" min="0" max="52"
										value={policy.weekly_weeks}
										onchange={(e) => setRetentionField(folder.id, 'weekly_weeks', Number((e.target as HTMLInputElement).value))}
										class="w-full rounded-md border border-gray-300 px-3 py-1.5 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
									/>
								</div>
								<div>
									<label class="block text-xs font-medium text-gray-600 mb-1">Keep monthly (months)</label>
									<input
										type="number" min="0" max="120"
										value={policy.monthly_months}
										onchange={(e) => setRetentionField(folder.id, 'monthly_months', Number((e.target as HTMLInputElement).value))}
										class="w-full rounded-md border border-gray-300 px-3 py-1.5 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
									/>
								</div>
								<div class="flex items-center gap-2 pt-5">
									<input
										type="checkbox"
										id="yearly-{folder.id}"
										checked={policy.yearly_keep_forever}
										onchange={(e) => setRetentionField(folder.id, 'yearly_keep_forever', (e.target as HTMLInputElement).checked)}
										class="rounded border-gray-300 text-blue-500"
									/>
									<label for="yearly-{folder.id}" class="text-xs font-medium text-gray-600">Keep yearly forever</label>
								</div>
							</div>

							<div class="flex justify-end">
								<button
									onclick={() => saveRetention(folder.id)}
									disabled={savingRetention[folder.id]}
									class="rounded-md px-4 py-1.5 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors"
								>
									{savingRetention[folder.id] ? 'Saving…' : 'Save'}
								</button>
							</div>
						</div>
					{/each}
				</div>
			{/if}
		</div>
	{/if}
</div>
