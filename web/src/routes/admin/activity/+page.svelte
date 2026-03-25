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
		'login', 'logout', 'upload', 'download', 'delete', 'restore',
		'create_folder', 'rename', 'move', 'share_create', 'share_delete',
		'user_create', 'user_update', 'user_delete'
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
			const params = new URLSearchParams({ page: String(page), limit: String(PAGE_SIZE) });
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

	function applyFilters() { loadLogs(true); }
	function clearFilters() {
		filterUser = '';
		filterAction = '';
		filterDateFrom = '';
		filterDateTo = '';
		loadLogs(true);
	}

	function actionBadgeStyle(action: string): string {
		if (action.includes('delete')) return 'background: rgba(239,68,68,0.12); color: #f87171; border: 1px solid rgba(239,68,68,0.20);';
		if (action.includes('create') || action.includes('upload')) return 'background: rgba(34,197,94,0.12); color: #4ade80; border: 1px solid rgba(34,197,94,0.20);';
		if (action.includes('login') || action.includes('logout')) return 'background: rgba(59,130,246,0.12); color: #60a5fa; border: 1px solid rgba(59,130,246,0.20);';
		if (action.includes('share')) return 'background: rgba(168,85,247,0.12); color: #c084fc; border: 1px solid rgba(168,85,247,0.20);';
		return 'background: rgba(255,255,255,0.06); color: rgba(255,255,255,0.50); border: 1px solid rgba(255,255,255,0.08);';
	}
</script>

<svelte:head>
	<title>Activity — SyncVault Admin</title>
</svelte:head>

<div class="p-6" style="background: #0a0a0b; min-height: 100%;">
	<div class="mb-6">
		<h1 class="text-base font-semibold text-white">Activity Log</h1>
		<p class="text-sm mt-1" style="color: rgba(255,255,255,0.35);">Audit trail of all user actions.</p>
	</div>

	<!-- Filters -->
	<div class="rounded-xl border p-4 mb-5" style="background: #111113; border-color: rgba(255,255,255,0.05);">
		<div class="flex flex-wrap gap-3 items-end">
			<div class="flex-1 min-w-32">
				<label class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.40);">User</label>
				<select bind:value={filterUser}>
					<option value="">All users</option>
					{#each allUsers as u}
						<option value={u.id}>{u.username}</option>
					{/each}
				</select>
			</div>
			<div class="flex-1 min-w-32">
				<label class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.40);">Action</label>
				<select bind:value={filterAction}>
					<option value="">All actions</option>
					{#each actionTypes as a}
						<option value={a}>{a.replace(/_/g, ' ')}</option>
					{/each}
				</select>
			</div>
			<div class="flex-1 min-w-36">
				<label class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.40);">From</label>
				<input type="datetime-local" bind:value={filterDateFrom} />
			</div>
			<div class="flex-1 min-w-36">
				<label class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.40);">To</label>
				<input type="datetime-local" bind:value={filterDateTo} />
			</div>
			<div class="flex gap-2 flex-shrink-0">
				<button onclick={applyFilters} class="flex items-center gap-1.5 bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium rounded-lg px-3 py-2 transition-all duration-150">
					<Filter size={13} /> Apply
				</button>
				<button onclick={clearFilters} class="text-sm text-white/50 hover:text-white/80 border rounded-lg px-3 py-2 hover:bg-white/5 transition-all duration-150" style="border-color: rgba(255,255,255,0.10);">
					Clear
				</button>
			</div>
		</div>
	</div>

	<!-- Log table -->
	<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
		{#if loading}
			<div class="px-4 py-3 border-b" style="border-color: rgba(255,255,255,0.05);">
				<div class="flex gap-8">
					{#each [1,2,3,4] as _}
						<div class="skeleton h-3 rounded w-20"></div>
					{/each}
				</div>
			</div>
			{#each [1,2,3,4,5,6] as _}
				<div class="px-4 py-3.5 border-b flex items-center gap-4" style="border-color: rgba(255,255,255,0.04);">
					<div class="skeleton h-3 rounded w-28"></div>
					<div class="skeleton h-3 rounded w-20"></div>
					<div class="skeleton h-5 rounded-full w-16"></div>
					<div class="skeleton h-3 rounded w-32 ml-auto"></div>
				</div>
			{/each}
		{:else if logs.length === 0}
			<div class="flex flex-col items-center justify-center py-20">
				<div class="w-14 h-14 rounded-2xl flex items-center justify-center mb-4" style="background: rgba(255,255,255,0.04);">
					<Activity size={24} style="color: rgba(255,255,255,0.20);" />
				</div>
				<p class="text-base font-medium" style="color: rgba(255,255,255,0.40);">No activity yet</p>
				<p class="text-sm mt-1.5" style="color: rgba(255,255,255,0.25);">Try adjusting your filters.</p>
			</div>
		{:else}
			<table class="min-w-full">
				<thead>
					<tr style="border-bottom: 1px solid rgba(255,255,255,0.05);">
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Date / Time</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">User</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Action</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: rgba(255,255,255,0.30);">Resource</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden lg:table-cell" style="color: rgba(255,255,255,0.30);">Details</th>
					</tr>
				</thead>
				<tbody>
					{#each logs as log}
						<tr class="activity-row">
							<td class="px-4 py-3.5 whitespace-nowrap">
								<span class="text-xs font-mono" style="color: rgba(255,255,255,0.35);">{formatDateAbsolute(log.created_at)}</span>
							</td>
							<td class="px-4 py-3.5">
								<div class="flex items-center gap-2">
									<div class="w-6 h-6 rounded-full bg-blue-600/20 flex items-center justify-center text-blue-400 text-[10px] font-bold flex-shrink-0">
										{(log.username ?? '?')[0].toUpperCase()}
									</div>
									<span class="text-sm text-white/70">{log.username ?? log.user_id ?? '—'}</span>
								</div>
							</td>
							<td class="px-4 py-3.5">
								<span class="text-[11px] font-medium rounded-full px-2.5 py-1" style={actionBadgeStyle(log.action)}>
									{log.action.replace(/_/g, ' ')}
								</span>
							</td>
							<td class="px-4 py-3.5 hidden sm:table-cell">
								{#if log.resource_name}
									<div>
										<p class="text-sm text-white/60 truncate max-w-48">{log.resource_name}</p>
										{#if log.resource_type}
											<p class="text-xs mt-0.5" style="color: rgba(255,255,255,0.30);">{log.resource_type}</p>
										{/if}
									</div>
								{:else}
									<span style="color: rgba(255,255,255,0.20);">—</span>
								{/if}
							</td>
							<td class="px-4 py-3.5 hidden lg:table-cell">
								<span class="text-xs truncate max-w-48 block" style="color: rgba(255,255,255,0.35);">{log.details ?? '—'}</span>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>

			{#if hasMore}
				<div class="px-4 py-4 border-t text-center" style="border-color: rgba(255,255,255,0.05);">
					<button
						onclick={() => loadLogs(false)}
						disabled={loadingMore}
						class="flex items-center gap-2 mx-auto text-sm text-blue-400 hover:text-blue-300 font-medium disabled:opacity-50 transition-colors"
					>
						{#if loadingMore}
							<div class="w-4 h-4 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
							Loading…
						{:else}
							<ChevronDown size={15} /> Load more
						{/if}
					</button>
				</div>
			{/if}
		{/if}
	</div>
</div>

<style>
	.activity-row {
		border-bottom: 1px solid rgba(255,255,255,0.04);
	}
	.activity-row:hover {
		background: rgba(255,255,255,0.02);
	}
	.activity-row:last-child {
		border-bottom: none;
	}
</style>
