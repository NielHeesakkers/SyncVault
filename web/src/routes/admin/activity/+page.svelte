<script lang="ts">
	import { onMount } from 'svelte';
	import { Activity, Filter, ChevronDown } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatDateAbsolute } from '$lib/utils';

	interface ActivityLog {
		id: string;
		user_id?: string;
		username?: string;
		action: string;
		resource_type?: string;
		resource_name?: string;
		details?: string;
		created_at: string;
		ip_address?: string;
	}

	interface UserOption {
		id: string;
		username: string;
	}

	let logs = $state<ActivityLog[]>([]);
	let loading = $state(true);
	let loadingMore = $state(false);
	let hasMore = $state(false);
	let page = $state(1);
	const PAGE_SIZE = 50;

	let filterUser = $state('');
	let filterAction = $state('');
	let filterDateFrom = $state('');
	let filterDateTo = $state('');

	let allUsers = $state<UserOption[]>([]);

	const actionTypes = [
		'login',
		'logout',
		'upload',
		'download',
		'delete',
		'restore',
		'create_folder',
		'rename',
		'move',
		'share_create',
		'share_delete',
		'user_create',
		'user_update',
		'user_delete'
	];

	onMount(async () => {
		const [, usersRes] = await Promise.all([loadLogs(true), api.get('/api/admin/users')]);
		if (usersRes.ok) {
			const data = await usersRes.json();
			allUsers = (data.users || data || []).map((u: { id: string; username: string }) => ({
				id: u.id,
				username: u.username
			}));
		}
	});

	async function loadLogs(reset = false) {
		if (reset) {
			page = 1;
			logs = [];
			loading = true;
		} else {
			loadingMore = true;
		}

		try {
			const params = new URLSearchParams({
				page: String(page),
				limit: String(PAGE_SIZE)
			});
			if (filterUser) params.set('user_id', filterUser);
			if (filterAction) params.set('action', filterAction);
			if (filterDateFrom) params.set('from', new Date(filterDateFrom).toISOString());
			if (filterDateTo) params.set('to', new Date(filterDateTo).toISOString());

			const res = await api.get(`/api/admin/activity?${params}`);
			if (res.ok) {
				const data = await res.json();
				const newLogs: ActivityLog[] = data.logs || data || [];
				if (reset) {
					logs = newLogs;
				} else {
					logs = [...logs, ...newLogs];
				}
				hasMore = newLogs.length === PAGE_SIZE;
				page++;
			} else {
				showToast('Failed to load activity', 'error');
			}
		} finally {
			loading = false;
			loadingMore = false;
		}
	}

	function applyFilters() {
		loadLogs(true);
	}

	function clearFilters() {
		filterUser = '';
		filterAction = '';
		filterDateFrom = '';
		filterDateTo = '';
		loadLogs(true);
	}

	function actionColor(action: string): string {
		if (action.includes('delete')) return 'bg-red-100 text-red-700';
		if (action.includes('create') || action.includes('upload')) return 'bg-green-100 text-green-700';
		if (action.includes('login') || action.includes('logout')) return 'bg-blue-100 text-blue-700';
		if (action.includes('share')) return 'bg-purple-100 text-purple-700';
		return 'bg-gray-100 text-gray-600';
	}
</script>

<svelte:head>
	<title>Activity — SyncVault Admin</title>
</svelte:head>

<div class="p-6">
	<div class="mb-6">
		<h1 class="text-xl font-semibold text-gray-900">Activity Log</h1>
		<p class="text-sm text-gray-500 mt-1">Audit trail of all user actions.</p>
	</div>

	<!-- Filters -->
	<div class="bg-white rounded-lg shadow-sm border border-gray-200 p-4 mb-5">
		<div class="flex flex-wrap gap-3 items-end">
			<div class="flex-1 min-w-32">
				<label class="block text-xs font-medium text-gray-600 mb-1">User</label>
				<select bind:value={filterUser} class="w-full text-sm border border-gray-300 rounded-md px-3 py-1.5 focus:border-blue-500 focus:outline-none">
					<option value="">All users</option>
					{#each allUsers as u}
						<option value={u.id}>{u.username}</option>
					{/each}
				</select>
			</div>
			<div class="flex-1 min-w-32">
				<label class="block text-xs font-medium text-gray-600 mb-1">Action</label>
				<select bind:value={filterAction} class="w-full text-sm border border-gray-300 rounded-md px-3 py-1.5 focus:border-blue-500 focus:outline-none">
					<option value="">All actions</option>
					{#each actionTypes as a}
						<option value={a}>{a.replace(/_/g, ' ')}</option>
					{/each}
				</select>
			</div>
			<div class="flex-1 min-w-36">
				<label class="block text-xs font-medium text-gray-600 mb-1">From</label>
				<input type="datetime-local" bind:value={filterDateFrom} class="w-full text-sm border border-gray-300 rounded-md px-3 py-1.5 focus:border-blue-500 focus:outline-none" />
			</div>
			<div class="flex-1 min-w-36">
				<label class="block text-xs font-medium text-gray-600 mb-1">To</label>
				<input type="datetime-local" bind:value={filterDateTo} class="w-full text-sm border border-gray-300 rounded-md px-3 py-1.5 focus:border-blue-500 focus:outline-none" />
			</div>
			<div class="flex gap-2 flex-shrink-0">
				<button
					onclick={applyFilters}
					class="flex items-center gap-1.5 bg-blue-500 hover:bg-blue-600 text-white text-sm font-medium rounded-md px-3 py-1.5 transition-colors"
				>
					<Filter size={14} /> Apply
				</button>
				<button
					onclick={clearFilters}
					class="text-sm text-gray-500 hover:text-gray-700 border border-gray-300 rounded-md px-3 py-1.5 hover:bg-gray-50 transition-colors"
				>
					Clear
				</button>
			</div>
		</div>
	</div>

	<!-- Log table -->
	<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
		{#if loading}
			<div class="flex items-center justify-center py-16">
				<div class="w-7 h-7 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
			</div>
		{:else if logs.length === 0}
			<div class="text-center py-16 text-gray-400">
				<Activity size={48} class="mx-auto mb-3 opacity-30" />
				<p class="text-base font-medium">No activity found</p>
				<p class="text-sm mt-1">Try adjusting your filters.</p>
			</div>
		{:else}
			<table class="min-w-full divide-y divide-gray-200">
				<thead class="bg-gray-50">
					<tr>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Date / Time</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">User</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Action</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden sm:table-cell">Resource</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden lg:table-cell">Details</th>
					</tr>
				</thead>
				<tbody class="bg-white divide-y divide-gray-200">
					{#each logs as log}
						<tr class="hover:bg-gray-50">
							<td class="px-4 py-3 whitespace-nowrap">
								<span class="text-xs text-gray-500 font-mono">{formatDateAbsolute(log.created_at)}</span>
							</td>
							<td class="px-4 py-3">
								<div class="flex items-center gap-2">
									<div class="w-6 h-6 rounded-full bg-blue-100 flex items-center justify-center text-blue-600 text-xs font-bold flex-shrink-0">
										{(log.username ?? '?')[0].toUpperCase()}
									</div>
									<span class="text-sm text-gray-800">{log.username ?? log.user_id ?? '—'}</span>
								</div>
							</td>
							<td class="px-4 py-3">
								<span class="text-xs font-medium rounded-full px-2.5 py-1 {actionColor(log.action)}">
									{log.action.replace(/_/g, ' ')}
								</span>
							</td>
							<td class="px-4 py-3 hidden sm:table-cell">
								{#if log.resource_name}
									<div>
										<p class="text-sm text-gray-700 truncate max-w-48">{log.resource_name}</p>
										{#if log.resource_type}
											<p class="text-xs text-gray-400">{log.resource_type}</p>
										{/if}
									</div>
								{:else}
									<span class="text-gray-400">—</span>
								{/if}
							</td>
							<td class="px-4 py-3 hidden lg:table-cell">
								<span class="text-xs text-gray-500 truncate max-w-48 block">{log.details ?? '—'}</span>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>

			{#if hasMore}
				<div class="px-4 py-4 border-t border-gray-200 text-center">
					<button
						onclick={() => loadLogs(false)}
						disabled={loadingMore}
						class="flex items-center gap-2 mx-auto text-sm text-blue-600 hover:text-blue-800 font-medium disabled:opacity-50"
					>
						{#if loadingMore}
							<div class="w-4 h-4 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
							Loading…
						{:else}
							<ChevronDown size={16} /> Load more
						{/if}
					</button>
				</div>
			{/if}
		{/if}
	</div>
</div>
