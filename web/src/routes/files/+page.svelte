<script lang="ts">
	import { onMount } from 'svelte';
	import { Clock, FolderOpen, FileText, Download, RotateCcw, Settings2, Share2, Copy, Check, Trash2 } from 'lucide-svelte';
	import Modal from '$lib/components/Modal.svelte';
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
		_isTeam?: boolean;
	}

	interface BreadcrumbItem {
		id: string | null;
		name: string;
	}

	let currentFolderId = $state<string | null>(null);
	let breadcrumbs = $state<BreadcrumbItem[]>([{ id: null, name: 'Files' }]);
	let files = $state<HistoryFile[]>([]);
	let changeDates = $state<string[]>([]);
	let loading = $state(false);
	let selectedDate = $state<string | null>(null);
	let selectedFile = $state<HistoryFile | null>(null);
	let selectedFileDates = $state<string[]>([]);

	// Timeline dimensions
	const TIMELINE_HEIGHT = 80;
	const TIMELINE_PADDING = 60;
	let timelineWidth = $state(900);
	let timelineContainer: HTMLDivElement;

	// Compute timeline range: 6 months back from today
	const today = new Date();
	const sixMonthsAgo = new Date(today);
	sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 6);
	sixMonthsAgo.setDate(1); // Start at first of month
	const rangeStart = sixMonthsAgo.getTime();
	const rangeEnd = today.getTime();
	const rangeDuration = rangeEnd - rangeStart;

	function dateToX(date: Date): number {
		const t = date.getTime();
		const ratio = (t - rangeStart) / rangeDuration;
		return TIMELINE_PADDING + ratio * (timelineWidth - 2 * TIMELINE_PADDING);
	}

	// Generate day/week/month tick marks
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

	// Generate version dots from changeDates
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
		// Save initial state
		history.replaceState({ folderId: currentFolderId, breadcrumbs: JSON.parse(JSON.stringify(breadcrumbs)) }, '');

		loadChangeDates(currentFolderId);

		// Handle browser back/forward
		const handlePopState = (e: PopStateEvent) => {
			if (e.state?.breadcrumbs) {
				breadcrumbs = e.state.breadcrumbs;
				currentFolderId = e.state.folderId;
				selectedFile = null;
				selectedFileDates = [];
				loadChangeDates(currentFolderId);
				if (selectedDate) loadHistory(currentFolderId, selectedDate);
			}
		};
		window.addEventListener('popstate', handlePopState);
		return () => window.removeEventListener('popstate', handlePopState);
	});

	async function loadChangeDates(folderId: string | null) {
		try {
			const path = folderId
				? `/api/files/history/dates?parent_id=${folderId}`
				: '/api/files/history/dates';
			const res = await api.get(path);
			if (res.ok) {
				const data = await res.json();
				changeDates = data.dates || [];
				if (!selectedDate) {
					// Always default to today so all current files/folders are visible
					selectDate(new Date().toISOString().slice(0, 10));
				}
			}
		} catch {
			// non-fatal
		}
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
				files = data.files || [];
			} else {
				showToast('Failed to load history', 'error');
			}

			// At root level, also load team folders
			if (!folderId) {
				try {
					const user = api.getUser();
					const teamEndpoint = user?.role === 'admin' ? '/api/teams' : '/api/teams/mine';
					const teamRes = await api.get(teamEndpoint);
					if (teamRes.ok) {
						const teamData = await teamRes.json();
						const teamList = teamData.teams || teamData || [];
						// Mark existing file folders that belong to teams
						const teamIds = new Set(teamList.map((t: any) => t.id));
						files = files.map((f: any) => {
							if (f.is_dir && f.name.startsWith('Team-') && !f._isTeam) {
								return { ...f, _isTeam: true };
							}
							return f;
						});

						// Only add team folders that aren't already in the files list
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
				} catch { /* non-fatal */ }
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

	async function navigateToFolder(file: HistoryFile) {
		selectedFile = null;
		selectedFileDates = [];
		breadcrumbs = [...breadcrumbs, { id: file.id, name: file.name }];
		currentFolderId = file.id;
		// Update URL without page reload
		const url = new URL(window.location.href);
		url.searchParams.set('folder', file.id);
		history.pushState({ folderId: file.id, breadcrumbs: JSON.parse(JSON.stringify(breadcrumbs)) }, '', url);

		loadChangeDates(file.id);
		if (selectedDate) loadHistory(file.id, selectedDate);
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
		loadChangeDates(crumb.id);
		if (selectedDate) loadHistory(crumb.id, selectedDate);
	}

	async function selectFile(file: HistoryFile) {
		if (selectedFile?.id === file.id) {
			// Deselect
			selectedFile = null;
			selectedFileDates = [];
			return;
		}
		selectedFile = file;
		// Load version dates for this file
		try {
			if (file.is_dir) {
				// For folders, load change dates scoped to this folder
				const res = await api.get(`/api/files/history/dates?parent_id=${file.id}`);
				if (res.ok) {
					const data = await res.json();
					selectedFileDates = data.dates || [];
				}
			} else {
				// For files, load versions and extract dates
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
		// Find the sync task for this folder
		try {
			const res = await api.get('/api/tasks');
			if (res.ok) {
				const tasks = await res.json();
				const task = tasks.find((t: any) => t.folder_id === file.id);
				if (task) {
					retentionTaskId = task.id;
					const retRes = await api.get(`/api/tasks/${task.id}/retention`);
					if (retRes.ok) {
						retention = await retRes.json();
					}
					showRetention = true;
				} else {
					showToast('No sync task found for this folder', 'error');
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
				} catch { /* use default */ }
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

		// Check if this folder has a sync task
		try {
			const res = await api.get(`/api/tasks?folder_id=${file.id}`);
			if (res.ok) {
				const data = await res.json();
				const tasks = data.tasks || [];
				deleteFolderHasSyncTask = tasks.length > 0;
			}
		} catch { /* non-fatal */ }

		showDeleteFolder = true;
	}

	async function confirmDeleteFolder() {
		if (!deleteFolderTarget) return;
		deletingFolder = true;
		try {
			const res = await api.del(`/api/files/${deleteFolderTarget.id}`);
			if (res.ok) {
				showToast(`"${deleteFolderTarget.name}" deleted`, 'success');
				showDeleteFolder = false;
				deleteFolderTarget = null;
				loadHistory();
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
</script>

<svelte:head>
	<title>Files — SyncVault</title>
</svelte:head>

<div class="h-full flex flex-col">
	<!-- Top bar -->
	<div class="px-6 py-4 bg-white border-b border-gray-200">
		<div class="flex items-center justify-between">
			<div class="flex items-center gap-3">
				<FolderOpen size={22} class="text-blue-500 flex-shrink-0" />
				<h1 class="text-lg font-semibold text-gray-900">Files</h1>
				{#if selectedDate}
					<span class="text-sm text-gray-500">— {formatSelectedDate(selectedDate)}</span>
				{/if}
			</div>
		</div>
	</div>

	<!-- Breadcrumb bar -->
	<div class="px-6 py-2 bg-gray-50 border-b border-gray-100">
		<BreadcrumbNav items={breadcrumbs} onclick={navigateToBreadcrumb} />
	</div>

	<!-- File list -->
	<div class="flex-1 overflow-auto p-6">
		{#if !selectedDate && changeDates.length === 0}
			<div class="text-center py-24 text-gray-400">
				<Clock size={56} class="mx-auto mb-4 opacity-30" />
				<p class="text-base font-medium">No version history found</p>
				<p class="text-sm mt-1">Upload and modify files to start building version history.</p>
			</div>
		{:else if !selectedDate}
			<div class="text-center py-24 text-gray-400">
				<Clock size={56} class="mx-auto mb-4 opacity-30" />
				<p class="text-base font-medium">Select a point on the timeline below</p>
				<p class="text-sm mt-1">Click a blue dot to see files as they were on that date.</p>
			</div>
		{:else if loading}
			<div class="flex items-center justify-center py-24">
				<div class="w-8 h-8 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
			</div>
		{:else if files.length === 0}
			<div class="text-center py-24 text-gray-400">
				<Clock size={56} class="mx-auto mb-4 opacity-30" />
				<p class="text-base font-medium">No files at this point in time</p>
				<p class="text-sm mt-1">Try a different date on the timeline.</p>
			</div>
		{:else}
			{@const userFiles = breadcrumbs.length <= 1 ? files.filter(f => !f._isTeam) : files}
			{@const teamFiles = breadcrumbs.length <= 1 ? files.filter(f => f._isTeam) : []}

			{#if breadcrumbs.length <= 1 && userFiles.length > 0}
				<p class="px-1 mb-2 text-xs font-semibold uppercase tracking-wider text-gray-400">Users</p>
			{/if}

			{#if userFiles.length > 0}
			<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
				<table class="min-w-full divide-y divide-gray-200">
					<thead class="bg-gray-50">
						<tr>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider w-8"></th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Name</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden sm:table-cell">Size</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Version</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Date</th>
							<th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Actions</th>
						</tr>
					</thead>
					<tbody class="bg-white divide-y divide-gray-200">
						{#each userFiles as file}
							<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
							<tr
								class="hover:bg-gray-50 transition-colors cursor-pointer {selectedFile?.id === file.id ? 'bg-blue-50' : ''}"
								onclick={() => selectFile(file)}
								ondblclick={() => { if (file.is_dir) navigateToFolder(file); }}
							>
								<td class="px-4 py-3">
									{#if file.is_dir && file._isTeam}
										<FolderOpen size={20} class="text-blue-500" />
									{:else if file.is_dir}
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
										{formatBytes(file.size)}
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
									<div class="flex items-center gap-2 justify-end">
										{#if file.is_dir}
											{#if breadcrumbs.length <= 2}
												<button
													onclick={(e) => { e.stopPropagation(); openRetention(file); }}
													title="Retention policy"
													class="flex items-center gap-1 text-xs text-gray-600 hover:text-gray-800 font-medium px-2 py-1 rounded hover:bg-gray-100 transition-colors"
												>
													<Settings2 size={13} /> Retention
												</button>
											{/if}
											<button
												onclick={(e) => { e.stopPropagation(); openShare(file); }}
												title="Share folder"
												class="flex items-center gap-1 text-xs text-purple-600 hover:text-purple-800 font-medium px-2 py-1 rounded hover:bg-purple-50 transition-colors"
											>
												<Share2 size={13} /> Share
											</button>
											<button
												onclick={(e) => { e.stopPropagation(); downloadFolder(file); }}
												title="Download folder as ZIP"
												class="flex items-center gap-1 text-xs text-blue-600 hover:text-blue-800 font-medium px-2 py-1 rounded hover:bg-blue-50 transition-colors"
											>
												<Download size={13} /> Download
											</button>
											<button
												onclick={(e) => { e.stopPropagation(); restoreFolder(file); }}
												title="Restore all files in folder"
												class="flex items-center gap-1 text-xs text-gray-600 hover:text-gray-800 font-medium px-2 py-1 rounded hover:bg-gray-100 transition-colors"
											>
												<RotateCcw size={13} /> Restore
											</button>
											<button
												onclick={(e) => { e.stopPropagation(); openDeleteFolder(file); }}
												title="Delete folder"
												class="flex items-center gap-1 text-xs text-red-500 hover:text-red-700 font-medium px-2 py-1 rounded hover:bg-red-50 transition-colors"
											>
												<Trash2 size={13} /> Delete
											</button>
										{:else}
											<button
												onclick={(e) => { e.stopPropagation(); openShare(file); }}
												title="Share file"
												class="flex items-center gap-1 text-xs text-purple-600 hover:text-purple-800 font-medium px-2 py-1 rounded hover:bg-purple-50 transition-colors"
											>
												<Share2 size={13} /> Share
											</button>
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
				<p class="px-1 mt-6 mb-2 text-xs font-semibold uppercase tracking-wider text-gray-400">Team Folders</p>
				<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
					<table class="min-w-full divide-y divide-gray-200">
						<thead class="bg-gray-50">
							<tr>
								<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider w-8"></th>
								<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Name</th>
								<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden sm:table-cell">Size</th>
								<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Version</th>
								<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Date</th>
								<th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Actions</th>
							</tr>
						</thead>
						<tbody class="bg-white divide-y divide-gray-200">
							{#each teamFiles as file}
								<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
								<tr
									class="hover:bg-gray-50 transition-colors cursor-pointer {selectedFile?.id === file.id ? 'bg-blue-50' : ''}"
									onclick={() => selectFile(file)}
									ondblclick={() => navigateToFolder(file)}
								>
									<td class="px-4 py-3">
										<FolderOpen size={20} class="text-blue-500" />
									</td>
									<td class="px-4 py-3">
										<span class="text-sm font-medium text-gray-900">{file.name.replace('Team-', '')}</span>
									</td>
									<td class="px-4 py-3 hidden sm:table-cell">
										<span class="text-sm text-gray-500">{file.size ? formatBytes(file.size) : '—'}</span>
									</td>
									<td class="px-4 py-3 hidden md:table-cell">
										<span class="text-gray-400 text-sm">—</span>
									</td>
									<td class="px-4 py-3 hidden md:table-cell">
										<span class="text-sm text-gray-500">{formatDate(file.updated_at)}</span>
									</td>
									<td class="px-4 py-3">
										<div class="flex items-center gap-2 justify-end">
											<button
												onclick={(e) => { e.stopPropagation(); openShare(file); }}
												title="Share"
												class="flex items-center gap-1 text-xs text-purple-600 hover:text-purple-800 font-medium px-2 py-1 rounded hover:bg-purple-50 transition-colors"
											>
												<Share2 size={13} /> Share
											</button>
											<button
												onclick={(e) => { e.stopPropagation(); downloadFolder(file); }}
												title="Download"
												class="flex items-center gap-1 text-xs text-blue-600 hover:text-blue-800 font-medium px-2 py-1 rounded hover:bg-blue-50 transition-colors"
											>
												<Download size={13} /> Download
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

	<!-- Timeline -->
	<div class="bg-white border-t border-gray-200 px-4 py-2" bind:this={timelineContainer}>
		<svg width="100%" height={TIMELINE_HEIGHT} class="select-none">
			<!-- Base line -->
			<line
				x1={TIMELINE_PADDING}
				y1={TIMELINE_HEIGHT - 16}
				x2={timelineWidth - TIMELINE_PADDING}
				y2={TIMELINE_HEIGHT - 16}
				stroke="#e5e7eb"
				stroke-width="1"
			/>

			<!-- Day / Week / Month ticks -->
			{#each ticks as tick}
				{#if tick.isMonth}
					<!-- Month tick: tallest + label -->
					<line
						x1={tick.x}
						y1={TIMELINE_HEIGHT - 16}
						x2={tick.x}
						y2={TIMELINE_HEIGHT - 48}
						stroke="#9ca3af"
						stroke-width="1"
					/>
					<text
						x={tick.x}
						y={TIMELINE_HEIGHT - 52}
						text-anchor="middle"
						class="text-[10px] fill-gray-500 font-medium"
					>{tick.label}</text>
				{:else if tick.isWeek}
					<!-- Week tick: medium -->
					<line
						x1={tick.x}
						y1={TIMELINE_HEIGHT - 16}
						x2={tick.x}
						y2={TIMELINE_HEIGHT - 34}
						stroke="#d1d5db"
						stroke-width="0.5"
					/>
				{:else}
					<!-- Day tick: short -->
					<line
						x1={tick.x}
						y1={TIMELINE_HEIGHT - 16}
						x2={tick.x}
						y2={TIMELINE_HEIGHT - 24}
						stroke="#e5e7eb"
						stroke-width="0.5"
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
					<!-- Blue version line -->
					<line
						class="dot-line"
						x1={dot.x}
						y1={TIMELINE_HEIGHT - 16}
						x2={dot.x}
						y2={TIMELINE_HEIGHT - 38}
					/>
					<!-- Clickable dot -->
					<circle
						class="dot-circle"
						cx={dot.x}
						cy={TIMELINE_HEIGHT - 40}
						stroke="none"
					>
						<title>{dot.date}</title>
					</circle>
				</g>

				<!-- Date label for selected dot -->
				{#if dot.isSelected}
					<text
						x={dot.x}
						y={TIMELINE_HEIGHT - 52}
						text-anchor="middle"
						class="text-[10px] fill-blue-600 font-semibold"
					>{dot.date.slice(5)}</text>
				{/if}
			{/each}
		</svg>
	</div>
</div>

{#if showRetention}
<Modal title="Retention Policy — {retentionFolder?.name}" onclose={() => (showRetention = false)}>
	<div class="space-y-3">
		<p class="text-sm text-gray-500">Set how long versions are kept. Use 0 for unlimited.</p>
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
					<span class="text-sm font-medium text-gray-700">{field.label}</span>
					<span class="text-xs text-gray-400 ml-1">— {field.desc}</span>
				</div>
				<div class="flex items-center gap-2 w-28">
					<input type="number" min="0" bind:value={retention[field.key]}
						class="w-20 rounded-md border border-gray-300 px-3 py-1.5 text-sm text-right focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
					{#if field.unit}
						<span class="text-xs text-gray-400 w-12">{field.unit}</span>
					{/if}
				</div>
			</div>
		{/each}
		<div class="flex justify-end gap-3 pt-3 border-t border-gray-100">
			<button onclick={() => (showRetention = false)}
				class="px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 rounded-md hover:bg-gray-50">
				Cancel
			</button>
			<button onclick={saveRetention} disabled={retentionSaving}
				class="px-4 py-2 text-sm font-medium text-white bg-blue-500 rounded-md hover:bg-blue-600 disabled:opacity-50">
				{retentionSaving ? 'Saving…' : 'Save'}
			</button>
		</div>
	</div>
</Modal>
{/if}

{#if showShare}
<Modal title="Share" onclose={() => (showShare = false)}>
	<div class="space-y-3">
		<div>
			<span class="text-sm font-medium text-gray-700">Name</span>
			<input type="text" bind:value={shareName}
				class="mt-1 block w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
		</div>
		{#if shareUrl}
			<div>
				<span class="text-sm font-medium text-gray-700">Share URL</span>
				<div class="flex items-center gap-2 mt-1">
					<input type="text" readonly value={shareUrl}
						class="flex-1 rounded-md border border-gray-300 bg-gray-50 px-3 py-2 text-sm text-gray-700 select-all" />
					<button onclick={copyShareUrl}
						class="flex items-center gap-1 px-3 py-2 text-sm font-medium rounded-md transition-colors
						{shareCopied ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-700 hover:bg-gray-200'}">
						{#if shareCopied}
							<Check size={14} /> Copied
						{:else}
							<Copy size={14} /> Copy
						{/if}
					</button>
				</div>
			</div>
		{/if}
		<div>
			<span class="text-sm font-medium text-gray-700">Password</span>
			<span class="text-xs text-gray-400 ml-1">— optional</span>
			<input type="text" bind:value={sharePassword} placeholder="Leave empty for no password"
				class="mt-1 block w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
		</div>
		<div>
			<span class="text-sm font-medium text-gray-700">Expiry date</span>
			<span class="text-xs text-gray-400 ml-1">— optional</span>
			<input type="datetime-local" bind:value={shareExpiry}
				class="mt-1 block w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
		</div>
		<div>
			<span class="text-sm font-medium text-gray-700">Max downloads</span>
			<span class="text-xs text-gray-400 ml-1">— 0 = unlimited</span>
			<input type="number" min="0" bind:value={shareMaxDownloads}
				class="mt-1 block w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
		</div>
		<div class="flex items-center gap-3">
			<input type="checkbox" id="notify-download" bind:checked={shareNotifyOnDownload}
				class="rounded border-gray-300 text-blue-500 focus:ring-blue-500" />
			<label for="notify-download" class="text-sm text-gray-700">Email me when someone downloads</label>
		</div>
		<div class="flex justify-end gap-3 pt-3 border-t border-gray-100">
			<button onclick={() => (showShare = false)}
				class="px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 rounded-md hover:bg-gray-50">
				{shareUrl ? 'Close' : 'Cancel'}
			</button>
			{#if !shareUrl}
				<button onclick={createShare} disabled={shareCreating}
					class="px-4 py-2 text-sm font-medium text-white bg-blue-500 rounded-md hover:bg-blue-600 disabled:opacity-50">
					{shareCreating ? 'Creating…' : 'Create Share Link'}
				</button>
			{/if}
		</div>
	</div>
</Modal>
{/if}

{#if showDeleteFolder && deleteFolderTarget}
<Modal title="Delete Folder" onclose={() => (showDeleteFolder = false)}>
	{#snippet children()}
		<div class="space-y-3">
			{#if deleteFolderHasSyncTask}
				<div class="flex items-start gap-3 p-3 bg-amber-50 border border-amber-200 rounded-lg">
					<div class="text-amber-600 mt-0.5">⚠️</div>
					<div>
						<p class="text-sm font-medium text-amber-800">This folder has an active sync task</p>
						<p class="text-sm text-amber-700 mt-1">If you delete this folder, the sync client will recreate it and re-upload all files on the next sync cycle.</p>
					</div>
				</div>
			{/if}
			<p class="text-sm text-gray-600">Are you sure you want to delete <span class="font-semibold">"{deleteFolderTarget.name}"</span> and all its contents?</p>
			<p class="text-xs text-gray-400">This will move the folder and all files inside to the trash.</p>
		</div>
	{/snippet}
	{#snippet footer()}
		<button onclick={() => (showDeleteFolder = false)}
			class="px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 rounded-md hover:bg-gray-50">Cancel</button>
		<button onclick={confirmDeleteFolder} disabled={deletingFolder}
			class="px-4 py-2 text-sm font-medium text-white bg-red-500 rounded-md hover:bg-red-600 disabled:opacity-50">
			{deletingFolder ? 'Deleting…' : 'Delete'}
		</button>
	{/snippet}
</Modal>
{/if}

<style>
	.version-dot {
		cursor: pointer;
	}

	.version-dot .dot-line {
		stroke: #93c5fd;
		stroke-width: 1.5;
		transition: all 0.15s ease;
	}

	.version-dot .dot-circle {
		r: 3px;
		fill: #93c5fd;
		transition: all 0.15s ease;
	}

	/* Hover: bigger and darker */
	.version-dot:hover .dot-line {
		stroke: #2563eb;
		stroke-width: 2;
	}

	.version-dot:hover .dot-circle {
		r: 5px;
		fill: #2563eb;
	}

	/* Selected date: biggest and darkest */
	.version-dot.selected .dot-line {
		stroke: #1d4ed8;
		stroke-width: 2.5;
	}

	.version-dot.selected .dot-circle {
		r: 5px;
		fill: #1d4ed8;
	}

	/* File version highlight: orange */
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

	/* Selected + file version: orange stays dominant */
	.version-dot.selected.file-version .dot-line {
		stroke: #d97706;
		stroke-width: 2.5;
	}

	.version-dot.selected.file-version .dot-circle {
		r: 5px;
		fill: #d97706;
	}
</style>
