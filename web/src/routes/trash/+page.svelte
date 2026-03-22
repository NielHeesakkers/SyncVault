<script lang="ts">
	import { onMount } from 'svelte';
	import { Trash2, RotateCcw, FileText, FolderOpen, AlertTriangle } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes, formatDate } from '$lib/utils';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';

	interface TrashedItem {
		id: string;
		name: string;
		size: number;
		is_dir?: boolean;
		type?: 'file' | 'folder';
		deleted_at?: string;
		original_path?: string;
	}

	function isDir(item: TrashedItem): boolean {
		return item.is_dir === true || item.type === 'folder';
	}

	let items = $state<TrashedItem[]>([]);
	let loading = $state(true);
	let selected = $state<Set<string>>(new Set());
	let lastClickedIndex = $state<number>(-1);

	let deleteTarget = $state<TrashedItem | null>(null);
	let showPermanentDelete = $state(false);
	let showEmptyTrash = $state(false);
	let showRemoveSelected = $state(false);

	function toggleSelect(item: TrashedItem, index: number, event: MouseEvent) {
		const newSet = new Set(selected);
		if (event.shiftKey && lastClickedIndex >= 0) {
			const start = Math.min(lastClickedIndex, index);
			const end = Math.max(lastClickedIndex, index);
			for (let i = start; i <= end; i++) {
				newSet.add(items[i].id);
			}
		} else {
			if (newSet.has(item.id)) {
				newSet.delete(item.id);
			} else {
				newSet.add(item.id);
			}
		}
		selected = newSet;
		lastClickedIndex = index;
	}

	function selectAll() {
		if (selected.size === items.length) {
			selected = new Set();
		} else {
			selected = new Set(items.map(i => i.id));
		}
	}

	async function removeSelected() {
		for (const id of selected) {
			await api.delete(`/api/files/${id}/permanent`);
		}
		items = items.filter(i => !selected.has(i.id));
		showToast(`${selected.size} items permanently deleted`, 'success');
		selected = new Set();
		showRemoveSelected = false;
	}

	onMount(loadTrash);

	async function loadTrash() {
		loading = true;
		try {
			const res = await api.get('/api/trash');
			if (res.ok) {
				const data = await res.json();
				items = data.files || data.items || data || [];
			} else {
				showToast('Failed to load trash', 'error');
			}
		} finally {
			loading = false;
		}
	}

	async function restoreItem(item: TrashedItem) {
		const res = await api.post(`/api/files/${item.id}/restore`, {});
		if (res.ok) {
			showToast(`'${item.name}' restored`, 'success');
			items = items.filter((i) => i.id !== item.id);
		} else {
			showToast('Restore failed', 'error');
		}
	}

	function confirmPermanentDelete(item: TrashedItem) {
		deleteTarget = item;
		showPermanentDelete = true;
	}

	async function doPermanentDelete() {
		if (!deleteTarget) return;
		const res = await api.delete(`/api/files/${deleteTarget.id}/permanent`);
		if (res.ok) {
			showToast('Permanently deleted', 'success');
			items = items.filter((i) => i.id !== deleteTarget!.id);
			showPermanentDelete = false;
			deleteTarget = null;
		} else {
			showToast('Delete failed', 'error');
		}
	}

	async function emptyTrash() {
		const res = await api.delete('/api/trash');
		if (res.ok) {
			showToast('Trash emptied', 'success');
			items = [];
			showEmptyTrash = false;
		} else {
			showToast('Failed to empty trash', 'error');
		}
	}
</script>

<svelte:head>
	<title>Trash — SyncVault</title>
</svelte:head>

<div class="p-6">
	<div class="mb-6 flex items-center justify-between">
		<div>
			<h1 class="text-xl font-semibold text-gray-900">Trash</h1>
			<p class="text-sm text-gray-500 mt-1">Files here will be permanently deleted after 30 days.</p>
		</div>
		{#if items.length > 0}
			{#if selected.size > 0}
				<button
					onclick={() => (showRemoveSelected = true)}
					class="flex items-center gap-2 bg-red-500 hover:bg-red-600 text-white text-sm font-medium rounded-md px-4 py-2 transition-colors"
				>
					<Trash2 size={16} /> Remove ({selected.size})
				</button>
			{:else}
				<button
					onclick={() => (showEmptyTrash = true)}
					class="flex items-center gap-2 bg-red-500 hover:bg-red-600 text-white text-sm font-medium rounded-md px-4 py-2 transition-colors"
				>
					<Trash2 size={16} /> Empty Trash
				</button>
			{/if}
		{/if}
	</div>

	<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
		{#if loading}
			<div class="flex items-center justify-center py-16">
				<div class="w-7 h-7 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
			</div>
		{:else if items.length === 0}
			<div class="text-center py-16 text-gray-400">
				<Trash2 size={48} class="mx-auto mb-3 opacity-30" />
				<p class="text-base font-medium">Trash is empty</p>
				<p class="text-sm mt-1">Deleted files will appear here.</p>
			</div>
		{:else}
			<table class="min-w-full divide-y divide-gray-200">
				<thead class="bg-gray-50">
					<tr>
						<th class="px-4 py-3 w-8">
							<input type="checkbox" checked={selected.size === items.length && items.length > 0} onchange={selectAll}
								class="rounded border-gray-300 text-blue-500 focus:ring-blue-500" />
						</th>
						<th class="px-4 py-3 w-8"></th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Name</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden sm:table-cell">Size</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Deleted</th>
						<th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Actions</th>
					</tr>
				</thead>
				<tbody class="bg-white divide-y divide-gray-200">
					{#each items as item, i}
						<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
						<tr class="hover:bg-gray-50 cursor-pointer {selected.has(item.id) ? 'bg-blue-50' : ''}"
							onclick={(e) => toggleSelect(item, i, e)}>
							<td class="px-4 py-3">
								<input type="checkbox" checked={selected.has(item.id)} onclick={(e) => e.stopPropagation()} onchange={(e) => toggleSelect(item, i, e)}
									class="rounded border-gray-300 text-blue-500 focus:ring-blue-500" />
							</td>
							<td class="px-4 py-3">
								{#if isDir(item)}
									<FolderOpen size={20} class="text-yellow-400 opacity-60" />
								{:else}
									<FileText size={20} class="text-gray-300" />
								{/if}
							</td>
							<td class="px-4 py-3">
								<div>
									<p class="text-sm font-medium text-gray-600">{item.name}</p>
									{#if item.original_path}
										<p class="text-xs text-gray-400 mt-0.5">{item.original_path}</p>
									{/if}
								</div>
							</td>
							<td class="px-4 py-3 hidden sm:table-cell">
								<span class="text-sm text-gray-500">
									{isDir(item) ? '—' : formatBytes(item.size)}
								</span>
							</td>
							<td class="px-4 py-3 hidden md:table-cell">
								<span class="text-sm text-gray-500">{formatDate(item.deleted_at)}</span>
							</td>
							<td class="px-4 py-3">
								<div class="flex items-center justify-end gap-2">
									<button
										onclick={() => restoreItem(item)}
										class="flex items-center gap-1.5 text-sm text-blue-600 hover:text-blue-800 font-medium transition-colors"
									>
										<RotateCcw size={14} /> Restore
									</button>
									<button
										onclick={() => confirmPermanentDelete(item)}
										class="flex items-center gap-1.5 text-sm text-red-500 hover:text-red-700 font-medium transition-colors"
									>
										<Trash2 size={14} /> Delete
									</button>
								</div>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		{/if}
	</div>
</div>

{#if showPermanentDelete && deleteTarget}
	<ConfirmDialog
		title="Permanently Delete"
		message="'{deleteTarget.name}' will be permanently deleted and cannot be recovered. Continue?"
		confirmLabel="Delete Forever"
		onconfirm={doPermanentDelete}
		oncancel={() => { showPermanentDelete = false; deleteTarget = null; }}
	/>
{/if}

{#if showRemoveSelected}
	<ConfirmDialog
		title="Remove Selected"
		message="Permanently delete {selected.size} selected item(s)? This cannot be undone."
		confirmLabel="Remove"
		onconfirm={removeSelected}
		oncancel={() => (showRemoveSelected = false)}
	/>
{/if}

{#if showEmptyTrash}
	<ConfirmDialog
		title="Empty Trash"
		message="All {items.length} item(s) in the trash will be permanently deleted. This cannot be undone."
		confirmLabel="Empty Trash"
		onconfirm={emptyTrash}
		oncancel={() => (showEmptyTrash = false)}
	/>
{/if}
