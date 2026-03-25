<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/stores';
	import { onMount } from 'svelte';
	import {
		Folder,
		FolderOpen,
		FileText,
		Upload,
		FolderPlus,
		MoreHorizontal,
		Download,
		Edit2,
		Move,
		Trash2,
		File,
		FileImage,
		FileCode,
		FileArchive,
		Music,
		Video
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

	function getFileIcon(file: FileItem): { icon: any; color: string } {
		if (file.type === 'folder') return { icon: Folder, color: '#f59e0b' };
		const ext = file.name.split('.').pop()?.toLowerCase() || '';
		if (['jpg','jpeg','png','gif','webp','svg','bmp','ico','tiff'].includes(ext)) return { icon: FileImage, color: '#22c55e' };
		if (['mp4','mov','avi','mkv','webm','flv','wmv'].includes(ext)) return { icon: Video, color: '#ec4899' };
		if (['mp3','wav','flac','aac','ogg','m4a'].includes(ext)) return { icon: Music, color: '#06b6d4' };
		if (['zip','tar','gz','rar','7z','bz2'].includes(ext)) return { icon: FileArchive, color: '#f97316' };
		if (['js','ts','jsx','tsx','py','go','rs','java','c','cpp','cs','php','rb','swift','kt','vue','svelte'].includes(ext)) return { icon: FileCode, color: '#a855f7' };
		if (['pdf'].includes(ext)) return { icon: FileText, color: '#ef4444' };
		if (['doc','docx','odt','rtf','txt','md'].includes(ext)) return { icon: FileText, color: '#3b82f6' };
		if (['xls','xlsx','csv','ods'].includes(ext)) return { icon: FileText, color: '#22c55e' };
		return { icon: File, color: 'rgba(255,255,255,0.40)' };
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
			const res = await api.get(`/api/files?parent_id=${folderId}`);
			folderName = folderId;
			breadcrumbs = [{ id: null, name: 'Files' }, { id: folderId, name: 'Folder' }];

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
	style="background: #0a0a0b;"
	onclick={closeContextMenu}
	ondragover={(e) => { e.preventDefault(); dragOver = true; }}
	ondragleave={() => { dragOver = false; }}
	ondrop={onDrop}
>
	{#if dragOver}
		<div class="fixed inset-0 z-40 pointer-events-none flex items-center justify-center" style="background: rgba(59,130,246,0.08); border: 3px dashed rgba(59,130,246,0.40);">
			<div class="rounded-xl px-8 py-6 text-center" style="background: #1a1a1d; border: 1px solid rgba(255,255,255,0.10);">
				<Upload size={36} class="mx-auto mb-3 text-blue-400" />
				<p class="text-base font-semibold text-white">Drop files to upload</p>
			</div>
		</div>
	{/if}

	<!-- Header bar -->
	<div class="px-5 py-3.5 border-b flex items-center justify-between gap-4" style="background: #111113; border-color: rgba(255,255,255,0.05);">
		<BreadcrumbNav items={breadcrumbs} onclick={navigateToBreadcrumb} />
		<div class="flex items-center gap-2 flex-shrink-0">
			{#if uploading}
				<div class="flex items-center gap-2 text-sm text-blue-400">
					<div class="w-3.5 h-3.5 border-2 border-blue-400 border-t-transparent rounded-full animate-spin"></div>
					Uploading…
				</div>
			{/if}
			<button
				onclick={() => fileInput.click()}
				class="flex items-center gap-2 bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium rounded-lg px-3.5 py-2 transition-all duration-150"
			>
				<Upload size={14} /> Upload
			</button>
			<button
				onclick={() => (showNewFolder = true)}
				class="flex items-center gap-2 text-sm font-medium rounded-lg px-3.5 py-2 transition-all duration-150 text-white/60 hover:text-white/80"
				style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.07);"
			>
				<FolderPlus size={14} /> New Folder
			</button>
		</div>
	</div>

	<input bind:this={fileInput} type="file" multiple class="hidden" onchange={onFileInputChange} />

	<div class="flex-1 overflow-auto p-5">
		{#if loading}
			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
				<table class="min-w-full">
					<thead>
						<tr style="border-bottom: 1px solid rgba(255,255,255,0.05);">
							<th class="px-4 py-3 w-8"></th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Name</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: rgba(255,255,255,0.30);">Size</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: rgba(255,255,255,0.30);">Modified</th>
						</tr>
					</thead>
					<tbody>
						{#each [1,2,3,4,5] as _}
							<tr style="border-bottom: 1px solid rgba(255,255,255,0.04);">
								<td class="px-4 py-3.5"><div class="skeleton h-5 rounded w-5"></div></td>
								<td class="px-4 py-3.5"><div class="skeleton h-4 rounded w-40"></div></td>
								<td class="px-4 py-3.5 hidden sm:table-cell"><div class="skeleton h-4 rounded w-16"></div></td>
								<td class="px-4 py-3.5 hidden md:table-cell"><div class="skeleton h-4 rounded w-24"></div></td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{:else if items.length === 0}
			<div class="text-center py-24">
				<FolderOpen size={48} style="color: rgba(255,255,255,0.08); margin: 0 auto 16px;" />
				<p class="text-sm font-medium text-white/40">This folder is empty</p>
				<p class="text-xs mt-1.5" style="color: rgba(255,255,255,0.20);">Upload files or create a folder to get started.</p>
			</div>
		{:else}
			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
				<table class="min-w-full">
					<thead>
						<tr style="border-bottom: 1px solid rgba(255,255,255,0.05);">
							<th class="px-4 py-3 w-8"></th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Name</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: rgba(255,255,255,0.30);">Size</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: rgba(255,255,255,0.30);">Modified</th>
							<th class="px-4 py-3 w-10"></th>
						</tr>
					</thead>
					<tbody>
						{#each items as item}
							{@const fi = getFileIcon(item)}
							<tr
								class="file-row {selectedFile?.id === item.id ? 'selected-row' : ''}"
								onclick={() => {
									if (item.type === 'folder') {
										navigateToFolder(item);
									} else {
										selectedFile = selectedFile?.id === item.id ? null : item;
									}
								}}
								oncontextmenu={(e) => openContextMenu(e, item)}
							>
								<td class="px-4 py-3.5">
									<svelte:component this={fi.icon} size={17} style="color: {fi.color};" />
								</td>
								<td class="px-4 py-3.5">
									<span class="text-sm font-medium text-white/75">{item.name}</span>
								</td>
								<td class="px-4 py-3.5 hidden sm:table-cell">
									<span class="text-sm" style="color: rgba(255,255,255,0.40);">
										{item.type === 'folder' ? '—' : formatBytes(item.size)}
									</span>
								</td>
								<td class="px-4 py-3.5 hidden md:table-cell">
									<span class="text-sm" style="color: rgba(255,255,255,0.40);">{formatDate(item.updated_at)}</span>
								</td>
								<td class="px-4 py-3.5">
									<button
										onclick={(e) => { e.stopPropagation(); openContextMenu(e, item); }}
										class="p-1 rounded transition-colors"
										style="color: rgba(255,255,255,0.25);"
										onmouseenter={(e) => { (e.currentTarget as HTMLElement).style.color = 'rgba(255,255,255,0.60)'; (e.currentTarget as HTMLElement).style.background = 'rgba(255,255,255,0.05)'; }}
										onmouseleave={(e) => { (e.currentTarget as HTMLElement).style.color = 'rgba(255,255,255,0.25)'; (e.currentTarget as HTMLElement).style.background = ''; }}
									>
										<MoreHorizontal size={15} />
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
		class="fixed z-50 rounded-xl py-1 w-44"
		style="left: {contextMenu.x}px; top: {contextMenu.y}px; background: #1a1a1d; border: 1px solid rgba(255,255,255,0.10); box-shadow: 0 8px 32px rgba(0,0,0,0.5);"
		onclick={(e) => e.stopPropagation()}
	>
		{#if contextMenu.item.type === 'file'}
			<button onclick={() => { downloadFile(contextMenu!.item); }} class="context-item flex items-center gap-2 w-full px-4 py-2 text-sm text-white/70">
				<Download size={14} style="color: rgba(255,255,255,0.40);" /> Download
			</button>
		{/if}
		<button onclick={() => startRename(contextMenu!.item)} class="context-item flex items-center gap-2 w-full px-4 py-2 text-sm text-white/70">
			<Edit2 size={14} style="color: rgba(255,255,255,0.40);" /> Rename
		</button>
		<button class="context-item flex items-center gap-2 w-full px-4 py-2 text-sm text-white/70" onclick={closeContextMenu}>
			<Move size={14} style="color: rgba(255,255,255,0.40);" /> Move
		</button>
		<div style="border-top: 1px solid rgba(255,255,255,0.07); margin: 4px 0;"></div>
		<button onclick={() => confirmDelete(contextMenu!.item)} class="context-item-danger flex items-center gap-2 w-full px-4 py-2 text-sm text-red-400">
			<Trash2 size={14} class="text-red-400" /> Delete
		</button>
	</div>
{/if}

<FileDetails file={selectedFile} onclose={() => (selectedFile = null)} />

{#if showNewFolder}
	<Modal title="New Folder" onclose={() => { showNewFolder = false; newFolderName = ''; }}>
		{#snippet children()}
			<div>
				<label for="folderName" class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.50);">Folder name</label>
				<input
					id="folderName"
					type="text"
					bind:value={newFolderName}
					placeholder="My folder"
					onkeydown={(e) => e.key === 'Enter' && createFolder()}
				/>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => { showNewFolder = false; newFolderName = ''; }} class="rounded-lg px-4 py-2 text-sm font-medium transition-all duration-150 text-white/60 hover:text-white/80" style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.08);">Cancel</button>
			<button onclick={createFolder} disabled={creatingFolder || !newFolderName.trim()} class="rounded-lg px-4 py-2 text-sm font-medium bg-blue-600 hover:bg-blue-500 disabled:opacity-50 text-white transition-all duration-150">
				{creatingFolder ? 'Creating…' : 'Create'}
			</button>
		{/snippet}
	</Modal>
{/if}

{#if showRename && renameTarget}
	<Modal title="Rename" onclose={() => (showRename = false)}>
		{#snippet children()}
			<div>
				<label for="renameName" class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.50);">New name</label>
				<input id="renameName" type="text" bind:value={renameName} onkeydown={(e) => e.key === 'Enter' && doRename()} />
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showRename = false)} class="rounded-lg px-4 py-2 text-sm font-medium transition-all duration-150 text-white/60 hover:text-white/80" style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.08);">Cancel</button>
			<button onclick={doRename} disabled={!renameName.trim()} class="rounded-lg px-4 py-2 text-sm font-medium bg-blue-600 hover:bg-blue-500 disabled:opacity-50 text-white transition-all duration-150">Rename</button>
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

<style>
	.file-row {
		border-bottom: 1px solid rgba(255,255,255,0.04);
		cursor: pointer;
		transition: background 0.1s;
	}
	.file-row:last-child {
		border-bottom: none;
	}
	.file-row:hover {
		background: rgba(255,255,255,0.03);
	}
	.selected-row {
		background: rgba(59,130,246,0.08);
		border-left: 2px solid #3b82f6;
	}
	.selected-row:hover {
		background: rgba(59,130,246,0.12);
	}
	.context-item:hover {
		background: rgba(255,255,255,0.05);
	}
	.context-item-danger:hover {
		background: rgba(239,68,68,0.08);
	}
</style>
