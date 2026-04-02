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
		Video,
		Search,
		X,
		Eye
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
		return { icon: File, color: 'var(--text-tertiary)' };
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

	// Search state
	let searchQuery = $state('');
	let searchResults = $state<FileItem[]>([]);
	let searching = $state(false);
	let searchActive = $state(false);
	let searchTimeout: ReturnType<typeof setTimeout> | null = null;

	// Preview state
	let previewFile = $state<FileItem | null>(null);
	let previewBlobUrl = $state<string | null>(null);
	let previewLoading = $state(false);

	function getPreviewType(file: FileItem): 'image' | 'pdf' | 'video' | 'audio' | 'none' {
		const ext = file.name.split('.').pop()?.toLowerCase() || '';
		if (['jpg','jpeg','png','gif','webp','svg','bmp','ico','tiff'].includes(ext)) return 'image';
		if (['pdf'].includes(ext)) return 'pdf';
		if (['mp4','mov','avi','mkv','webm'].includes(ext)) return 'video';
		if (['mp3','wav','flac','aac','ogg','m4a'].includes(ext)) return 'audio';
		return 'none';
	}

	async function openPreview(file: FileItem) {
		previewFile = file;
		const ptype = getPreviewType(file);
		if (ptype === 'none') {
			previewBlobUrl = null;
			previewLoading = false;
			return;
		}
		previewLoading = true;
		try {
			const token = localStorage.getItem('access_token');
			const res = await fetch(`/api/files/${file.id}/download`, {
				headers: token ? { 'Authorization': `Bearer ${token}` } : {}
			});
			if (res.ok) {
				const blob = await res.blob();
				if (previewBlobUrl) URL.revokeObjectURL(previewBlobUrl);
				previewBlobUrl = URL.createObjectURL(blob);
			}
		} catch {
			// Silently fail
		} finally {
			previewLoading = false;
		}
	}

	function closePreview() {
		previewFile = null;
		if (previewBlobUrl) {
			URL.revokeObjectURL(previewBlobUrl);
			previewBlobUrl = null;
		}
	}

	function onSearchInput() {
		if (searchTimeout) clearTimeout(searchTimeout);
		if (!searchQuery.trim()) {
			searchResults = [];
			searchActive = false;
			return;
		}
		searchTimeout = setTimeout(async () => {
			searching = true;
			searchActive = true;
			try {
				const res = await api.get(`/api/files/search?q=${encodeURIComponent(searchQuery.trim())}`);
				if (res.ok) {
					const data = await res.json();
					const rawFiles = data.files || [];
					searchResults = rawFiles.map((f: any) => ({
						...f,
						type: f.is_dir ? 'folder' : 'file'
					}));
				}
			} catch {
				// Silently fail
			} finally {
				searching = false;
			}
		}, 300);
	}

	function clearSearch() {
		searchQuery = '';
		searchResults = [];
		searchActive = false;
		if (searchTimeout) clearTimeout(searchTimeout);
	}

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
	style="background: var(--bg-base);"
	onclick={closeContextMenu}
	ondragover={(e) => { e.preventDefault(); dragOver = true; }}
	ondragleave={() => { dragOver = false; }}
	ondrop={onDrop}
>
	{#if dragOver}
		<div class="fixed inset-0 z-40 pointer-events-none flex items-center justify-center" style="background: rgba(59,130,246,0.08); border: 3px dashed rgba(59,130,246,0.40);">
			<div class="rounded-xl px-8 py-6 text-center" style="background: var(--bg-overlay); border: 1px solid var(--border);">
				<Upload size={36} class="mx-auto mb-3 text-blue-400" />
				<p class="text-base font-semibold text-white">Drop files to upload</p>
			</div>
		</div>
	{/if}

	<!-- Header bar -->
	<div class="px-5 py-3.5 border-b flex items-center justify-between gap-4" style="background: var(--bg-elevated); border-color: var(--border);">
		<BreadcrumbNav items={breadcrumbs} onclick={navigateToBreadcrumb} />
		<div class="flex items-center gap-2 flex-shrink-0">
			<!-- Search bar -->
			<div class="relative">
				<div class="flex items-center rounded-lg border transition-all duration-150" style="background: var(--bg-hover); border-color: var(--border);">
					<Search size={14} class="ml-2.5 text-white/40 flex-shrink-0" />
					<input
						type="text"
						bind:value={searchQuery}
						oninput={onSearchInput}
						placeholder="Search files..."
						class="bg-transparent border-none text-sm text-white/80 placeholder:text-white/30 px-2 py-1.5 w-40 focus:w-56 transition-all duration-200 outline-none"
					/>
					{#if searchQuery}
						<button onclick={clearSearch} class="mr-1.5 p-0.5 rounded hover:bg-white/10 transition-colors">
							<X size={12} class="text-white/40" />
						</button>
					{/if}
				</div>
				{#if searchActive}
					<div class="absolute top-full right-0 mt-1 w-80 max-h-80 overflow-auto rounded-xl border z-50" style="background: var(--bg-overlay); border-color: var(--border); box-shadow: 0 8px 32px rgba(0,0,0,0.5);">
						{#if searching}
							<div class="px-4 py-3 text-sm text-white/40 text-center">Searching...</div>
						{:else if searchResults.length === 0}
							<div class="px-4 py-3 text-sm text-white/40 text-center">No results found</div>
						{:else}
							{#each searchResults as result}
								{@const fi = getFileIcon(result)}
								<button
									class="flex items-center gap-3 w-full px-4 py-2.5 text-left hover:bg-white/[0.04] transition-colors"
									onclick={() => {
										clearSearch();
										if (result.type === 'folder') {
											goto(`/files/${result.id}`);
										} else {
											openPreview(result);
										}
									}}
								>
									<svelte:component this={fi.icon} size={15} style="color: {fi.color};" />
									<div class="flex-1 min-w-0">
										<p class="text-sm text-white/75 truncate">{result.name}</p>
										<p class="text-[10px]" style="color: var(--text-tertiary);">{result.type === 'folder' ? 'Folder' : formatBytes(result.size)}</p>
									</div>
								</button>
							{/each}
						{/if}
					</div>
				{/if}
			</div>
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
				style="background: var(--bg-hover); border: 1px solid var(--border);"
			>
				<FolderPlus size={14} /> New Folder
			</button>
		</div>
	</div>

	<input bind:this={fileInput} type="file" multiple class="hidden" onchange={onFileInputChange} />

	<div class="flex-1 overflow-auto p-5">
		{#if loading}
			<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
				<table class="min-w-full">
					<thead>
						<tr style="border-bottom: 1px solid var(--border);">
							<th class="px-4 py-3 w-8"></th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Name</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: var(--text-tertiary);">Size</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: var(--text-tertiary);">Modified</th>
						</tr>
					</thead>
					<tbody>
						{#each [1,2,3,4,5] as _}
							<tr style="border-bottom: 1px solid var(--border);">
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
				<FolderOpen size={48} style="color: var(--text-tertiary); margin: 0 auto 16px;" />
				<p class="text-sm font-medium text-white/40">This folder is empty</p>
				<p class="text-xs mt-1.5" style="color: var(--text-tertiary);">Upload files or create a folder to get started.</p>
			</div>
		{:else}
			<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
				<table class="min-w-full">
					<thead>
						<tr style="border-bottom: 1px solid var(--border);">
							<th class="px-4 py-3 w-8"></th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Name</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: var(--text-tertiary);">Size</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: var(--text-tertiary);">Modified</th>
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
										openPreview(item);
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
									<span class="text-sm" style="color: var(--text-tertiary);">
										{item.type === 'folder' ? '—' : formatBytes(item.size)}
									</span>
								</td>
								<td class="px-4 py-3.5 hidden md:table-cell">
									<span class="text-sm" style="color: var(--text-tertiary);">{formatDate(item.updated_at)}</span>
								</td>
								<td class="px-4 py-3.5">
									<button
										onclick={(e) => { e.stopPropagation(); openContextMenu(e, item); }}
										class="p-1 rounded transition-colors"
										style="color: var(--text-tertiary);"
										onmouseenter={(e) => { (e.currentTarget as HTMLElement).style.color = 'var(--text-secondary)'; (e.currentTarget as HTMLElement).style.background = 'var(--bg-hover)'; }}
										onmouseleave={(e) => { (e.currentTarget as HTMLElement).style.color = 'var(--text-tertiary)'; (e.currentTarget as HTMLElement).style.background = ''; }}
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
		style="left: {contextMenu.x}px; top: {contextMenu.y}px; background: var(--bg-overlay); border: 1px solid var(--border); box-shadow: 0 8px 32px rgba(0,0,0,0.5);"
		onclick={(e) => e.stopPropagation()}
	>
		{#if contextMenu.item.type === 'file'}
			<button onclick={() => { openPreview(contextMenu!.item); closeContextMenu(); }} class="context-item flex items-center gap-2 w-full px-4 py-2 text-sm text-white/70">
				<Eye size={14} style="color: var(--text-tertiary);" /> Preview
			</button>
			<button onclick={() => { downloadFile(contextMenu!.item); }} class="context-item flex items-center gap-2 w-full px-4 py-2 text-sm text-white/70">
				<Download size={14} style="color: var(--text-tertiary);" /> Download
			</button>
		{/if}
		<button onclick={() => startRename(contextMenu!.item)} class="context-item flex items-center gap-2 w-full px-4 py-2 text-sm text-white/70">
			<Edit2 size={14} style="color: var(--text-tertiary);" /> Rename
		</button>
		<button class="context-item flex items-center gap-2 w-full px-4 py-2 text-sm text-white/70" onclick={closeContextMenu}>
			<Move size={14} style="color: var(--text-tertiary);" /> Move
		</button>
		<div style="border-top: 1px solid var(--border); margin: 4px 0;"></div>
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
				<label for="folderName" class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Folder name</label>
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
			<button onclick={() => { showNewFolder = false; newFolderName = ''; }} class="rounded-lg px-4 py-2 text-sm font-medium transition-all duration-150 text-white/60 hover:text-white/80" style="background: var(--bg-hover); border: 1px solid var(--border);">Cancel</button>
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
				<label for="renameName" class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">New name</label>
				<input id="renameName" type="text" bind:value={renameName} onkeydown={(e) => e.key === 'Enter' && doRename()} />
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showRename = false)} class="rounded-lg px-4 py-2 text-sm font-medium transition-all duration-150 text-white/60 hover:text-white/80" style="background: var(--bg-hover); border: 1px solid var(--border);">Cancel</button>
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

{#if previewFile}
	<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
	<div
		class="fixed inset-0 z-50 flex items-center justify-center"
		style="background: rgba(0,0,0,0.7); backdrop-filter: blur(4px);"
		onclick={closePreview}
	>
		<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
		<div
			class="relative rounded-2xl border w-full max-w-3xl max-h-[85vh] overflow-auto mx-4"
			style="background: var(--bg-elevated); border-color: var(--border); box-shadow: 0 16px 64px rgba(0,0,0,0.6);"
			onclick={(e) => e.stopPropagation()}
		>
			<!-- Preview header -->
			<div class="flex items-center justify-between px-5 py-3.5 border-b" style="border-color: var(--border);">
				<div class="flex items-center gap-3 min-w-0">
					{#if previewFile}
						{@const pfi = getFileIcon(previewFile)}
						<svelte:component this={pfi.icon} size={17} style="color: {pfi.color};" />
						<span class="text-sm font-medium text-white/80 truncate">{previewFile.name}</span>
					{/if}
				</div>
				<div class="flex items-center gap-2 flex-shrink-0">
					<button
						onclick={() => { downloadFile(previewFile!); }}
						class="flex items-center gap-1.5 text-xs font-medium rounded-lg px-3 py-1.5 transition-all duration-150 text-white/60 hover:text-white/80"
						style="background: var(--bg-hover); border: 1px solid var(--border);"
					>
						<Download size={12} /> Download
					</button>
					<button
						onclick={closePreview}
						class="p-1.5 rounded-lg transition-colors text-white/40 hover:text-white/80 hover:bg-white/10"
					>
						<X size={16} />
					</button>
				</div>
			</div>

			<!-- Preview content -->
			<div class="p-5">
				{#if previewLoading}
					<div class="flex items-center justify-center py-16">
						<div class="w-6 h-6 border-2 border-blue-400 border-t-transparent rounded-full animate-spin"></div>
					</div>
				{:else if getPreviewType(previewFile) === 'image' && previewBlobUrl}
					<div class="flex items-center justify-center">
						<img src={previewBlobUrl} alt={previewFile.name} class="max-w-full max-h-[60vh] rounded-lg object-contain" />
					</div>
				{:else if getPreviewType(previewFile) === 'pdf' && previewBlobUrl}
					<iframe src={previewBlobUrl} title={previewFile.name} class="w-full rounded-lg border" style="height: 60vh; border-color: var(--border);" ></iframe>
				{:else if getPreviewType(previewFile) === 'video' && previewBlobUrl}
					<div class="flex items-center justify-center">
						<!-- svelte-ignore a11y_media_has_caption -->
						<video src={previewBlobUrl} controls class="max-w-full max-h-[60vh] rounded-lg">
							Your browser does not support the video element.
						</video>
					</div>
				{:else if getPreviewType(previewFile) === 'audio' && previewBlobUrl}
					<div class="flex items-center justify-center py-8">
						<!-- svelte-ignore a11y_media_has_caption -->
						<audio src={previewBlobUrl} controls class="w-full max-w-md">
							Your browser does not support the audio element.
						</audio>
					</div>
				{:else}
					<!-- File info for non-previewable files -->
					<div class="flex flex-col items-center justify-center py-12">
						{#if previewFile}
						{@const ficon = getFileIcon(previewFile)}
						<svelte:component this={ficon.icon} size={48} style="color: {ficon.color}; opacity: 0.6;" />
						<h3 class="text-base font-semibold text-white/80 mt-4">{previewFile.name}</h3>
						{/if}
						<div class="mt-3 space-y-1 text-center">
							<p class="text-sm" style="color: var(--text-tertiary);">Size: {formatBytes(previewFile.size)}</p>
							{#if previewFile.updated_at}
								<p class="text-sm" style="color: var(--text-tertiary);">Modified: {formatDate(previewFile.updated_at)}</p>
							{/if}
							{#if previewFile.mime_type}
								<p class="text-sm" style="color: var(--text-tertiary);">Type: {previewFile.mime_type}</p>
							{/if}
						</div>
						<button
							onclick={() => downloadFile(previewFile!)}
							class="mt-5 flex items-center gap-2 bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-all duration-150"
						>
							<Download size={14} /> Download File
						</button>
					</div>
				{/if}
			</div>
		</div>
	</div>
{/if}

<style>
	.file-row {
		border-bottom: 1px solid var(--border);
		cursor: pointer;
		transition: background 0.1s;
	}
	.file-row:last-child {
		border-bottom: none;
	}
	.file-row:hover {
		background: var(--bg-hover);
	}
	.selected-row {
		background: rgba(59,130,246,0.08);
		border-left: 2px solid #3b82f6;
	}
	.selected-row:hover {
		background: rgba(59,130,246,0.12);
	}
	.context-item:hover {
		background: var(--bg-hover);
	}
	.context-item-danger:hover {
		background: rgba(239,68,68,0.08);
	}
</style>
