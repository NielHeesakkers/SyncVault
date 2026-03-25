<script lang="ts">
	import { onMount } from 'svelte';
	import { Trash2, RotateCcw, FileText, FolderOpen, Sparkles } from 'lucide-svelte';
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

<div class="p-6" style="background: var(--bg-base); min-height: 100%;">
	<div class="mb-6 flex items-center justify-between">
		<div>
			<h1 class="text-base font-semibold text-white">Trash</h1>
			<p class="text-sm mt-1" style="color: var(--text-tertiary);">Files here will be permanently deleted after 30 days.</p>
		</div>
		{#if items.length > 0}
			{#if selected.size > 0}
				<button
					onclick={() => (showRemoveSelected = true)}
					class="flex items-center gap-2 text-sm font-medium rounded-lg px-4 py-2 transition-all duration-150 bg-red-600/10 text-red-400 hover:bg-red-600/20 border border-red-500/20"
				>
					<Trash2 size={15} /> Remove ({selected.size})
				</button>
			{:else}
				<button
					onclick={() => (showEmptyTrash = true)}
					class="flex items-center gap-2 text-sm font-medium rounded-lg px-4 py-2 transition-all duration-150 bg-red-600/10 text-red-400 hover:bg-red-600/20 border border-red-500/20"
				>
					<Trash2 size={15} /> Empty Trash
				</button>
			{/if}
		{/if}
	</div>

	<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
		{#if loading}
			<!-- Skeleton -->
			<div class="px-4 py-3 border-b" style="border-color: var(--border);">
				<div class="flex gap-4">
					<div class="skeleton h-3 rounded w-3"></div>
					<div class="skeleton h-3 rounded w-3"></div>
					<div class="skeleton h-3 rounded w-32"></div>
				</div>
			</div>
			{#each [1,2,3,4] as _}
				<div class="px-4 py-3.5 border-b flex items-center gap-3" style="border-color: var(--border);">
					<div class="skeleton w-4 h-4 rounded"></div>
					<div class="skeleton w-5 h-5 rounded"></div>
					<div class="skeleton h-3 rounded w-48"></div>
					<div class="skeleton h-3 rounded w-16 ml-auto"></div>
				</div>
			{/each}
		{:else if items.length === 0}
			<div class="flex flex-col items-center justify-center py-20">
				<div class="w-14 h-14 rounded-2xl flex items-center justify-center mb-4" style="background: var(--bg-active);">
					<Sparkles size={24} style="color: var(--text-tertiary);" />
				</div>
				<p class="text-base font-medium" style="color: var(--text-tertiary);">Trash is empty</p>
				<p class="text-sm mt-1.5" style="color: var(--text-tertiary);">Deleted files will appear here.</p>
			</div>
		{:else}
			<table class="min-w-full">
				<thead>
					<tr style="border-bottom: 1px solid var(--border);">
						<th class="px-4 py-3 w-8">
							<input type="checkbox" checked={selected.size === items.length && items.length > 0} onchange={selectAll} />
						</th>
						<th class="px-4 py-3 w-8"></th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Name</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: var(--text-tertiary);">Size</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: var(--text-tertiary);">Deleted</th>
						<th class="px-4 py-3 text-right text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Actions</th>
					</tr>
				</thead>
				<tbody>
					{#each items as item, i}
						<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
						<tr
							class="transition-colors cursor-pointer trash-row {selected.has(item.id) ? 'selected-row' : ''}"
							onclick={(e) => toggleSelect(item, i, e)}
						>
							<td class="px-4 py-3.5">
								<input type="checkbox" checked={selected.has(item.id)} onclick={(e) => e.stopPropagation()} onchange={(e) => toggleSelect(item, i, e)} />
							</td>
							<td class="px-4 py-3.5">
								{#if isDir(item)}
									<FolderOpen size={18} style="color: #f59e0b; opacity: 0.7;" />
								{:else}
									<FileText size={18} style="color: var(--text-tertiary);" />
								{/if}
							</td>
							<td class="px-4 py-3.5">
								<div>
									<p class="text-sm font-medium text-white/70">{item.name}</p>
									{#if item.original_path}
										<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">{item.original_path}</p>
									{/if}
								</div>
							</td>
							<td class="px-4 py-3.5 hidden sm:table-cell">
								<span class="text-sm" style="color: var(--text-tertiary);">
									{isDir(item) ? '—' : formatBytes(item.size)}
								</span>
							</td>
							<td class="px-4 py-3.5 hidden md:table-cell">
								<span class="text-sm" style="color: var(--text-tertiary);">{formatDate(item.deleted_at)}</span>
							</td>
							<td class="px-4 py-3.5">
								<div class="flex items-center justify-end gap-1">
									<button
										onclick={(e) => { e.stopPropagation(); restoreItem(item); }}
										class="flex items-center gap-1 text-xs font-medium px-2 py-1 rounded-md transition-all text-blue-400 hover:bg-blue-500/10"
									>
										<RotateCcw size={13} /> Restore
									</button>
									<button
										onclick={(e) => { e.stopPropagation(); confirmPermanentDelete(item); }}
										class="flex items-center gap-1 text-xs font-medium px-2 py-1 rounded-md transition-all text-red-400 hover:bg-red-500/10"
									>
										<Trash2 size={13} /> Delete
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

<style>
	.trash-row {
		border-bottom: 1px solid var(--border);
	}
	.trash-row:hover {
		background: var(--bg-hover);
	}
	.trash-row:last-child {
		border-bottom: none;
	}
	.selected-row {
		background: rgba(59,130,246,0.06) !important;
	}
</style>
