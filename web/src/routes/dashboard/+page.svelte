<script lang="ts">
	import { onMount } from 'svelte';
	import { FolderOpen, Users, Settings, Activity, HardDrive, CheckCircle2, AlertCircle, Clock, ArrowRight, RefreshCw } from 'lucide-svelte';
	import { goto } from '$app/navigation';
	import { api } from '$lib/api';
	import { currentUser } from '$lib/stores';
	import { formatBytes } from '$lib/utils';

	let user = $derived($currentUser);
	let loading = $state(true);

	// Storage data
	let storageUsed = $state(0);
	let storageQuota = $state(0);

	// Activity
	let activity = $state<any[]>([]);
	let activityLoading = $state(true);

	// Sync tasks
	let tasks = $state<any[]>([]);
	let tasksLoading = $state(true);

	// Server status
	let serverOnline = $state(false);
	let serverVersion = $state('');

	onMount(async () => {
		// Server health
		try {
			const res = await fetch('/api/health');
			if (res.ok) {
				const data = await res.json();
				serverOnline = true;
				serverVersion = data.version || '';
			}
		} catch {}

		// Storage
		try {
			const res = await api.get('/api/me/storage');
			if (res.ok) {
				const data = await res.json();
				storageUsed = data.used || 0;
				storageQuota = data.quota || 0;
			}
		} catch {}
		loading = false;

		// Activity
		try {
			const res = await api.get('/api/activity?limit=10');
			if (res.ok) {
				const data = await res.json();
				activity = data.events || data.activity || data || [];
				if (!Array.isArray(activity)) activity = [];
			}
		} catch {}
		// Fallback: if no activity, show recent file changes
		if (activity.length === 0) {
			try {
				const since = new Date(Date.now() - 30 * 86400000).toISOString();
				const res = await api.get(`/api/changes?since=${since}`);
				if (res.ok) {
					const data = await res.json();
					const changes = data.changes || [];
					activity = changes.slice(0, 10).map((c: any) => ({
						action: c.deleted_at ? 'delete' : 'upload',
						details: c.name,
						resource: c.is_dir ? 'folder' : 'file',
						created_at: c.updated_at
					}));
				}
			} catch {}
		}
		activityLoading = false;

		// Tasks
		try {
			const res = await api.get('/api/tasks');
			if (res.ok) {
				const data = await res.json();
				tasks = Array.isArray(data) ? data : (data.tasks || []);
			}
		} catch {}
		tasksLoading = false;
	});

	function storagePercent(): number {
		if (!storageQuota || storageQuota === 0) return 0;
		return Math.min(100, Math.round((storageUsed / storageQuota) * 100));
	}

	// SVG circle progress
	const circleR = 40;
	const circleC = 2 * Math.PI * circleR;
	function circleDash(): string {
		const pct = storagePercent() / 100;
		return `${(circleC * pct).toFixed(1)} ${circleC.toFixed(1)}`;
	}

	function storageColor(): string {
		const pct = storagePercent();
		if (pct >= 90) return '#ef4444';
		if (pct >= 70) return '#f59e0b';
		return '#3b82f6';
	}

	function formatActivityTime(ts: string | undefined): string {
		if (!ts) return '';
		const d = new Date(ts);
		const now = new Date();
		const diff = now.getTime() - d.getTime();
		const minutes = Math.floor(diff / 60000);
		const hours = Math.floor(diff / 3600000);
		const days = Math.floor(diff / 86400000);
		if (minutes < 1) return 'just now';
		if (minutes < 60) return `${minutes}m ago`;
		if (hours < 24) return `${hours}h ago`;
		return `${days}d ago`;
	}

	function getActivityIcon(event: any): string {
		const action = (event.action || event.event || '').toLowerCase();
		if (action.includes('upload') || action.includes('create')) return 'upload';
		if (action.includes('delete') || action.includes('trash')) return 'delete';
		if (action.includes('restore')) return 'restore';
		if (action.includes('download')) return 'download';
		if (action.includes('share')) return 'share';
		return 'other';
	}

	function getActivityColor(type: string): string {
		if (type === 'upload') return '#22c55e';
		if (type === 'delete') return '#ef4444';
		if (type === 'restore') return '#3b82f6';
		if (type === 'download') return '#a855f7';
		if (type === 'share') return '#f59e0b';
		return 'var(--text-tertiary)';
	}

	function getActivityLabel(event: any): string {
		if (event.message) return event.message;
		if (event.description) return event.description;
		if (event.details) return event.details;
		const action = (event.action || event.event || 'Activity').replace(/_/g, ' ');
		const target = event.file_name || event.resource || event.target || '';
		return target ? `${action}: ${target}` : action;
	}

	function getTaskStatusColor(status: string): string {
		if (status === 'syncing' || status === 'running') return '#3b82f6';
		if (status === 'idle' || status === 'ready') return '#22c55e';
		if (status === 'error' || status === 'failed') return '#ef4444';
		return 'var(--text-tertiary)';
	}

	function getTaskStatusLabel(status: string): string {
		if (status === 'syncing' || status === 'running') return 'Syncing';
		if (status === 'idle') return 'Idle';
		if (status === 'ready') return 'Ready';
		if (status === 'error' || status === 'failed') return 'Error';
		return status || 'Unknown';
	}
</script>

<svelte:head>
	<title>Dashboard — SyncVault</title>
</svelte:head>

<div class="p-6 max-w-6xl mx-auto">
	<!-- Header -->
	<div class="mb-8">
		<h1 class="text-xl font-semibold text-white">
			Welcome back{user?.username ? `, ${user.username}` : ''}
		</h1>
		<div class="flex items-center gap-2 mt-1.5">
			<span class="w-1.5 h-1.5 rounded-full {serverOnline ? 'bg-green-500' : 'bg-red-500'}"></span>
			<span class="text-sm" style="color: var(--text-tertiary);">
				{serverOnline ? `Server online${serverVersion ? ' · v' + serverVersion : ''}` : 'Server offline'}
			</span>
		</div>
	</div>

	<!-- Top row: Storage + Quick Actions -->
	<div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
		<!-- Storage Card -->
		<div class="rounded-xl border p-5" style="background: var(--bg-elevated); border-color: var(--border);">
			<div class="flex items-center justify-between mb-4">
				<span class="text-xs font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Storage</span>
				<HardDrive size={14} style="color: var(--text-tertiary);" />
			</div>
			{#if loading}
				<div class="flex justify-center py-4">
					<div class="skeleton w-24 h-24 rounded-full"></div>
				</div>
			{:else}
				<div class="flex flex-col items-center">
					<div class="relative w-24 h-24">
						<svg viewBox="0 0 100 100" class="w-full h-full -rotate-90">
							<!-- Background circle -->
							<circle cx="50" cy="50" r={circleR} fill="none" stroke="var(--border-strong)" stroke-width="10" />
							<!-- Progress circle -->
							<circle
								cx="50" cy="50" r={circleR}
								fill="none"
								stroke={storageColor()}
								stroke-width="10"
								stroke-linecap="round"
								stroke-dasharray={circleDash()}
							/>
						</svg>
						<div class="absolute inset-0 flex flex-col items-center justify-center">
							<span class="text-lg font-bold text-white">{storagePercent()}%</span>
						</div>
					</div>
					<div class="mt-3 text-center">
						<p class="text-sm font-medium text-white/80">{formatBytes(storageUsed)}</p>
						{#if storageQuota > 0}
							<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">of {formatBytes(storageQuota)}</p>
						{:else}
							<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">no quota set</p>
						{/if}
					</div>
				</div>
			{/if}
		</div>

		<!-- Quick Actions -->
		<div class="md:col-span-2 rounded-xl border p-5" style="background: var(--bg-elevated); border-color: var(--border);">
			<div class="mb-4">
				<span class="text-xs font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Quick Actions</span>
			</div>
			<div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
				<button
					onclick={() => goto('/files')}
					class="flex items-center gap-3 px-4 py-3.5 rounded-xl border transition-all duration-150 hover:border-white/10 hover:bg-white/[0.04] text-left group"
					style="border-color: var(--border-strong);"
				>
					<div class="w-8 h-8 rounded-lg bg-blue-500/15 flex items-center justify-center flex-shrink-0">
						<FolderOpen size={16} class="text-blue-400" />
					</div>
					<div>
						<p class="text-sm font-medium text-white/80 group-hover:text-white transition-colors">Open Files</p>
						<p class="text-xs" style="color: var(--text-tertiary);">Browse your files</p>
					</div>
				</button>

				{#if user?.role === 'admin'}
					<button
						onclick={() => goto('/admin/users')}
						class="flex items-center gap-3 px-4 py-3.5 rounded-xl border transition-all duration-150 hover:border-white/10 hover:bg-white/[0.04] text-left group"
						style="border-color: var(--border-strong);"
					>
						<div class="w-8 h-8 rounded-lg bg-purple-500/15 flex items-center justify-center flex-shrink-0">
							<Users size={16} class="text-purple-400" />
						</div>
						<div>
							<p class="text-sm font-medium text-white/80 group-hover:text-white transition-colors">Manage Users</p>
							<p class="text-xs" style="color: var(--text-tertiary);">Add and manage users</p>
						</div>
					</button>

					<button
						onclick={() => goto('/admin/settings')}
						class="flex items-center gap-3 px-4 py-3.5 rounded-xl border transition-all duration-150 hover:border-white/10 hover:bg-white/[0.04] text-left group"
						style="border-color: var(--border-strong);"
					>
						<div class="w-8 h-8 rounded-lg bg-green-500/15 flex items-center justify-center flex-shrink-0">
							<Settings size={16} class="text-green-400" />
						</div>
						<div>
							<p class="text-sm font-medium text-white/80 group-hover:text-white transition-colors">Settings</p>
							<p class="text-xs" style="color: var(--text-tertiary);">Configure server</p>
						</div>
					</button>
				{:else}
					<button
						onclick={() => goto('/shared')}
						class="flex items-center gap-3 px-4 py-3.5 rounded-xl border transition-all duration-150 hover:border-white/10 hover:bg-white/[0.04] text-left group"
						style="border-color: var(--border-strong);"
					>
						<div class="w-8 h-8 rounded-lg bg-yellow-500/15 flex items-center justify-center flex-shrink-0">
							<Activity size={16} class="text-yellow-400" />
						</div>
						<div>
							<p class="text-sm font-medium text-white/80 group-hover:text-white transition-colors">Shared Links</p>
							<p class="text-xs" style="color: var(--text-tertiary);">Manage shared files</p>
						</div>
					</button>

					<button
						onclick={() => goto('/trash')}
						class="flex items-center gap-3 px-4 py-3.5 rounded-xl border transition-all duration-150 hover:border-white/10 hover:bg-white/[0.04] text-left group"
						style="border-color: var(--border-strong);"
					>
						<div class="w-8 h-8 rounded-lg bg-red-500/15 flex items-center justify-center flex-shrink-0">
							<HardDrive size={16} class="text-red-400" />
						</div>
						<div>
							<p class="text-sm font-medium text-white/80 group-hover:text-white transition-colors">Trash</p>
							<p class="text-xs" style="color: var(--text-tertiary);">Deleted files</p>
						</div>
					</button>
				{/if}
			</div>
		</div>
	</div>

	<!-- Bottom row: Activity + Sync Tasks -->
	<div class="grid grid-cols-1 md:grid-cols-2 gap-4">
		<!-- Recent Activity -->
		<div class="rounded-xl border" style="background: var(--bg-elevated); border-color: var(--border);">
			<div class="flex items-center justify-between px-5 py-4 border-b" style="border-color: var(--border);">
				<span class="text-xs font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Recent Activity</span>
				<Activity size={14} style="color: var(--text-tertiary);" />
			</div>
			<div class="p-4">
				{#if activityLoading}
					<div class="space-y-3">
						{#each [1,2,3,4,5] as _}
							<div class="flex items-center gap-3">
								<div class="skeleton w-6 h-6 rounded-full flex-shrink-0"></div>
								<div class="flex-1 space-y-1.5">
									<div class="skeleton h-3 rounded w-4/5"></div>
									<div class="skeleton h-2.5 rounded w-1/3"></div>
								</div>
							</div>
						{/each}
					</div>
				{:else if activity.length === 0}
					<div class="flex flex-col items-center justify-center py-10">
						<div class="w-10 h-10 rounded-full flex items-center justify-center mb-3" style="background: var(--bg-active);">
							<Activity size={18} style="color: var(--text-tertiary);" />
						</div>
						<p class="text-sm font-medium" style="color: var(--text-tertiary);">No activity yet</p>
						<p class="text-xs mt-1" style="color: var(--text-tertiary);">Activity will appear here as files sync</p>
					</div>
				{:else}
					<div class="space-y-0">
						{#each activity.slice(0, 10) as event, i}
							{@const atype = getActivityIcon(event)}
							{@const acolor = getActivityColor(atype)}
							<div class="flex items-start gap-3 py-2.5 {i < activity.length - 1 ? 'border-b' : ''}" style="border-color: var(--border);">
								<div class="w-1.5 h-1.5 rounded-full mt-1.5 flex-shrink-0" style="background: {acolor};"></div>
								<div class="flex-1 min-w-0">
									<p class="text-xs text-white/70 truncate">{getActivityLabel(event)}</p>
									<p class="text-[10px] mt-0.5" style="color: var(--text-tertiary);">{formatActivityTime(event.created_at || event.timestamp)}</p>
								</div>
							</div>
						{/each}
					</div>
				{/if}
			</div>
		</div>

		<!-- Sync Tasks -->
		<div class="rounded-xl border" style="background: var(--bg-elevated); border-color: var(--border);">
			<div class="flex items-center justify-between px-5 py-4 border-b" style="border-color: var(--border);">
				<span class="text-xs font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Sync Tasks</span>
				<RefreshCw size={14} style="color: var(--text-tertiary);" />
			</div>
			<div class="p-4">
				{#if tasksLoading}
					<div class="space-y-3">
						{#each [1,2,3] as _}
							<div class="rounded-lg p-3 border" style="background: var(--bg-hover); border-color: var(--border);">
								<div class="skeleton h-3 rounded w-2/5 mb-2"></div>
								<div class="skeleton h-2.5 rounded w-1/4"></div>
							</div>
						{/each}
					</div>
				{:else if tasks.length === 0}
					<div class="flex flex-col items-center justify-center py-10">
						<div class="w-10 h-10 rounded-full flex items-center justify-center mb-3" style="background: var(--bg-active);">
							<RefreshCw size={18} style="color: var(--text-tertiary);" />
						</div>
						<p class="text-sm font-medium" style="color: var(--text-tertiary);">No sync tasks</p>
						<p class="text-xs mt-1" style="color: var(--text-tertiary);">Configure sync in the macOS app</p>
					</div>
				{:else}
					<div class="space-y-2">
						{#each tasks as task}
							{@const statusColor = getTaskStatusColor(task.status || task.state || '')}
							{@const statusLabel = getTaskStatusLabel(task.status || task.state || '')}
							<div class="rounded-lg p-3 border" style="background: var(--bg-hover); border-color: var(--border);">
								<div class="flex items-center justify-between mb-1">
									<p class="text-sm font-medium text-white/80 truncate max-w-[180px]">{task.name || task.folder_name || 'Sync task'}</p>
									<div class="flex items-center gap-1.5 flex-shrink-0">
										<span class="w-1.5 h-1.5 rounded-full" style="background: {statusColor};"></span>
										<span class="text-xs" style="color: {statusColor};">{statusLabel}</span>
									</div>
								</div>
								{#if task.last_sync || task.last_run}
									<p class="text-[10px]" style="color: var(--text-tertiary);">
										Last sync: {formatActivityTime(task.last_sync || task.last_run)}
									</p>
								{/if}
								{#if task.error_message}
									<p class="text-[10px] text-red-400 mt-0.5 truncate">{task.error_message}</p>
								{/if}
							</div>
						{/each}
					</div>
				{/if}
			</div>
		</div>
	</div>
</div>
