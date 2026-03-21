<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/stores';
	import { onMount } from 'svelte';
	import {
		FolderOpen,
		FileText,
		Upload,
		FolderPlus,
		MoreHorizontal,
		Download,
		Edit2,
		Move,
		Trash2
	} from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes, formatDate } from '$lib/utils';
	import Modal from '$lib/components/Modal.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import FileDetails from '$lib/components/FileDetails.svelte';
	import BreadcrumbNav from '$lib/components/BreadcrumbNav.svelte';

	interface FileItem {
		id: string;
		name: string;
		size: number;
		mime_type?: string;
		type: 'file' | 'folder';
		owner?: string;
		created_at?: string;
		updated_at?: string;
		folder_id?: string | null;
	}

	interface BreadcrumbItem {
		id: string | null;
		name: string;
	}

	let folderId = $derived($page.params.folderId);
	let items = $state<FileItem[]>([]);
	let folderName = $state('');
	let loading = $state(true);
	let breadcrumbs = $state<BreadcrumbItem[]>([
		{ id: null, name: 'Files' }
	]);

	let showNewFolder = $state(false);
	let newFolderName = $state('');
	let creatingFolder = $state(false);

	let showRename = $state(false);
	let renameTarget = $state<FileItem | null>(null);
	let renameName = $state('');

	let showDelete = $state(false);
	let deleteTarget = $state<FileItem | null>(null);

	let selectedFile = $state<FileItem | null>(null);
	let contextMenu = $state<{ x: number; y: number; item: FileItem } | null>(null);
	let dragOver = $state(false);
	let uploading = $state(false);
	let fileInput: HTMLInputElement;

	onMount(() => {
		loadFolder();
	});

	async function loadFolder() {
		loading = true;
		try {
			// Load folder name from file metadata
			const folderRes = await api.get(`/api/files?parent_id=${folderId}`);
			// We don't have a get-single-file endpoint easily, so just set the name from the ID for now
			folderName = folderId;
			breadcrumbs = [{ id: null, name: 'Files' }, { id: folderId, name: 'Folder' }];

			// Load contents
			const res = await api.get(`/api/files?parent_id=${folderId}`);
			if (res.ok) {
				const data = await res.json();
				const rawFiles = data.files || data.items || data || [];
				items = rawFiles.map((f: any) => ({
					...f,
					type: f.is_dir ? 'folder' : 'file'
				}));
			} else {
				showToast('Failed to load folder', 'error');
			}
		} catch {
			showToast('Network error', 'error');
		} finally {
			loading = false;
		}
	}

	function navigateToFolder(item: FileItem) {
		goto(`/files/${item.id}`);
	}

	function navigateToBreadcrumb(crumb: BreadcrumbItem) {
		if (!crumb.id) {
			goto('/files');
		} else {
			goto(`/files/${crumb.id}`);
		}
	}

	async function createFolder() {
		if (!newFolderName.trim()) return;
		creatingFolder = true;
		try {
			const res = await api.post('/api/files', {
				name: newFolderName.trim(),
				parent_id: folderId,
				is_dir: true
			});
			if (res.ok) {
				showToast('Folder created', 'success');
				showNewFolder = false;
				newFolderName = '';
				loadFolder();
			} else {
				showToast('Failed to create folder', 'error');
			}
		} finally {
			creatingFolder = false;
		}
	}

	async function handleUpload(files: FileList | null) {
		if (!files || files.length === 0) return;
		uploading = true;
		let successCount = 0;

		for (const file of Array.from(files)) {
			const fd = new FormData();
			fd.append('file', file);
			fd.append('parent_id', folderId);
			const res = await api.upload('/api/files/upload', fd);
			if (res.ok) successCount++;
		}

		uploading = false;
		if (successCount > 0) {
			showToast(`${successCount} file(s) uploaded`, 'success');
			loadFolder();
		} else {
			showToast('Upload failed', 'error');
		}
	}

	function onFileInputChange(e: Event) {
		const input = e.target as HTMLInputElement;
		handleUpload(input.files);
		input.value = '';
	}

	function onDrop(e: DragEvent) {
		e.preventDefault();
		dragOver = false;
		handleUpload(e.dataTransfer?.files ?? null);
	}

	function openContextMenu(e: MouseEvent, item: FileItem) {
		e.preventDefault();
		contextMenu = { x: e.clientX, y: e.clientY, item };
	}

	function closeContextMenu() {
		contextMenu = null;
	}

	function startRename(item: FileItem) {
		renameTarget = item;
		renameName = item.name;
		showRename = true;
		closeContextMenu();
	}

	async function doRename() {
		if (!renameTarget || !renameName.trim()) return;
		const endpoint =
			renameTarget.type === 'folder'
				? `/api/folders/${renameTarget.id}`
				: `/api/files/${renameTarget.id}`;
		const res = await api.put(endpoint, { name: renameName.trim() });
		if (res.ok) {
			showToast('Renamed successfully', 'success');
			showRename = false;
			loadFolder();
		} else {
			showToast('Rename failed', 'error');
		}
	}

	function confirmDelete(item: FileItem) {
		deleteTarget = item;
		showDelete = true;
		closeContextMenu();
	}

	async function doDelete() {
		if (!deleteTarget) return;
		const endpoint =
			deleteTarget.type === 'folder'
				? `/api/folders/${deleteTarget.id}`
				: `/api/files/${deleteTarget.id}`;
		const res = await api.delete(endpoint);
		if (res.ok) {
			showToast('Moved to trash', 'success');
			showDelete = false;
			deleteTarget = null;
			loadFolder();
		} else {
			showToast('Delete failed', 'error');
		}
	}

	function downloadFile(item: FileItem) {
		window.open(`/api/files/${item.id}/download`, '_blank');
		closeContextMenu();
	}
</script>

<svelte:head>
	<title>{folderName || 'Files'} — SyncVault</title>
</svelte:head>

<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
<div
	class="h-full flex flex-col"
	onclick={closeContextMenu}
	ondragover={(e) => { e.preventDefault(); dragOver = true; }}
	ondragleave={() => { dragOver = false; }}
	ondrop={onDrop}
>
	{#if dragOver}
		<div class="fixed inset-0 z-40 bg-blue-500/10 border-4 border-dashed border-blue-400 pointer-events-none flex items-center justify-center">
			<div class="bg-white rounded-lg px-8 py-6 shadow-xl text-center">
				<Upload size={40} class="mx-auto mb-3 text-blue-500" />
				<p class="text-lg font-semibold text-gray-800">Drop files to upload</p>
			</div>
		</div>
	{/if}

	<div class="px-6 py-4 bg-white border-b border-gray-200 flex items-center justify-between gap-4">
		<BreadcrumbNav items={breadcrumbs} onclick={navigateToBreadcrumb} />
		<div class="flex items-center gap-2 flex-shrink-0">
			{#if uploading}
				<div class="flex items-center gap-2 text-sm text-blue-600">
					<div class="w-4 h-4 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
					Uploading…
				</div>
			{/if}
			<button
				onclick={() => fileInput.click()}
				class="flex items-center gap-2 bg-blue-500 hover:bg-blue-600 text-white text-sm font-medium rounded-md px-4 py-2 transition-colors"
			>
				<Upload size={16} /> Upload
			</button>
			<button
				onclick={() => (showNewFolder = true)}
				class="flex items-center gap-2 border border-gray-300 hover:bg-gray-50 text-gray-700 text-sm font-medium rounded-md px-4 py-2 transition-colors"
			>
				<FolderPlus size={16} /> New Folder
			</button>
		</div>
	</div>

	<input bind:this={fileInput} type="file" multiple class="hidden" onchange={onFileInputChange} />

	<div class="flex-1 overflow-auto p-6">
		{#if loading}
			<div class="flex items-center justify-center py-24">
				<div class="w-8 h-8 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
			</div>
		{:else if items.length === 0}
			<div class="text-center py-24 text-gray-400">
				<FolderOpen size={56} class="mx-auto mb-4 opacity-30" />
				<p class="text-base font-medium">This folder is empty</p>
				<p class="text-sm mt-1">Upload files or create a folder to get started.</p>
			</div>
		{:else}
			<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
				<table class="min-w-full divide-y divide-gray-200">
					<thead class="bg-gray-50">
						<tr>
							<th class="px-4 py-3 w-8"></th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Name</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden sm:table-cell">Size</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Modified</th>
							<th class="px-4 py-3 w-10"></th>
						</tr>
					</thead>
					<tbody class="bg-white divide-y divide-gray-200">
						{#each items as item}
							<tr
								class="hover:bg-gray-50 cursor-pointer transition-colors {selectedFile?.id === item.id ? 'bg-blue-50' : ''}"
								onclick={() => {
									if (item.type === 'folder') {
										navigateToFolder(item);
									} else {
										selectedFile = selectedFile?.id === item.id ? null : item;
									}
								}}
								oncontextmenu={(e) => openContextMenu(e, item)}
							>
								<td class="px-4 py-3">
									{#if item.type === 'folder'}
										<FolderOpen size={20} class="text-yellow-500" />
									{:else}
										<FileText size={20} class="text-gray-400" />
									{/if}
								</td>
								<td class="px-4 py-3">
									<span class="text-sm font-medium text-gray-900">{item.name}</span>
								</td>
								<td class="px-4 py-3 hidden sm:table-cell">
									<span class="text-sm text-gray-500">
										{item.type === 'folder' ? '—' : formatBytes(item.size)}
									</span>
								</td>
								<td class="px-4 py-3 hidden md:table-cell">
									<span class="text-sm text-gray-500">{formatDate(item.updated_at)}</span>
								</td>
								<td class="px-4 py-3">
									<button
										onclick={(e) => { e.stopPropagation(); openContextMenu(e, item); }}
										class="p-1 text-gray-400 hover:text-gray-600 rounded"
									>
										<MoreHorizontal size={16} />
									</button>
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</div>
</div>

{#if contextMenu}
	<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
	<div
		class="fixed z-50 bg-white rounded-lg shadow-xl border border-gray-200 py-1 w-44"
		style="left: {contextMenu.x}px; top: {contextMenu.y}px;"
		onclick={(e) => e.stopPropagation()}
	>
		{#if contextMenu.item.type === 'file'}
			<button onclick={() => { downloadFile(contextMenu!.item); }} class="flex items-center gap-2 w-full px-4 py-2 text-sm text-gray-700 hover:bg-gray-50">
				<Download size={15} /> Download
			</button>
		{/if}
		<button onclick={() => startRename(contextMenu!.item)} class="flex items-center gap-2 w-full px-4 py-2 text-sm text-gray-700 hover:bg-gray-50">
			<Edit2 size={15} /> Rename
		</button>
		<button class="flex items-center gap-2 w-full px-4 py-2 text-sm text-gray-700 hover:bg-gray-50" onclick={closeContextMenu}>
			<Move size={15} /> Move
		</button>
		<hr class="my-1 border-gray-100" />
		<button onclick={() => confirmDelete(contextMenu!.item)} class="flex items-center gap-2 w-full px-4 py-2 text-sm text-red-600 hover:bg-red-50">
			<Trash2 size={15} /> Delete
		</button>
	</div>
{/if}

<FileDetails file={selectedFile} onclose={() => (selectedFile = null)} />

{#if showNewFolder}
	<Modal title="New Folder" onclose={() => { showNewFolder = false; newFolderName = ''; }}>
		{#snippet children()}
			<div>
				<label for="folderName" class="block text-sm font-medium text-gray-700 mb-1">Folder name</label>
				<input
					id="folderName"
					type="text"
					bind:value={newFolderName}
					placeholder="My folder"
					class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
					onkeydown={(e) => e.key === 'Enter' && createFolder()}
				/>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => { showNewFolder = false; newFolderName = ''; }} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={createFolder} disabled={creatingFolder || !newFolderName.trim()} class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors">
				{creatingFolder ? 'Creating…' : 'Create'}
			</button>
		{/snippet}
	</Modal>
{/if}

{#if showRename && renameTarget}
	<Modal title="Rename" onclose={() => (showRename = false)}>
		{#snippet children()}
			<div>
				<label for="renameName" class="block text-sm font-medium text-gray-700 mb-1">New name</label>
				<input id="renameName" type="text" bind:value={renameName} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" onkeydown={(e) => e.key === 'Enter' && doRename()} />
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showRename = false)} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={doRename} disabled={!renameName.trim()} class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors">Rename</button>
		{/snippet}
	</Modal>
{/if}

{#if showDelete && deleteTarget}
	<ConfirmDialog
		title="Delete {deleteTarget.type === 'folder' ? 'Folder' : 'File'}"
		message="Are you sure you want to move '{deleteTarget.name}' to trash?"
		confirmLabel="Move to Trash"
		onconfirm={doDelete}
		oncancel={() => { showDelete = false; deleteTarget = null; }}
	/>
{/if}
