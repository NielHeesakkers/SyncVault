<script lang="ts">
	import { onMount } from 'svelte';
	import { Clock, FolderOpen, FileText, Download, RotateCcw } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes, formatDate } from '$lib/utils';
	import BreadcrumbNav from '$lib/components/BreadcrumbNav.svelte';

	interface HistoryFile {
		id: string;
		name: string;
		is_dir: boolean;
		size: number;
		version_num: number;
		version_id: string;
		content_hash: string;
		updated_at: string;
	}

	interface BreadcrumbItem {
		id: string | null;
		name: string;
	}

	// Default to "now" rounded to the minute
	function defaultAt(): string {
		const d = new Date();
		d.setSeconds(0, 0);
		// datetime-local input expects "YYYY-MM-DDTHH:MM"
		return d.toISOString().slice(0, 16);
	}

	let atValue = $state(defaultAt());
	let currentFolderId = $state<string | null>(null);
	let breadcrumbs = $state<BreadcrumbItem[]>([{ id: null, name: 'Files' }]);
	let files = $state<HistoryFile[]>([]);
	let changeDates = $state<string[]>([]);
	let loading = $state(false);
	let datesLoading = $state(false);

	onMount(() => {
		loadChangeDates(null);
		loadHistory(null, atValue);
	});

	async function loadChangeDates(folderId: string | null) {
		datesLoading = true;
		try {
			const path = folderId
				? `/api/files/history/dates?parent_id=${folderId}`
				: '/api/files/history/dates';
			const res = await api.get(path);
			if (res.ok) {
				const data = await res.json();
				changeDates = data.dates || [];
			}
		} catch {
			// non-fatal
		} finally {
			datesLoading = false;
		}
	}

	async function loadHistory(folderId: string | null, at: string) {
		loading = true;
		files = [];
		try {
			// Convert datetime-local value ("YYYY-MM-DDTHH:MM") to UTC ISO string
			const atISO = new Date(at).toISOString();
			const params = new URLSearchParams({ at: atISO });
			if (folderId) params.set('parent_id', folderId);
			const res = await api.get(`/api/files/history?${params}`);
			if (res.ok) {
				const data = await res.json();
				files = data.files || [];
			} else {
				showToast('Failed to load history', 'error');
			}
		} catch {
			showToast('Network error', 'error');
		} finally {
			loading = false;
		}
	}

	function navigateToFolder(file: HistoryFile) {
		breadcrumbs = [...breadcrumbs, { id: file.id, name: file.name }];
		currentFolderId = file.id;
		loadChangeDates(file.id);
		loadHistory(file.id, atValue);
	}

	function navigateToBreadcrumb(crumb: BreadcrumbItem) {
		const idx = breadcrumbs.findIndex((b) => b.id === crumb.id);
		if (idx >= 0) breadcrumbs = breadcrumbs.slice(0, idx + 1);
		currentFolderId = crumb.id;
		loadChangeDates(crumb.id);
		loadHistory(crumb.id, atValue);
	}

	function onAtChange() {
		loadHistory(currentFolderId, atValue);
	}

	function jumpToDate(dateStr: string) {
		// Set time to end-of-day for that date so we see all changes
		atValue = dateStr + 'T23:59';
		loadHistory(currentFolderId, atValue);
	}

	function downloadVersion(file: HistoryFile) {
		if (file.version_num > 0) {
			window.open(`/api/files/${file.id}/versions/${file.version_num}/download`, '_blank');
		} else {
			window.open(`/api/files/${file.id}/download`, '_blank');
		}
	}

	async function restoreVersion(file: HistoryFile) {
		if (file.version_num <= 0) {
			showToast('No version to restore', 'error');
			return;
		}
		const res = await api.post(`/api/files/${file.id}/versions/${file.version_num}/restore`, {});
		if (res.ok) {
			showToast(`Restored "${file.name}" to v${file.version_num}`, 'success');
		} else {
			showToast('Restore failed', 'error');
		}
	}
</script>

<svelte:head>
	<title>Version Explorer — SyncVault</title>
</svelte:head>

<div class="h-full flex flex-col">
	<!-- Top bar -->
	<div class="px-6 py-4 bg-white border-b border-gray-200">
		<div class="flex items-center justify-between gap-4 flex-wrap">
			<div class="flex items-center gap-3">
				<Clock size={22} class="text-blue-500 flex-shrink-0" />
				<h1 class="text-lg font-semibold text-gray-900">Version Explorer</h1>
			</div>
			<div class="flex items-center gap-3 flex-wrap">
				<label class="flex items-center gap-2 text-sm text-gray-600">
					<span class="font-medium">Browse at:</span>
					<input
						type="datetime-local"
						bind:value={atValue}
						onchange={onAtChange}
						class="rounded-md border border-gray-300 px-3 py-1.5 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
					/>
				</label>
				<button
					disabled
					title="Coming soon"
					class="flex items-center gap-2 border border-gray-200 text-gray-400 text-sm font-medium rounded-md px-4 py-2 cursor-not-allowed"
				>
					<RotateCcw size={16} /> Restore All
				</button>
			</div>
		</div>

		<!-- Change date timeline chips -->
		{#if changeDates.length > 0}
			<div class="mt-3 flex flex-wrap gap-2">
				<span class="text-xs text-gray-500 self-center">Jump to:</span>
				{#each changeDates as date}
					<button
						onclick={() => jumpToDate(date)}
						class="px-3 py-1 rounded-full text-xs font-medium border transition-colors
							{atValue.startsWith(date)
								? 'bg-blue-500 text-white border-blue-500'
								: 'bg-gray-50 text-gray-700 border-gray-200 hover:bg-blue-50 hover:border-blue-300'}"
					>
						{date}
					</button>
				{/each}
			</div>
		{/if}
	</div>

	<!-- Breadcrumb bar -->
	<div class="px-6 py-2 bg-gray-50 border-b border-gray-100">
		<BreadcrumbNav items={breadcrumbs} onclick={navigateToBreadcrumb} />
	</div>

	<!-- File list -->
	<div class="flex-1 overflow-auto p-6">
		{#if loading}
			<div class="flex items-center justify-center py-24">
				<div class="w-8 h-8 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
			</div>
		{:else if files.length === 0}
			<div class="text-center py-24 text-gray-400">
				<Clock size={56} class="mx-auto mb-4 opacity-30" />
				<p class="text-base font-medium">No files found at this point in time</p>
				<p class="text-sm mt-1">Try selecting a different date or navigate to a subfolder.</p>
			</div>
		{:else}
			<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
				<table class="min-w-full divide-y divide-gray-200">
					<thead class="bg-gray-50">
						<tr>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider w-8"></th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Name</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden sm:table-cell">Size</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Version</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Date</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Actions</th>
						</tr>
					</thead>
					<tbody class="bg-white divide-y divide-gray-200">
						{#each files as file}
							<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
							<tr
								class="hover:bg-gray-50 transition-colors {file.is_dir ? 'cursor-pointer' : ''}"
								onclick={() => { if (file.is_dir) navigateToFolder(file); }}
							>
								<td class="px-4 py-3">
									{#if file.is_dir}
										<FolderOpen size={20} class="text-yellow-500" />
									{:else}
										<FileText size={20} class="text-gray-400" />
									{/if}
								</td>
								<td class="px-4 py-3">
									<span class="text-sm font-medium text-gray-900">{file.name}</span>
								</td>
								<td class="px-4 py-3 hidden sm:table-cell">
									<span class="text-sm text-gray-500">
										{file.is_dir ? '—' : formatBytes(file.size)}
									</span>
								</td>
								<td class="px-4 py-3 hidden md:table-cell">
									{#if !file.is_dir}
										<span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-700">
											v{file.version_num}
										</span>
									{:else}
										<span class="text-gray-400 text-sm">—</span>
									{/if}
								</td>
								<td class="px-4 py-3 hidden md:table-cell">
									<span class="text-sm text-gray-500">{formatDate(file.updated_at)}</span>
								</td>
								<td class="px-4 py-3">
									{#if !file.is_dir}
										<div class="flex items-center gap-2">
											<button
												onclick={(e) => { e.stopPropagation(); downloadVersion(file); }}
												title="Download this version"
												class="flex items-center gap-1 text-xs text-blue-600 hover:text-blue-800 font-medium px-2 py-1 rounded hover:bg-blue-50 transition-colors"
											>
												<Download size={13} /> Download
											</button>
											<button
												onclick={(e) => { e.stopPropagation(); restoreVersion(file); }}
												title="Restore to current"
												class="flex items-center gap-1 text-xs text-gray-600 hover:text-gray-800 font-medium px-2 py-1 rounded hover:bg-gray-100 transition-colors"
											>
												<RotateCcw size={13} /> Restore
											</button>
										</div>
									{/if}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</div>
</div>
