<script lang="ts">
	import { onMount } from 'svelte';
	import {
		Clock, FolderOpen, FileText, Download, RotateCcw, Settings2, Share2, Copy, Check, Trash2,
		FileImage, FileCode, FileArchive, FileSpreadsheet, FileVideo, FileAudio, File
	} from 'lucide-svelte';
	import Modal from '$lib/components/Modal.svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes, formatDate } from '$lib/utils';
	import BreadcrumbNav from '$lib/components/BreadcrumbNav.svelte';
	import FilePreview from '$lib/components/FilePreview.svelte';

	interface HistoryFile {
		id: string;
		name: string;
		is_dir: boolean;
		size: number;
		version_num: number;
		version_id: string;
		content_hash: string;
		updated_at: string;
		removed_locally?: boolean;
		_isTeam?: boolean;
	}

	interface BreadcrumbItem {
		id: string | null;
		name: string;
	}

	// Read folder ID from URL query parameter on init
	const urlFolder = typeof window !== 'undefined' ? new URL(window.location.href).searchParams.get('folder') : null;
	let currentFolderId = $state<string | null>(urlFolder);
	let breadcrumbs = $state<BreadcrumbItem[]>(
		urlFolder
			? [{ id: null, name: 'Files' }, { id: urlFolder, name: '...' }]
			: [{ id: null, name: 'Files' }]
	);
	let files = $state<HistoryFile[]>([]);
	let changeDates = $state<string[]>([]);
	let loading = $state(false);
	let selectedDate = $state<string | null>(null);
	let selectedFile = $state<HistoryFile | null>(null);

	// Sorting
	type SortKey = 'name' | 'size' | 'version_num' | 'updated_at';
	let sortKey = $state<SortKey>('name');
	let sortAsc = $state(true);

	function toggleSort(key: SortKey) {
		if (sortKey === key) {
			sortAsc = !sortAsc;
		} else {
			sortKey = key;
			sortAsc = key === 'name'; // name defaults ascending, others descending
		}
	}

	function sortedFiles(list: HistoryFile[]): HistoryFile[] {
		// Directories always first
		const dirs = list.filter(f => f.is_dir);
		const regular = list.filter(f => !f.is_dir);

		const compare = (a: HistoryFile, b: HistoryFile): number => {
			let result = 0;
			switch (sortKey) {
				case 'name':
					result = a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
					break;
				case 'size':
					result = (a.size || 0) - (b.size || 0);
					break;
				case 'version_num':
					result = (a.version_num || 0) - (b.version_num || 0);
					break;
				case 'updated_at':
					result = (a.updated_at || '').localeCompare(b.updated_at || '');
					break;
			}
			return sortAsc ? result : -result;
		};

		dirs.sort(compare);
		regular.sort(compare);
		return [...dirs, ...regular];
	}

	function sortIcon(key: SortKey): string {
		if (sortKey !== key) return '↕';
		return sortAsc ? '↑' : '↓';
	}
	let selectedFileDates = $state<string[]>([]);
	let previewFile = $state<HistoryFile | null>(null);

	// Timeline dimensions
	const TIMELINE_HEIGHT = 80;
	const TIMELINE_PADDING = 60;
	let timelineWidth = $state(900);
	let timelineContainer: HTMLDivElement;

	// Compute timeline range: 6 months back from today
	const today = new Date();
	const sixMonthsAgo = new Date(today);
	sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 6);
	sixMonthsAgo.setDate(1);
	const rangeStart = sixMonthsAgo.getTime();
	const rangeEnd = today.getTime();
	const rangeDuration = rangeEnd - rangeStart;

	function dateToX(date: Date): number {
		const t = date.getTime();
		const ratio = (t - rangeStart) / rangeDuration;
		return TIMELINE_PADDING + ratio * (timelineWidth - 2 * TIMELINE_PADDING);
	}

	function generateTicks() {
		const days: { x: number; isWeek: boolean; isMonth: boolean; label?: string }[] = [];
		const d = new Date(sixMonthsAgo);
		while (d <= today) {
			const x = dateToX(d);
			const isFirstOfMonth = d.getDate() === 1;
			const isMonday = d.getDay() === 1;
			if (isFirstOfMonth) {
				const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
				days.push({ x, isWeek: false, isMonth: true, label: monthNames[d.getMonth()] });
			} else if (isMonday) {
				days.push({ x, isWeek: true, isMonth: false });
			} else {
				days.push({ x, isWeek: false, isMonth: false });
			}
			d.setDate(d.getDate() + 1);
		}
		return days;
	}

	function generateDots() {
		return changeDates
			.map((dateStr) => {
				const d = new Date(dateStr + 'T12:00:00');
				if (d.getTime() < rangeStart || d.getTime() > rangeEnd) return null;
				return {
					x: dateToX(d),
					date: dateStr,
					isSelected: dateStr === selectedDate,
					isFileVersion: selectedFileDates.includes(dateStr)
				};
			})
			.filter(Boolean) as { x: number; date: string; isSelected: boolean; isFileVersion: boolean }[];
	}

	$effect(() => {
		if (timelineContainer) {
			const observer = new ResizeObserver((entries) => {
				for (const entry of entries) {
					timelineWidth = entry.contentRect.width;
				}
			});
			observer.observe(timelineContainer);
			return () => observer.disconnect();
		}
	});

	let ticks = $derived(generateTicks());
	let dots = $derived(generateDots());

	onMount(async () => {
		history.replaceState({ folderId: currentFolderId, breadcrumbs: JSON.parse(JSON.stringify(breadcrumbs)) }, '');
		// Load current files immediately (fast — no history query)
		await loadCurrentFiles(currentFolderId);
		// Timeline dates are loaded on-demand when user clicks the timeline area
		const handlePopState = (e: PopStateEvent) => {
			if (e.state?.breadcrumbs) {
				breadcrumbs = e.state.breadcrumbs;
				currentFolderId = e.state.folderId;
				selectedFile = null;
				selectedFileDates = [];
				selectedDate = null;
				changeDates = [];
				loadCurrentFiles(currentFolderId);
			}
		};
		window.addEventListener('popstate', handlePopState);
		return () => window.removeEventListener('popstate', handlePopState);
	});

	// Fast initial load — uses simple file listing (no version history)
	async function loadCurrentFiles(folderId: string | null) {
		loading = true;
		files = [];
		try {
			const params = folderId ? `?parent_id=${folderId}` : '?parent_id=';
			const res = await api.get(`/api/files${params}`);
			if (res.ok) {
				const data = await res.json();
				// Filter hidden/system files and map to history format
				files = (data.files || [])
					.filter((f: any) => !f.name.startsWith('.'))
					.map((f: any) => ({
					...f,
					version_num: f.version_num || (f.is_dir ? 0 : 1),
				}));
			}
		} catch {}
		loading = false;
	}

	async function loadChangeDates(folderId: string | null) {
		try {
			const path = folderId
				? `/api/files/history/dates?parent_id=${folderId}`
				: '/api/files/history/dates';
			const res = await api.get(path);
			if (res.ok) {
				const data = await res.json();
				changeDates = data.dates || [];
				// Don't auto-select date — user must click timeline
			}
		} catch {}
	}

	async function loadHistory(folderId: string | null, dateStr: string) {
		loading = true;
		files = [];
		try {
			const atISO = new Date(dateStr + 'T23:59:59').toISOString();
			const params = new URLSearchParams({ at: atISO });
			if (folderId) params.set('parent_id', folderId);
			const res = await api.get(`/api/files/history?${params}`);
			if (res.ok) {
				const data = await res.json();
				files = (data.files || []).filter((f: any) => !f.name.startsWith('.'));
			} else {
				showToast('Failed to load history', 'error');
			}

			if (!folderId) {
				try {
					const user = api.getUser();
					const teamEndpoint = user?.role === 'admin' ? '/api/teams' : '/api/teams/mine';
					const teamRes = await api.get(teamEndpoint);
					if (teamRes.ok) {
						const teamData = await teamRes.json();
						const teamList = teamData.teams || teamData || [];
						files = files.map((f: any) => {
							if (f.is_dir && f.name.startsWith('Team-') && !f._isTeam) {
								return { ...f, _isTeam: true };
							}
							return f;
						});
						const existingNames = new Set(files.map((f: any) => f.name));
						const teamFolders = teamList
							.filter((t: any) => !existingNames.has('Team-' + t.name))
							.map((t: any) => ({
								id: t.id,
								name: 'Team-' + t.name,
								is_dir: true,
								size: 0,
								version_num: 0,
								version_id: '',
								content_hash: '',
								updated_at: '',
								_isTeam: true
							}));
						files = [...files, ...teamFolders];
					}
				} catch {}
			}
		} catch {
			showToast('Network error', 'error');
		} finally {
			loading = false;
		}
	}

	function selectDate(dateStr: string) {
		selectedDate = dateStr;
		loadHistory(currentFolderId, dateStr);
	}

	// Load timeline dates on-demand (called when user clicks timeline area)
	let timelineLoaded = $state(false);
	function loadTimelineIfNeeded() {
		if (!timelineLoaded) {
			timelineLoaded = true;
			loadChangeDates(currentFolderId);
		}
	}

	async function navigateToFolder(file: HistoryFile) {
		selectedFile = null;
		selectedFileDates = [];
		breadcrumbs = [...breadcrumbs, { id: file.id, name: file.name }];
		currentFolderId = file.id;
		const url = new URL(window.location.href);
		url.searchParams.set('folder', file.id);
		history.pushState({ folderId: file.id, breadcrumbs: JSON.parse(JSON.stringify(breadcrumbs)) }, '', url);
		timelineLoaded = false;
		if (selectedDate) {
			loadHistory(file.id, selectedDate);
		} else {
			await loadCurrentFiles(file.id);
		}
	}

	function navigateToBreadcrumb(crumb: BreadcrumbItem) {
		selectedFile = null;
		selectedFileDates = [];
		const idx = breadcrumbs.findIndex((b) => b.id === crumb.id);
		if (idx >= 0) breadcrumbs = breadcrumbs.slice(0, idx + 1);
		currentFolderId = crumb.id;
		const url = new URL(window.location.href);
		if (crumb.id) url.searchParams.set('folder', crumb.id);
		else url.searchParams.delete('folder');
		history.pushState({ folderId: crumb.id, breadcrumbs: JSON.parse(JSON.stringify(breadcrumbs)) }, '', url);
		timelineLoaded = false;
		if (selectedDate) {
			loadHistory(crumb.id, selectedDate);
		} else {
			loadCurrentFiles(crumb.id);
		}
	}

	async function selectFile(file: HistoryFile) {
		if (selectedFile?.id === file.id) {
			selectedFile = null;
			selectedFileDates = [];
			return;
		}
		selectedFile = file;
		try {
			if (file.is_dir) {
				const res = await api.get(`/api/files/history/dates?parent_id=${file.id}`);
				if (res.ok) {
					const data = await res.json();
					selectedFileDates = data.dates || [];
				}
			} else {
				const res = await api.get(`/api/files/${file.id}/versions`);
				if (res.ok) {
					const versions = await res.json();
					const vList = Array.isArray(versions) ? versions : versions.versions || [];
					selectedFileDates = [...new Set(vList.map((v: any) => v.created_at?.slice(0, 10)).filter(Boolean))];
				}
			}
		} catch {
			selectedFileDates = [];
		}
	}

	async function downloadVersion(file: HistoryFile) {
		const url = file.version_num > 0
			? `/api/files/${file.id}/versions/${file.version_num}/download`
			: `/api/files/${file.id}/download`;
		const res = await api.get(url);
		if (res.ok) {
			const blob = await res.blob();
			const objectUrl = URL.createObjectURL(blob);
			const a = document.createElement('a');
			a.href = objectUrl;
			a.download = file.name;
			a.click();
			URL.revokeObjectURL(objectUrl);
		} else {
			showToast('Failed to download file', 'error');
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

	async function downloadFolder(file: HistoryFile) {
		if (!selectedDate) return;
		const atISO = new Date(selectedDate + 'T23:59:59').toISOString();
		const res = await api.get(`/api/files/history/download?parent_id=${file.id}&at=${atISO}`);
		if (res.ok) {
			const blob = await res.blob();
			const objectUrl = URL.createObjectURL(blob);
			const a = document.createElement('a');
			a.href = objectUrl;
			a.download = `${file.name}.zip`;
			a.click();
			URL.revokeObjectURL(objectUrl);
		} else {
			showToast('Failed to download folder', 'error');
		}
	}

	async function restoreFolder(file: HistoryFile) {
		if (!selectedDate) return;
		const atISO = new Date(selectedDate + 'T23:59:59').toISOString();
		const res = await api.post('/api/files/history/restore', { parent_id: file.id, at: atISO });
		if (res.ok) {
			const data = await res.json();
			showToast(`Restored ${data.restored} files in "${file.name}"`, 'success');
		} else {
			showToast('Restore failed', 'error');
		}
	}

	// Retention policy modal
	let showRetention = $state(false);
	let retentionFolder = $state<HistoryFile | null>(null);
	let retentionTaskId = $state<string | null>(null);
	let retention = $state({ hourly_hours: 0, daily_days: 0, weekly_weeks: 0, monthly_months: 0, yearly_years: 0, max_versions: 0 });
	let retentionSaving = $state(false);

	async function openRetention(file: HistoryFile) {
		retentionFolder = file;
		try {
			// Try user's own tasks first, then all tasks (admin)
			let task: any = null;
			const res = await api.get('/api/tasks');
			if (res.ok) {
				const tasks = await res.json();
				task = tasks.find((t: any) => t.folder_id === file.id);
			}
			if (!task && user?.role === 'admin') {
				const adminRes = await api.get(`/api/tasks?folder_id=${file.id}`);
				if (adminRes.ok) {
					const adminTasks = await adminRes.json();
					task = Array.isArray(adminTasks) ? adminTasks[0] : adminTasks?.tasks?.[0];
				}
			}
			{
				if (task) {
					retentionTaskId = task.id;
					const retRes = await api.get(`/api/tasks/${task.id}/retention`);
					if (retRes.ok) {
						retention = await retRes.json();
					}
					showRetention = true;
				} else {
					showToast('Retention requires a sync task. Configure sync in the macOS app first.', 'info');
				}
			}
		} catch {
			showToast('Could not load retention policy', 'error');
		}
	}

	async function saveRetention() {
		if (!retentionTaskId) return;
		retentionSaving = true;
		try {
			const res = await api.put(`/api/tasks/${retentionTaskId}/retention`, retention);
			if (res.ok) {
				showToast('Retention policy saved', 'success');
				showRetention = false;
			} else {
				showToast('Could not save retention policy', 'error');
			}
		} catch {
			showToast('Network error', 'error');
		} finally {
			retentionSaving = false;
		}
	}

	// Share modal
	let showShare = $state(false);
	let shareFile = $state<HistoryFile | null>(null);
	let shareName = $state('');
	let sharePassword = $state('');
	let shareExpiry = $state('');
	let shareMaxDownloads = $state(0);
	let shareNotifyOnDownload = $state(false);
	let shareCreating = $state(false);
	let shareUrl = $state('');
	let shareCopied = $state(false);

	function openShare(file: HistoryFile) {
		shareFile = file;
		shareName = file.name;
		sharePassword = '';
		shareExpiry = '';
		shareMaxDownloads = 0;
		shareNotifyOnDownload = false;
		shareUrl = '';
		shareCopied = false;
		showShare = true;
	}

	async function createShare() {
		if (!shareFile) return;
		shareCreating = true;
		try {
			const body: any = { name: shareName };
			if (sharePassword) body.password = sharePassword;
			if (shareExpiry) body.expires_at = new Date(shareExpiry).toISOString();
			if (shareMaxDownloads > 0) body.max_downloads = shareMaxDownloads;
			if (shareNotifyOnDownload) body.notify_on_download = true;
			const res = await api.post(`/api/files/${shareFile.id}/shares`, body);
			if (res.ok) {
				const data = await res.json();
				let baseUrl = window.location.origin;
				try {
					const settingsRes = await api.get('/api/admin/settings');
					if (settingsRes.ok) {
						const settings = await settingsRes.json();
						if (settings.base_url) baseUrl = settings.base_url.replace(/\/$/, '');
					}
				} catch {}
				shareUrl = `${baseUrl}/s/${data.token}`;
				showToast('Share link created', 'success');
			} else {
				showToast('Could not create share link', 'error');
			}
		} catch {
			showToast('Network error', 'error');
		} finally {
			shareCreating = false;
		}
	}

	async function copyShareUrl() {
		if (!shareUrl) return;
		await navigator.clipboard.writeText(shareUrl);
		shareCopied = true;
		setTimeout(() => (shareCopied = false), 2000);
	}

	// Delete folder
	let showDeleteFolder = $state(false);
	let deleteFolderTarget = $state<HistoryFile | null>(null);
	let deleteFolderHasSyncTask = $state(false);
	let deletingFolder = $state(false);

	async function openDeleteFolder(file: HistoryFile) {
		deleteFolderTarget = file;
		deleteFolderHasSyncTask = false;
		deletingFolder = false;
		try {
			const res = await api.get(`/api/tasks?folder_id=${file.id}`);
			if (res.ok) {
				const data = await res.json();
				const tasks = data.tasks || [];
				deleteFolderHasSyncTask = tasks.length > 0;
			}
		} catch {}
		showDeleteFolder = true;
	}

	async function confirmDeleteFolder() {
		if (!deleteFolderTarget) return;
		deletingFolder = true;
		try {
			const res = await api.delete(`/api/files/${deleteFolderTarget.id}`);
			if (res.ok) {
				showToast(`"${deleteFolderTarget.name}" deleted`, 'success');
				showDeleteFolder = false;
				deleteFolderTarget = null;
				if (selectedDate) await loadHistory(currentFolderId, selectedDate);
			} else {
				const data = await res.json().catch(() => ({}));
				showToast(data.error || 'Could not delete folder', 'error');
			}
		} finally {
			deletingFolder = false;
		}
	}

	function formatSelectedDate(dateStr: string): string {
		const d = new Date(dateStr + 'T12:00:00');
		return d.toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
	}

	// File type icons
	type FileIconType = {
		icon: typeof File;
		color: string;
	};

	function getFileIcon(file: HistoryFile): FileIconType {
		if (file.is_dir && file._isTeam) return { icon: FolderOpen, color: '#3b82f6' };
		if (file.is_dir) return { icon: FolderOpen, color: '#f59e0b' };
		const ext = file.name.split('.').pop()?.toLowerCase() || '';
		if (['pdf'].includes(ext)) return { icon: FileText, color: '#ef4444' };
		if (['jpg', 'jpeg', 'png', 'gif', 'svg', 'webp', 'bmp', 'ico', 'tiff'].includes(ext)) return { icon: FileImage, color: '#22c55e' };
		if (['js', 'ts', 'jsx', 'tsx', 'py', 'go', 'swift', 'rs', 'c', 'cpp', 'h', 'java', 'rb', 'php', 'sh', 'bash', 'json', 'yaml', 'yml', 'toml'].includes(ext)) return { icon: FileCode, color: '#a855f7' };
		if (['zip', 'tar', 'gz', 'bz2', 'rar', '7z', 'xz'].includes(ext)) return { icon: FileArchive, color: '#f97316' };
		if (['doc', 'docx', 'txt', 'md', 'rtf', 'odt'].includes(ext)) return { icon: FileText, color: '#3b82f6' };
		if (['xls', 'xlsx', 'csv', 'ods'].includes(ext)) return { icon: FileSpreadsheet, color: '#22c55e' };
		if (['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv', 'wmv'].includes(ext)) return { icon: FileVideo, color: '#ec4899' };
		if (['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a'].includes(ext)) return { icon: FileAudio, color: '#06b6d4' };
		return { icon: File, color: 'var(--text-tertiary)' };
	}
</script>

<svelte:head>
	<title>Files — SyncVault</title>
</svelte:head>

<div class="h-full flex flex-col" style="background: var(--bg-base);">
	<!-- Top bar -->
	<div class="px-6 py-4 border-b flex-shrink-0" style="border-color: var(--border);">
		<div class="flex items-center justify-between">
			<div class="flex items-center gap-3">
				<FolderOpen size={20} class="text-blue-400 flex-shrink-0" />
				<h1 class="text-base font-semibold" style="color: var(--text-primary);">Files</h1>
				{#if selectedDate}
					<span class="text-sm" style="color: var(--text-tertiary);">— {formatSelectedDate(selectedDate)}</span>
				{/if}
			</div>
		</div>
	</div>

	<!-- Breadcrumb bar -->
	<div class="px-6 py-2.5 border-b flex-shrink-0" style="background: var(--bg-hover); border-color: var(--border);">
		<BreadcrumbNav items={breadcrumbs} onclick={navigateToBreadcrumb} />
	</div>

	<!-- File list -->
	<div class="flex-1 overflow-auto p-6">
		{#if loading}
			<!-- Skeleton loading -->
			<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
				<div class="px-4 py-3 border-b" style="border-color: var(--border);">
					<div class="flex gap-4">
						<div class="skeleton h-3 rounded w-8"></div>
						<div class="skeleton h-3 rounded w-40"></div>
						<div class="skeleton h-3 rounded w-20 ml-auto hidden sm:block"></div>
					</div>
				</div>
				{#each [1,2,3,4,5] as _}
					<div class="px-4 py-3.5 border-b flex items-center gap-3" style="border-color: var(--border);">
						<div class="skeleton w-5 h-5 rounded flex-shrink-0"></div>
						<div class="skeleton h-3 rounded flex-1 max-w-[200px]"></div>
						<div class="skeleton h-3 rounded w-16 ml-auto hidden sm:block"></div>
					</div>
				{/each}
			</div>
		{:else if files.length === 0}
			<div class="flex flex-col items-center justify-center py-24">
				<div class="w-16 h-16 rounded-2xl flex items-center justify-center mb-4" style="background: var(--bg-active);">
					<FolderOpen size={28} style="color: var(--text-tertiary);" />
				</div>
				<p class="text-base font-medium text-[var(--text-tertiary)]">No files yet</p>
				<p class="text-sm mt-1.5" style="color: var(--text-tertiary);">Upload or sync to get started.</p>
			</div>
		{:else}
			{@const userFiles = sortedFiles(breadcrumbs.length <= 1 ? files.filter(f => !f._isTeam) : files)}
			{@const teamFiles = sortedFiles(breadcrumbs.length <= 1 ? files.filter(f => f._isTeam) : [])}

			{#if breadcrumbs.length <= 1 && userFiles.length > 0}
				<p class="px-1 mb-2 text-[10px] font-semibold uppercase tracking-widest" style="color: var(--text-tertiary);">My Files</p>
			{/if}

			{#if userFiles.length > 0}
			<div class="rounded-xl border overflow-hidden mb-6" style="background: var(--bg-elevated); border-color: var(--border);">
				<table class="min-w-full">
					<thead>
						<tr style="border-bottom: 1px solid var(--border);">
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider w-8" style="color: var(--text-tertiary);"></th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider cursor-pointer select-none hover:text-[var(--text-secondary)]" style="color: var(--text-tertiary);" onclick={() => toggleSort('name')}>Name <span class="opacity-50">{sortIcon('name')}</span></th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell cursor-pointer select-none hover:text-[var(--text-secondary)]" style="color: var(--text-tertiary);" onclick={() => toggleSort('size')}>Size <span class="opacity-50">{sortIcon('size')}</span></th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell cursor-pointer select-none hover:text-[var(--text-secondary)]" style="color: var(--text-tertiary);" onclick={() => toggleSort('version_num')}>Version <span class="opacity-50">{sortIcon('version_num')}</span></th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell cursor-pointer select-none hover:text-[var(--text-secondary)]" style="color: var(--text-tertiary);" onclick={() => toggleSort('updated_at')}>Date <span class="opacity-50">{sortIcon('updated_at')}</span></th>
							<th class="px-4 py-3 text-right text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Actions</th>
						</tr>
					</thead>
					<tbody>
						{#each userFiles as file}
							{@const fi = getFileIcon(file)}
							<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
							<tr
								class="transition-colors cursor-pointer file-row {selectedFile?.id === file.id ? 'selected-row' : ''}"
								onclick={() => selectFile(file)}
								ondblclick={() => { if (file.is_dir) navigateToFolder(file); else previewFile = file; }}
							>
								<td class="px-4 py-3.5">
									<svelte:component this={fi.icon} size={18} style="color: {fi.color};" />
								</td>
								<td class="px-4 py-3.5">
									<div class="flex items-center gap-2">
										<span class="text-sm font-medium text-[var(--text-primary)]">{file.name}</span>
										{#if file.removed_locally}
											<span class="text-[10px] text-[var(--text-tertiary)] border rounded px-1.5 py-0.5" style="border-color: var(--border);">Removed locally</span>
										{/if}
									</div>
								</td>
								<td class="px-4 py-3.5 hidden sm:table-cell">
									<span class="text-sm" style="color: var(--text-tertiary);">{formatBytes(file.size)}</span>
								</td>
								<td class="px-4 py-3.5 hidden md:table-cell">
									{#if !file.is_dir}
										<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium" style="background: rgba(59,130,246,0.12); color: #60a5fa;">
											v{file.version_num}
										</span>
									{:else}
										<span style="color: var(--text-tertiary);">—</span>
									{/if}
								</td>
								<td class="px-4 py-3.5 hidden md:table-cell">
									<span class="text-sm" style="color: var(--text-tertiary);">{formatDate(file.updated_at)}</span>
								</td>
								<td class="px-4 py-3.5">
									<div class="flex items-center gap-1 justify-end">
										{#if file.is_dir}
											<button onclick={(e) => { e.stopPropagation(); openShare(file); }} title="Share folder" class="action-btn action-btn-purple">
												<Share2 size={13} /> Share
											</button>
											<button onclick={(e) => { e.stopPropagation(); downloadFolder(file); }} title="Download as ZIP" class="action-btn action-btn-blue">
												<Download size={13} /> Download
											</button>
											<button onclick={(e) => { e.stopPropagation(); restoreFolder(file); }} title="Restore folder" class="action-btn">
												<RotateCcw size={13} /> Restore
											</button>
											<button onclick={(e) => { e.stopPropagation(); openDeleteFolder(file); }} title="Delete folder" class="action-btn action-btn-red">
												<Trash2 size={13} /> Delete
											</button>
										{:else}
											<button onclick={(e) => { e.stopPropagation(); openShare(file); }} title="Share file" class="action-btn action-btn-purple">
												<Share2 size={13} /> Share
											</button>
											<button onclick={(e) => { e.stopPropagation(); downloadVersion(file); }} title="Download this version" class="action-btn action-btn-blue">
												<Download size={13} /> Download
											</button>
											<button onclick={(e) => { e.stopPropagation(); restoreVersion(file); }} title="Restore to current" class="action-btn">
												<RotateCcw size={13} /> Restore
											</button>
											<button onclick={(e) => { e.stopPropagation(); openDeleteFolder(file); }} title="Delete file" class="action-btn action-btn-red">
												<Trash2 size={13} /> Delete
											</button>
										{/if}
									</div>
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
			{/if}

			{#if teamFiles.length > 0}
				<p class="px-1 mt-2 mb-2 text-[10px] font-semibold uppercase tracking-widest" style="color: var(--text-tertiary);">Team Folders</p>
				<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
					<table class="min-w-full">
						<thead>
							<tr style="border-bottom: 1px solid var(--border);">
								<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider w-8" style="color: var(--text-tertiary);"></th>
								<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Name</th>
								<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: var(--text-tertiary);">Size</th>
								<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: var(--text-tertiary);">Version</th>
								<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: var(--text-tertiary);">Date</th>
								<th class="px-4 py-3 text-right text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Actions</th>
							</tr>
						</thead>
						<tbody>
							{#each teamFiles as file}
								<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
								<tr
									class="transition-colors cursor-pointer file-row {selectedFile?.id === file.id ? 'selected-row' : ''}"
									onclick={() => selectFile(file)}
									ondblclick={() => navigateToFolder(file)}
								>
									<td class="px-4 py-3.5">
										<FolderOpen size={18} style="color: #3b82f6;" />
									</td>
									<td class="px-4 py-3.5">
										<span class="text-sm font-medium text-[var(--text-primary)]">{file.name.replace('Team-', '')}</span>
									</td>
									<td class="px-4 py-3.5 hidden sm:table-cell">
										<span class="text-sm" style="color: var(--text-tertiary);">{file.size ? formatBytes(file.size) : '—'}</span>
									</td>
									<td class="px-4 py-3.5 hidden md:table-cell">
										<span style="color: var(--text-tertiary);">—</span>
									</td>
									<td class="px-4 py-3.5 hidden md:table-cell">
										<span class="text-sm" style="color: var(--text-tertiary);">{formatDate(file.updated_at)}</span>
									</td>
									<td class="px-4 py-3.5">
										<div class="flex items-center gap-1 justify-end">
											<button onclick={(e) => { e.stopPropagation(); openShare(file); }} title="Share" class="action-btn action-btn-purple">
												<Share2 size={13} /> Share
											</button>
											<button onclick={(e) => { e.stopPropagation(); downloadFolder(file); }} title="Download" class="action-btn action-btn-blue">
												<Download size={13} /> Download
											</button>
											<button onclick={(e) => { e.stopPropagation(); openDeleteFolder(file); }} title="Delete" class="action-btn action-btn-red">
												<Trash2 size={13} /> Delete
											</button>
										</div>
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		{/if}
	</div>

	<!-- Timeline (loads dates on first hover/click) -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div class="border-t flex-shrink-0 px-4 py-2" style="background: var(--bg-base); border-color: var(--border);" bind:this={timelineContainer} onmouseenter={loadTimelineIfNeeded}>
		<svg width="100%" height={TIMELINE_HEIGHT} class="select-none">
			<!-- Base line -->
			<line
				x1={TIMELINE_PADDING}
				y1={TIMELINE_HEIGHT - 16}
				x2={timelineWidth - TIMELINE_PADDING}
				y2={TIMELINE_HEIGHT - 16}
				stroke="var(--border-strong)"
				stroke-width="1"
			/>

			<!-- Day / Week / Month ticks -->
			{#each ticks as tick}
				{#if tick.isMonth}
					<line
						x1={tick.x} y1={TIMELINE_HEIGHT - 16}
						x2={tick.x} y2={TIMELINE_HEIGHT - 48}
						stroke="var(--border)" stroke-width="1"
					/>
					<text
						x={tick.x} y={TIMELINE_HEIGHT - 52}
						text-anchor="middle"
						style="font-size: 9px; fill: var(--text-tertiary); font-weight: 500;"
					>{tick.label}</text>
				{:else if tick.isWeek}
					<line
						x1={tick.x} y1={TIMELINE_HEIGHT - 16}
						x2={tick.x} y2={TIMELINE_HEIGHT - 30}
						stroke="var(--border)" stroke-width="0.5"
					/>
				{:else}
					<line
						x1={tick.x} y1={TIMELINE_HEIGHT - 16}
						x2={tick.x} y2={TIMELINE_HEIGHT - 22}
						stroke="var(--border)" stroke-width="0.5"
					/>
				{/if}
			{/each}

			<!-- Version dots -->
			{#each dots as dot}
				<!-- svelte-ignore a11y_click_events_have_key_events -->
				<g
					class="version-dot"
					class:selected={dot.isSelected}
					class:file-version={dot.isFileVersion}
					role="button"
					tabindex="0"
					onclick={() => selectDate(dot.date)}
					onkeydown={(e) => { if (e.key === 'Enter') selectDate(dot.date); }}
				>
					<line class="dot-line" x1={dot.x} y1={TIMELINE_HEIGHT - 16} x2={dot.x} y2={TIMELINE_HEIGHT - 38} />
					<circle class="dot-circle" cx={dot.x} cy={TIMELINE_HEIGHT - 40} stroke="none">
						<title>{dot.date}</title>
					</circle>
				</g>

				{#if dot.isSelected}
					<text
						x={dot.x} y={TIMELINE_HEIGHT - 52}
						text-anchor="middle"
						style="font-size: 9px; fill: #60a5fa; font-weight: 600;"
					>{dot.date.slice(5)}</text>
				{/if}
			{/each}
		</svg>
	</div>
</div>

{#if showRetention}
<Modal title="Retention Policy — {retentionFolder?.name}" onclose={() => (showRetention = false)}>
	{#snippet children()}
		<div class="space-y-3">
			<p class="text-sm" style="color: var(--text-secondary);">Set how long versions are kept. Use 0 for unlimited.</p>
			{#each [
				{ label: 'Hourly', unit: 'hours', key: 'hourly_hours', desc: 'Keep one version per hour' },
				{ label: 'Daily', unit: 'days', key: 'daily_days', desc: 'Keep one version per day' },
				{ label: 'Weekly', unit: 'weeks', key: 'weekly_weeks', desc: 'Keep one version per week' },
				{ label: 'Monthly', unit: 'months', key: 'monthly_months', desc: 'Keep one version per month' },
				{ label: 'Yearly', unit: 'years', key: 'yearly_years', desc: 'Keep one version per year' },
				{ label: 'Max versions', unit: '', key: 'max_versions', desc: 'Hard cap on total versions' }
			] as field}
				<div class="flex items-center justify-between gap-4">
					<div class="flex-1">
						<span class="text-sm font-medium text-[var(--text-secondary)]">{field.label}</span>
						<span class="text-xs ml-1" style="color: var(--text-tertiary);">— {field.desc}</span>
					</div>
					<div class="flex items-center gap-2 w-28">
						<input type="number" min="0" bind:value={retention[field.key]} style="width: 80px; text-align: right;" />
						{#if field.unit}
							<span class="text-xs w-12" style="color: var(--text-tertiary);">{field.unit}</span>
						{/if}
					</div>
				</div>
			{/each}
		</div>
	{/snippet}
	{#snippet footer()}
		<button onclick={() => (showRetention = false)} class="px-4 py-2 text-sm font-medium text-[var(--text-secondary)] border rounded-lg hover:bg-white/5 transition-all" style="border-color: var(--border);">Cancel</button>
		<button onclick={saveRetention} disabled={retentionSaving} class="px-4 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-500 disabled:opacity-40 rounded-lg transition-all">
			{retentionSaving ? 'Saving…' : 'Save'}
		</button>
	{/snippet}
</Modal>
{/if}

{#if showShare}
<Modal title="Share — {shareFile?.name}" onclose={() => (showShare = false)}>
	{#snippet children()}
		<div class="space-y-3">
			<div>
				<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Name</label>
				<input type="text" bind:value={shareName} />
			</div>
			{#if shareUrl}
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Share URL</label>
					<div class="flex items-center gap-2">
						<input type="text" readonly value={shareUrl} style="font-size: 12px;" />
						<button onclick={copyShareUrl}
							class="flex items-center gap-1 px-3 py-2 text-xs font-medium rounded-lg transition-all flex-shrink-0"
							style="{shareCopied ? 'background: rgba(34,197,94,0.12); color: #4ade80;' : 'background: var(--bg-active); color: var(--text-secondary);'}">
							{#if shareCopied}
								<Check size={12} /> Copied
							{:else}
								<Copy size={12} /> Copy
							{/if}
						</button>
					</div>
				</div>
			{/if}
			<div>
				<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Password <span style="color: var(--text-tertiary);">— optional</span></label>
				<input type="text" bind:value={sharePassword} placeholder="Leave empty for no password" />
			</div>
			<div>
				<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Expiry date <span style="color: var(--text-tertiary);">— optional</span></label>
				<input type="datetime-local" bind:value={shareExpiry} />
			</div>
			<div>
				<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Max downloads <span style="color: var(--text-tertiary);">— 0 = unlimited</span></label>
				<input type="number" min="0" bind:value={shareMaxDownloads} />
			</div>
			<div class="flex items-center gap-3">
				<input type="checkbox" id="notify-download" bind:checked={shareNotifyOnDownload} />
				<label for="notify-download" class="text-sm" style="color: var(--text-secondary);">Email me when someone downloads</label>
			</div>
		</div>
	{/snippet}
	{#snippet footer()}
		<button onclick={() => (showShare = false)} class="px-4 py-2 text-sm font-medium text-[var(--text-secondary)] border rounded-lg hover:bg-white/5 transition-all" style="border-color: var(--border);">{shareUrl ? 'Close' : 'Cancel'}</button>
		{#if !shareUrl}
			<button onclick={createShare} disabled={shareCreating} class="px-4 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-500 disabled:opacity-40 rounded-lg transition-all">
				{shareCreating ? 'Creating…' : 'Create Share Link'}
			</button>
		{/if}
	{/snippet}
</Modal>
{/if}

{#if showDeleteFolder && deleteFolderTarget}
<Modal title="Delete Folder" onclose={() => (showDeleteFolder = false)}>
	{#snippet children()}
		<div class="space-y-3">
			{#if deleteFolderHasSyncTask}
				<div class="flex items-start gap-3 p-3 rounded-lg border" style="background: rgba(245,158,11,0.08); border-color: rgba(245,158,11,0.20);">
					<span class="text-yellow-400 mt-0.5 flex-shrink-0">⚠</span>
					<div>
						<p class="text-sm font-medium text-yellow-300">This folder has an active sync task</p>
						<p class="text-sm mt-1" style="color: rgba(245,158,11,0.70);">If you delete this folder, the sync client will recreate it and re-upload all files on the next sync cycle.</p>
					</div>
				</div>
			{/if}
			<p class="text-sm" style="color: var(--text-secondary);">Are you sure you want to delete <span class="font-semibold text-[var(--text-primary)]">"{deleteFolderTarget.name}"</span> and all its contents?</p>
			<p class="text-xs" style="color: var(--text-tertiary);">This will move the folder and all files inside to the trash.</p>
		</div>
	{/snippet}
	{#snippet footer()}
		<button onclick={() => (showDeleteFolder = false)} class="px-4 py-2 text-sm font-medium text-[var(--text-secondary)] border rounded-lg hover:bg-white/5 transition-all" style="border-color: var(--border);">Cancel</button>
		<button onclick={confirmDeleteFolder} disabled={deletingFolder} class="px-4 py-2 text-sm font-medium rounded-lg transition-all bg-red-600/10 text-red-400 hover:bg-red-600/20 border border-red-500/20">
			{deletingFolder ? 'Deleting…' : 'Delete'}
		</button>
	{/snippet}
</Modal>
{/if}

{#if previewFile}
	<FilePreview file={previewFile} onclose={() => previewFile = null} />
{/if}

<style>
	.file-row {
		border-bottom: 1px solid var(--border);
	}
	.file-row:hover {
		background: var(--bg-hover);
	}
	.file-row:last-child {
		border-bottom: none;
	}
	.selected-row {
		background: rgba(59,130,246,0.08) !important;
		border-left: 2px solid #3b82f6;
	}

	.action-btn {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		font-size: 11px;
		font-weight: 500;
		padding: 4px 8px;
		border-radius: 6px;
		transition: all 0.15s;
		color: var(--text-secondary);
	}
	.action-btn:hover {
		background: var(--bg-active);
		color: var(--text-primary);
	}
	.action-btn-blue {
		color: #60a5fa;
	}
	.action-btn-blue:hover {
		background: rgba(59,130,246,0.12);
		color: #93c5fd;
	}
	.action-btn-purple {
		color: #c084fc;
	}
	.action-btn-purple:hover {
		background: rgba(168,85,247,0.12);
		color: #d8b4fe;
	}
	.action-btn-red {
		color: #f87171;
	}
	.action-btn-red:hover {
		background: rgba(239,68,68,0.12);
		color: #fca5a5;
	}

	/* Timeline dots */
	.version-dot {
		cursor: pointer;
	}
	.version-dot .dot-line {
		stroke: rgba(147,197,253,0.50);
		stroke-width: 1.5;
		transition: all 0.15s ease;
	}
	.version-dot .dot-circle {
		r: 3px;
		fill: rgba(147,197,253,0.60);
		transition: all 0.15s ease;
	}
	.version-dot:hover .dot-line {
		stroke: #3b82f6;
		stroke-width: 2;
	}
	.version-dot:hover .dot-circle {
		r: 5px;
		fill: #3b82f6;
	}
	.version-dot.selected .dot-line {
		stroke: #60a5fa;
		stroke-width: 2.5;
	}
	.version-dot.selected .dot-circle {
		r: 5px;
		fill: #60a5fa;
	}
	.version-dot.file-version .dot-line {
		stroke: #f59e0b;
		stroke-width: 2;
	}
	.version-dot.file-version .dot-circle {
		r: 4px;
		fill: #f59e0b;
	}
	.version-dot.file-version:hover .dot-line {
		stroke: #d97706;
		stroke-width: 2.5;
	}
	.version-dot.file-version:hover .dot-circle {
		r: 5px;
		fill: #d97706;
	}
	.version-dot.selected.file-version .dot-line {
		stroke: #d97706;
		stroke-width: 2.5;
	}
	.version-dot.selected.file-version .dot-circle {
		r: 5px;
		fill: #d97706;
	}
</style>
