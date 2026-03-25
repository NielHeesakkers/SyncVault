<script lang="ts">
	import { onMount } from 'svelte';
	import { Mail, Send, Save, Settings2, BookOpen, HardDrive, Code, Download, Upload, Trash2, PlugZap, Eraser, ChevronLeft, ChevronRight } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes, formatDate } from '$lib/utils';

	// Tab state
	let activeTab = $state('general');
	const tabs = [
		{ id: 'general', label: 'General', icon: Settings2 },
		{ id: 'notifications', label: 'Notifications', icon: Mail },
		{ id: 'backup', label: 'Backup', icon: HardDrive },
		{ id: 'cleanup', label: 'Cleanup', icon: Eraser },
		{ id: 'changelog', label: 'Changelog', icon: BookOpen },
		{ id: 'opensource', label: 'Info', icon: Code }
	];

	// General settings
	let baseUrl = $state('');
	let trashDays = $state('30');

	// SMTP
	let loading = $state(true);
	let saving = $state(false);
	let testing = $state(false);
	let testingConnection = $state(false);
	let connectionResult = $state<'idle' | 'success' | 'error'>('idle');
	let emailResult = $state<'idle' | 'success' | 'error'>('idle');
	let smtpEnabled = $state(false);
	let smtpHost = $state('');
	let smtpPort = $state('587');
	let smtpUser = $state('');
	let smtpPassword = $state('');
	let smtpFrom = $state('SyncVault <noreply@example.com>');
	let testEmailAddress = $state('');
	let showTestEmail = $state(false);

	// Backup
	interface BackupEntry {
		name: string;
		size: number;
		created_at: string;
	}
	let backups = $state<BackupEntry[]>([]);
	let backupLoading = $state(false);
	let backupCreating = $state(false);
	let backupAutoEnabled = $state(true);
	let backupInterval = $state('24');
	let backupIntervalUnit = $state('hours');

	// Changelog
	interface ChangelogVersion {
		version: string;
		date: string;
		changes: string[];
	}
	let currentVersion = $state('');
	let changelogVersions = $state<ChangelogVersion[]>([]);

	onMount(loadAll);

	async function loadAll() {
		loading = true;
		try {
			const [settingsRes, versionRes] = await Promise.all([
				api.get('/api/admin/settings'),
				api.get('/api/version')
			]);
			if (settingsRes.ok) {
				const data: Record<string, string> = await settingsRes.json();
				baseUrl = data['base_url'] || '';
				trashDays = data['trash_retention_days'] || '30';
				smtpEnabled = data['smtp.enabled'] === 'true' || data['smtp.enabled'] === '1';
				smtpHost = data['smtp.host'] || '';
				smtpPort = data['smtp.port'] || '587';
				smtpUser = data['smtp.user'] || '';
				smtpPassword = data['smtp.password'] || '';
				smtpFrom = data['smtp.from'] || 'SyncVault <noreply@example.com>';
				backupAutoEnabled = data['backup.auto_enabled'] !== 'false';
				backupInterval = data['backup.interval'] || '24';
				backupIntervalUnit = data['backup.interval_unit'] || 'hours';
			}
			if (versionRes.ok) {
				const data = await versionRes.json();
				currentVersion = data.current_version || data.version || '';
				changelogVersions = data.changelog || [];
			}
			loadBackups();
		} finally {
			loading = false;
		}
	}

	async function saveSettings() {
		saving = true;
		try {
			const payload: Record<string, string> = {
				'base_url': baseUrl,
				'trash_retention_days': trashDays,
				'smtp.enabled': smtpEnabled ? 'true' : 'false',
				'smtp.host': smtpHost,
				'smtp.port': smtpPort,
				'smtp.user': smtpUser,
				'smtp.password': smtpPassword,
				'smtp.from': smtpFrom,
				'backup.auto_enabled': backupAutoEnabled ? 'true' : 'false',
				'backup.interval': backupInterval,
				'backup.interval_unit': backupIntervalUnit
			};
			const res = await api.put('/api/admin/settings', payload);
			if (res.ok) showToast('Settings saved', 'success');
			else showToast('Failed to save', 'error');
		} finally {
			saving = false;
		}
	}

	function openTestEmail() {
		const user = api.getUser();
		testEmailAddress = user?.email || '';
		showTestEmail = true;
	}

	async function sendTestEmail() {
		testing = true;
		emailResult = 'idle';
		try {
			const res = await api.post('/api/admin/settings/test-email', { email: testEmailAddress });
			if (res.ok) {
				emailResult = 'success';
				showToast('Test email sent to ' + testEmailAddress, 'success');
			} else {
				emailResult = 'error';
				const data = await res.json().catch(() => ({}));
				showToast(data.error || 'Failed to send', 'error');
			}
		} catch {
			emailResult = 'error';
			showToast('Could not reach server', 'error');
		} finally {
			testing = false;
			setTimeout(() => { emailResult = 'idle'; }, 5000);
		}
	}

	async function testSmtpConnection() {
		testingConnection = true;
		connectionResult = 'idle';
		try {
			const res = await api.post('/api/admin/settings/test-smtp', {});
			const data = await res.json().catch(() => ({}));
			if (data.success) {
				connectionResult = 'success';
				showToast(`SMTP connection OK — ${data.host}:${data.port}`, 'success');
			} else {
				connectionResult = 'error';
				showToast(data.error || 'Connection failed', 'error');
			}
		} catch {
			connectionResult = 'error';
			showToast('Could not reach server', 'error');
		} finally {
			testingConnection = false;
			setTimeout(() => { connectionResult = 'idle'; }, 5000);
		}
	}

	async function loadBackups() {
		backupLoading = true;
		try {
			const res = await api.get('/api/admin/backups');
			if (res.ok) {
				const data = await res.json();
				backups = data.backups || [];
			}
		} catch { /* non-fatal */ }
		finally { backupLoading = false; }
	}

	async function createBackup() {
		backupCreating = true;
		try {
			const res = await api.post('/api/admin/backups', {});
			if (res.ok) {
				showToast('Backup created', 'success');
				loadBackups();
			} else {
				showToast('Failed to create backup', 'error');
			}
		} finally {
			backupCreating = false;
		}
	}

	async function downloadBackup(name: string) {
		const res = await api.get(`/api/admin/backups/${name}/download`);
		if (res.ok) {
			const blob = await res.blob();
			const url = URL.createObjectURL(blob);
			const a = document.createElement('a');
			a.href = url;
			a.download = name;
			a.click();
			URL.revokeObjectURL(url);
		} else {
			showToast('Failed to download backup', 'error');
		}
	}

	let fileInput: HTMLInputElement;

	async function uploadRestore(event: Event) {
		const input = event.target as HTMLInputElement;
		const file = input.files?.[0];
		if (!file) return;
		const formData = new FormData();
		formData.append('file', file);
		const res = await api.upload('/api/admin/backups/upload', formData);
		if (res.ok) {
			showToast('Backup uploaded and restored — reload to see changes', 'success');
			loadBackups();
		} else {
			showToast('Failed to upload backup', 'error');
		}
		input.value = '';
	}

	async function deleteBackup(name: string) {
		const res = await api.delete(`/api/admin/backups/${name}`);
		if (res.ok) {
			showToast('Backup deleted', 'success');
			backups = backups.filter(b => b.name !== name);
		} else {
			showToast('Failed to delete backup', 'error');
		}
	}

	async function restoreBackup(name: string) {
		if (!confirm('Restore this backup? Current settings will be overwritten.')) return;
		const res = await api.post(`/api/admin/backups/${name}/restore`, {});
		if (res.ok) {
			showToast('Backup restored — reload to see changes', 'success');
		} else {
			showToast('Failed to restore backup', 'error');
		}
	}

	// Cleanup
	// Calendar state
	interface CalendarMonths { [month: string]: number[] }
	let calendarData = $state<CalendarMonths>({});
	let calendarLoaded = $state(false);
	let calendarViewYear = $state(new Date().getFullYear());
	let calendarViewMonth = $state(new Date().getMonth()); // 0-indexed

	// Cleanup form state
	let cleanupSelectedDate = $state<string>(''); // YYYY-MM-DD
	let cleanupIncludeVersions = $state(true);
	let cleanupOnlyDeleted = $state(false);
	let cleanupConfirmText = $state('');
	let cleanupRunning = $state(false);

	// Preview state
	interface CleanupPreview { files_count: number; versions_count: number; total_bytes: number }
	let cleanupPreview = $state<CleanupPreview | null>(null);
	let cleanupPreviewLoading = $state(false);

	// Derived: calendar helpers
	function calendarMonthKey(year: number, month: number): string {
		return `${year}-${String(month + 1).padStart(2, '0')}`;
	}

	function daysInMonth(year: number, month: number): number {
		return new Date(year, month + 1, 0).getDate();
	}

	function firstDayOfMonth(year: number, month: number): number {
		// 0 = Sunday, adjusting to Monday-first (0 = Mon, 6 = Sun)
		const d = new Date(year, month, 1).getDay();
		return (d + 6) % 7;
	}

	function hasData(year: number, month: number, day: number): boolean {
		const key = calendarMonthKey(year, month);
		return (calendarData[key] || []).includes(day);
	}

	function isSelectedDate(year: number, month: number, day: number): boolean {
		const d = String(day).padStart(2, '0');
		const m = String(month + 1).padStart(2, '0');
		return cleanupSelectedDate === `${year}-${m}-${d}`;
	}

	function selectCalendarDay(year: number, month: number, day: number) {
		const d = String(day).padStart(2, '0');
		const m = String(month + 1).padStart(2, '0');
		cleanupSelectedDate = `${year}-${m}-${d}`;
		cleanupConfirmText = '';
		fetchCleanupPreview();
	}

	function prevMonth() {
		if (calendarViewMonth === 0) {
			calendarViewMonth = 11;
			calendarViewYear -= 1;
		} else {
			calendarViewMonth -= 1;
		}
	}

	function nextMonth() {
		if (calendarViewMonth === 11) {
			calendarViewMonth = 0;
			calendarViewYear += 1;
		} else {
			calendarViewMonth += 1;
		}
	}

	async function loadCalendar() {
		try {
			const res = await api.get('/api/admin/cleanup/calendar');
			if (res.ok) {
				const data = await res.json();
				calendarData = data.months || {};
			}
		} catch { /* non-fatal */ }
		finally { calendarLoaded = true; }
	}

	async function fetchCleanupPreview() {
		if (!cleanupSelectedDate) return;
		cleanupPreviewLoading = true;
		cleanupPreview = null;
		try {
			const params = new URLSearchParams({
				before_date: cleanupSelectedDate,
				include_versions: String(cleanupIncludeVersions),
				only_deleted: String(cleanupOnlyDeleted)
			});
			const res = await api.get(`/api/admin/cleanup/preview?${params}`);
			if (res.ok) {
				cleanupPreview = await res.json();
			}
		} catch { /* non-fatal */ }
		finally { cleanupPreviewLoading = false; }
	}

	async function runCleanup() {
		if (cleanupConfirmText !== 'DELETE') return;
		if (!cleanupSelectedDate) return;
		cleanupRunning = true;
		try {
			const res = await api.post('/api/admin/cleanup', {
				before_date: cleanupSelectedDate + 'T00:00:00Z',
				include_versions: cleanupIncludeVersions,
				only_deleted: cleanupOnlyDeleted
			});
			if (res.ok) {
				const data = await res.json();
				showToast(
					`Cleanup complete — ${data.deleted_files} files, ${data.deleted_versions} versions, ${formatBytes(data.freed_bytes)} freed`,
					'success'
				);
				cleanupSelectedDate = '';
				cleanupConfirmText = '';
				cleanupPreview = null;
				loadCalendar();
			} else {
				const data = await res.json().catch(() => ({}));
				showToast(data.error || 'Cleanup failed', 'error');
			}
		} catch {
			showToast('Could not reach server', 'error');
		} finally {
			cleanupRunning = false;
		}
	}

	// Load calendar when the cleanup tab is activated.
	$effect(() => {
		if (activeTab === 'cleanup' && !calendarLoaded) {
			loadCalendar();
		}
	});

	// Re-fetch preview when options change.
	$effect(() => {
		if (cleanupSelectedDate) {
			// Reactive dependency on the two checkboxes.
			cleanupIncludeVersions;
			cleanupOnlyDeleted;
			fetchCleanupPreview();
		}
	});

	const MONTH_NAMES = ['January','February','March','April','May','June','July','August','September','October','November','December'];
	const DAY_LABELS = ['Mo','Tu','We','Th','Fr','Sa','Su'];

	const openSourceLibs = [
		{ name: 'Go', url: 'https://go.dev', license: 'BSD-3-Clause', desc: 'Backend language' },
		{ name: 'Chi', url: 'https://github.com/go-chi/chi', license: 'MIT', desc: 'HTTP router' },
		{ name: 'SQLite (modernc)', url: 'https://pkg.go.dev/modernc.org/sqlite', license: 'BSD-3-Clause', desc: 'Database engine' },
		{ name: 'SvelteKit', url: 'https://kit.svelte.dev', license: 'MIT', desc: 'Frontend framework' },
		{ name: 'Tailwind CSS', url: 'https://tailwindcss.com', license: 'MIT', desc: 'CSS framework' },
		{ name: 'Lucide', url: 'https://lucide.dev', license: 'ISC', desc: 'Icon library' },
		{ name: 'Sparkle', url: 'https://sparkle-project.org', license: 'MIT', desc: 'macOS auto-update' },
		{ name: 'SQLite.swift', url: 'https://github.com/stephencelis/SQLite.swift', license: 'MIT', desc: 'Swift SQLite wrapper' },
	];
</script>

<svelte:head>
	<title>Settings — SyncVault Admin</title>
</svelte:head>

<div class="p-6 max-w-3xl" style="background: #0a0a0b; min-height: 100%;">
	<div class="mb-6">
		<h1 class="text-base font-semibold text-white">Settings</h1>
		<p class="text-sm mt-1" style="color: rgba(255,255,255,0.35);">Server configuration and system info.</p>
	</div>

	<!-- Tabs -->
	<div class="flex gap-0 border-b mb-6" style="border-color: rgba(255,255,255,0.06);">
		{#each tabs as tab}
			<button
				onclick={() => (activeTab = tab.id)}
				class="flex items-center gap-2 px-4 py-2.5 text-sm font-medium border-b-2 transition-colors -mb-px"
				style="{activeTab === tab.id ? 'border-color: #3b82f6; color: #60a5fa;' : 'border-color: transparent; color: rgba(255,255,255,0.40);'}"
			>
				<tab.icon size={14} />
				{tab.label}
			</button>
		{/each}
	</div>

	{#if loading}
		<div class="space-y-4">
			{#each [1,2] as _}
				<div class="rounded-xl border p-6" style="background: #111113; border-color: rgba(255,255,255,0.05);">
					<div class="skeleton h-4 rounded w-24 mb-4"></div>
					<div class="skeleton h-9 rounded w-full"></div>
				</div>
			{/each}
		</div>

	<!-- GENERAL -->
	{:else if activeTab === 'general'}
		<div class="space-y-4">
			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
				<div class="px-5 py-4 border-b" style="border-color: rgba(255,255,255,0.05);">
					<h3 class="text-sm font-semibold text-white/70">Server</h3>
				</div>
				<div class="px-5 py-4">
					<label class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.45);" for="base-url">Base URL</label>
					<input id="base-url" type="url" bind:value={baseUrl} placeholder="https://sync.example.com" />
					<p class="text-xs mt-1.5" style="color: rgba(255,255,255,0.30);">Used for share links. Leave empty to use the current browser URL.</p>
				</div>
			</div>

			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
				<div class="px-5 py-4 border-b" style="border-color: rgba(255,255,255,0.05);">
					<h3 class="text-sm font-semibold text-white/70">Trash</h3>
				</div>
				<div class="px-5 py-4">
					<label class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.45);" for="trash-days">Retention period (days)</label>
					<input id="trash-days" type="number" min="1" bind:value={trashDays} style="width: 120px;" />
					<p class="text-xs mt-1.5" style="color: rgba(255,255,255,0.30);">Files in trash are permanently deleted after this many days.</p>
				</div>
			</div>

			<div class="flex justify-end">
				<button onclick={saveSettings} disabled={saving}
					class="flex items-center gap-1.5 px-4 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-500 rounded-lg disabled:opacity-50 transition-all">
					<Save size={13} /> {saving ? 'Saving…' : 'Save'}
				</button>
			</div>
		</div>

	<!-- NOTIFICATIONS -->
	{:else if activeTab === 'notifications'}
		<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
			<div class="px-5 py-5 space-y-5">
				<div class="flex items-center justify-between">
					<div>
						<p class="text-sm font-medium text-white/70">Enable SMTP</p>
						<p class="text-xs mt-0.5" style="color: rgba(255,255,255,0.35);">Send emails for welcome, password reset, quota warnings</p>
					</div>
					<button role="switch" aria-checked={smtpEnabled}
						onclick={() => (smtpEnabled = !smtpEnabled)}
						class="relative inline-flex h-5 w-9 items-center rounded-full transition-colors flex-shrink-0"
						style="{smtpEnabled ? 'background: #3b82f6;' : 'background: rgba(255,255,255,0.12);'}">
						<span class="inline-block h-3.5 w-3.5 transform rounded-full bg-white shadow transition-transform {smtpEnabled ? 'translate-x-4' : 'translate-x-0.5'}"></span>
					</button>
				</div>
				<div class="border-t pt-5 space-y-3" style="border-color: rgba(255,255,255,0.06);">
					{#each [
						{ id: 'smtp-host', label: 'SMTP Host', value: smtpHost, placeholder: 'smtp.gmail.com', type: 'text' },
						{ id: 'smtp-port', label: 'SMTP Port', value: smtpPort, placeholder: '587', type: 'number' },
						{ id: 'smtp-user', label: 'SMTP User', value: smtpUser, placeholder: 'you@example.com', type: 'text' },
						{ id: 'smtp-password', label: 'SMTP Password', value: smtpPassword, placeholder: 'App password', type: 'password' },
						{ id: 'smtp-from', label: 'From Address', value: smtpFrom, placeholder: 'SyncVault <noreply@example.com>', type: 'text' }
					] as field}
						<div>
							<label class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.45);" for={field.id}>{field.label}</label>
							<input id={field.id} type={field.type} value={field.value} placeholder={field.placeholder}
								oninput={(e) => {
									const v = (e.target as HTMLInputElement).value;
									if (field.id === 'smtp-host') smtpHost = v;
									else if (field.id === 'smtp-port') smtpPort = v;
									else if (field.id === 'smtp-user') smtpUser = v;
									else if (field.id === 'smtp-password') smtpPassword = v;
									else if (field.id === 'smtp-from') smtpFrom = v;
								}} />
						</div>
					{/each}
				</div>
			</div>
			<div class="px-5 py-4 border-t flex items-center justify-between" style="border-color: rgba(255,255,255,0.05); background: rgba(255,255,255,0.02);">
				<div class="flex gap-2">
					<button onclick={testSmtpConnection} disabled={!smtpEnabled || testingConnection}
						class="flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium border transition-all duration-200 disabled:opacity-40"
						style="{connectionResult === 'success' ? 'border-color: rgba(34,197,94,0.30); background: rgba(34,197,94,0.12); color: #4ade80;' :
						 connectionResult === 'error' ? 'border-color: rgba(239,68,68,0.30); background: rgba(239,68,68,0.12); color: #f87171;' :
						 'border-color: rgba(255,255,255,0.10); color: rgba(255,255,255,0.60);'}">
						<PlugZap size={13} /> {testingConnection ? 'Testing…' : connectionResult === 'success' ? 'Connected!' : connectionResult === 'error' ? 'Failed' : 'Test Connection'}
					</button>
					<button onclick={openTestEmail} disabled={!smtpEnabled}
						class="flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium border transition-all duration-200 disabled:opacity-40"
						style="{emailResult === 'success' ? 'border-color: rgba(34,197,94,0.30); background: rgba(34,197,94,0.12); color: #4ade80;' :
						 emailResult === 'error' ? 'border-color: rgba(239,68,68,0.30); background: rgba(239,68,68,0.12); color: #f87171;' :
						 'border-color: rgba(255,255,255,0.10); color: rgba(255,255,255,0.60);'}">
						<Send size={13} /> {emailResult === 'success' ? 'Sent!' : emailResult === 'error' ? 'Failed' : 'Send Test Email'}
					</button>
				</div>
				<button onclick={saveSettings} disabled={saving}
					class="flex items-center gap-1.5 px-4 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-500 rounded-lg disabled:opacity-50 transition-all">
					<Save size={13} /> {saving ? 'Saving…' : 'Save'}
				</button>
			</div>
		</div>

		{#if showTestEmail}
		<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
		<div class="fixed inset-0 z-50 flex items-center justify-center" style="background: rgba(0,0,0,0.70); backdrop-filter: blur(4px);" onclick={() => (showTestEmail = false)}>
			<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
			<div class="rounded-xl shadow-2xl border p-6 w-96 space-y-4" style="background: #1a1a1d; border-color: rgba(255,255,255,0.10);" onclick={(e) => e.stopPropagation()}>
				<h3 class="text-base font-semibold text-white">Send Test Email</h3>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.45);" for="test-email">Email address</label>
					<input id="test-email" type="email" bind:value={testEmailAddress} placeholder="you@example.com" />
				</div>
				<div class="flex justify-end gap-2.5">
					<button onclick={() => (showTestEmail = false)} class="px-4 py-2 text-sm font-medium text-white/60 border rounded-lg hover:bg-white/5 transition-all" style="border-color: rgba(255,255,255,0.10);">Cancel</button>
					<button onclick={sendTestEmail} disabled={testing || !testEmailAddress}
						class="flex items-center gap-1.5 px-4 py-2 text-sm font-medium text-white rounded-lg disabled:opacity-50 transition-all duration-200"
						style="{emailResult === 'success' ? 'background: #22c55e;' : emailResult === 'error' ? 'background: #ef4444;' : 'background: #2563eb;'}">
						<Send size={13} /> {testing ? 'Sending…' : emailResult === 'success' ? 'Sent!' : emailResult === 'error' ? 'Failed' : 'Send'}
					</button>
				</div>
			</div>
		</div>
		{/if}

	<!-- BACKUP -->
	{:else if activeTab === 'backup'}
		<div class="space-y-4">
			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
				<div class="px-5 py-5">
					<div class="flex items-center justify-between mb-4">
						<div>
							<p class="text-sm font-medium text-white/70">Automatic backup</p>
							<p class="text-xs mt-0.5" style="color: rgba(255,255,255,0.35);">Creates a backup of all settings, users, teams, and metadata</p>
						</div>
						<button role="switch" aria-checked={backupAutoEnabled}
							onclick={() => { backupAutoEnabled = !backupAutoEnabled; saveSettings(); }}
							class="relative inline-flex h-5 w-9 items-center rounded-full transition-colors flex-shrink-0"
							style="{backupAutoEnabled ? 'background: #3b82f6;' : 'background: rgba(255,255,255,0.12);'}">
							<span class="inline-block h-3.5 w-3.5 transform rounded-full bg-white shadow transition-transform {backupAutoEnabled ? 'translate-x-4' : 'translate-x-0.5'}"></span>
						</button>
					</div>
					{#if backupAutoEnabled}
						<div class="flex items-center gap-2 mb-3">
							<label class="text-sm" style="color: rgba(255,255,255,0.50);">Every</label>
							<input type="number" min="1" bind:value={backupInterval} onchange={saveSettings} style="width: 80px;" />
							<select bind:value={backupIntervalUnit} onchange={saveSettings} style="width: auto;">
								<option value="hours">hours</option>
								<option value="days">days</option>
								<option value="weeks">weeks</option>
							</select>
						</div>
					{/if}
					<p class="text-xs" style="color: rgba(255,255,255,0.30);">Backups are stored in the Docker volume at <code class="font-mono px-1 rounded" style="background: rgba(255,255,255,0.06);">/data/backups/</code></p>
				</div>
				<div class="px-5 py-3 border-t flex justify-between items-center" style="border-color: rgba(255,255,255,0.05); background: rgba(255,255,255,0.02);">
					<span class="text-xs" style="color: rgba(255,255,255,0.35);">{backups.length} backup{backups.length !== 1 ? 's' : ''} available</span>
					<div class="flex items-center gap-2">
						<input type="file" accept=".zip" bind:this={fileInput} onchange={uploadRestore} class="hidden" />
						<button onclick={() => fileInput.click()}
							class="flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-white/60 border rounded-lg hover:bg-white/5 transition-all" style="border-color: rgba(255,255,255,0.10);">
							<Upload size={13} /> Restore from file
						</button>
						<button onclick={createBackup} disabled={backupCreating}
							class="flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-500 rounded-lg disabled:opacity-50 transition-all">
							<HardDrive size={13} /> {backupCreating ? 'Creating…' : 'Create Backup Now'}
						</button>
					</div>
				</div>
			</div>

			{#if backups.length > 0}
			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
				<table class="min-w-full">
					<thead>
						<tr style="border-bottom: 1px solid rgba(255,255,255,0.05);">
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Backup</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Size</th>
							<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Date</th>
							<th class="px-4 py-3 text-right text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Actions</th>
						</tr>
					</thead>
					<tbody>
						{#each backups as backup}
							<tr class="backup-row">
								<td class="px-4 py-3.5">
									<span class="text-sm font-medium text-white/70">{backup.name}</span>
								</td>
								<td class="px-4 py-3.5">
									<span class="text-sm" style="color: rgba(255,255,255,0.40);">{formatBytes(backup.size)}</span>
								</td>
								<td class="px-4 py-3.5">
									<span class="text-sm" style="color: rgba(255,255,255,0.40);">{formatDate(backup.created_at)}</span>
								</td>
								<td class="px-4 py-3.5">
									<div class="flex items-center justify-end gap-1">
										<button onclick={() => downloadBackup(backup.name)} title="Download"
											class="flex items-center gap-1 text-xs font-medium px-2 py-1 rounded-md transition-all text-blue-400 hover:bg-blue-500/10">
											<Download size={13} /> Download
										</button>
										<button onclick={() => restoreBackup(backup.name)} title="Restore"
											class="flex items-center gap-1 text-xs font-medium px-2 py-1 rounded-md transition-all text-white/50 hover:bg-white/5">
											<Upload size={13} /> Restore
										</button>
										<button onclick={() => deleteBackup(backup.name)} title="Delete"
											class="flex items-center gap-1 text-xs font-medium px-2 py-1 rounded-md transition-all text-red-400 hover:bg-red-500/10">
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
		</div>

	<!-- CLEANUP -->
	{:else if activeTab === 'cleanup'}
		<div class="space-y-4">
			<!-- Calendar -->
			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
				<div class="px-5 py-4 border-b" style="border-color: rgba(255,255,255,0.05);">
					<h3 class="text-sm font-semibold text-white/70">Select cutoff date</h3>
					<p class="text-xs mt-0.5" style="color: rgba(255,255,255,0.35);">Files and versions created <strong class="text-white/50">before</strong> the selected date will be deleted.</p>
				</div>
				<div class="px-5 py-4">
					<!-- Month navigation -->
					<div class="flex items-center justify-between mb-3">
						<button onclick={prevMonth} class="p-1 rounded hover:bg-white/5 transition-colors" style="color: rgba(255,255,255,0.50);">
							<ChevronLeft size={16} />
						</button>
						<span class="text-sm font-medium text-white/70">{MONTH_NAMES[calendarViewMonth]} {calendarViewYear}</span>
						<button onclick={nextMonth} class="p-1 rounded hover:bg-white/5 transition-colors" style="color: rgba(255,255,255,0.50);">
							<ChevronRight size={16} />
						</button>
					</div>

					<!-- Day-of-week headers -->
					<div class="grid grid-cols-7 gap-1 mb-1">
						{#each DAY_LABELS as lbl}
							<div class="text-center text-[10px] font-semibold py-1" style="color: rgba(255,255,255,0.25);">{lbl}</div>
						{/each}
					</div>

					<!-- Calendar grid -->
					{#key `${calendarViewYear}-${calendarViewMonth}`}
					<div class="grid grid-cols-7 gap-1">
						<!-- Leading empty cells -->
						{#each Array(firstDayOfMonth(calendarViewYear, calendarViewMonth)) as _}
							<div></div>
						{/each}
						<!-- Day cells -->
						{#each Array(daysInMonth(calendarViewYear, calendarViewMonth)) as _, i}
							{@const day = i + 1}
							{@const active = hasData(calendarViewYear, calendarViewMonth, day)}
							{@const selected = isSelectedDate(calendarViewYear, calendarViewMonth, day)}
							<button
								onclick={() => selectCalendarDay(calendarViewYear, calendarViewMonth, day)}
								class="calendar-day text-xs font-medium rounded-md py-1.5 transition-all"
								style="{selected
									? 'outline: 2px solid #3b82f6; outline-offset: -2px; background: rgba(59,130,246,0.20); color: #93c5fd;'
									: active
										? 'background: rgba(59,130,246,0.12); color: #93c5fd;'
										: 'color: rgba(255,255,255,0.25);'}"
							>{day}</button>
						{/each}
					</div>
					{/key}

					{#if cleanupSelectedDate}
						<p class="mt-3 text-xs" style="color: rgba(255,255,255,0.40);">
							Selected: <span class="font-semibold text-white/60">{cleanupSelectedDate}</span>
						</p>
					{/if}
				</div>
			</div>

			<!-- Options -->
			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
				<div class="px-5 py-4 space-y-3">
					<label class="flex items-center gap-3 cursor-pointer">
						<input type="checkbox" bind:checked={cleanupIncludeVersions} class="w-4 h-4 rounded accent-blue-500" />
						<div>
							<p class="text-sm font-medium text-white/70">Include old versions</p>
							<p class="text-xs" style="color: rgba(255,255,255,0.35);">Also delete stored file versions created before the cutoff date</p>
						</div>
					</label>
					<label class="flex items-center gap-3 cursor-pointer">
						<input type="checkbox" bind:checked={cleanupOnlyDeleted} class="w-4 h-4 rounded accent-blue-500" />
						<div>
							<p class="text-sm font-medium text-white/70">Only deleted files (trash)</p>
							<p class="text-xs" style="color: rgba(255,255,255,0.35);">Only target files that are already in the trash</p>
						</div>
					</label>
				</div>
			</div>

			<!-- Preview -->
			{#if cleanupSelectedDate}
			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
				<div class="px-5 py-4">
					<h3 class="text-sm font-semibold text-white/70 mb-2">Preview</h3>
					{#if cleanupPreviewLoading}
						<div class="flex items-center gap-2 text-sm" style="color: rgba(255,255,255,0.35);">
							<span class="animate-spin inline-block w-3 h-3 border-2 border-white/20 border-t-white/60 rounded-full"></span>
							Calculating…
						</div>
					{:else if cleanupPreview}
						<p class="text-sm" style="color: rgba(255,255,255,0.55);">
							<span class="font-semibold text-white/75">{cleanupPreview.files_count.toLocaleString()}</span> files,
							<span class="font-semibold text-white/75">{cleanupPreview.versions_count.toLocaleString()}</span> versions,
							<span class="font-semibold text-white/75">{formatBytes(cleanupPreview.total_bytes)}</span> will be deleted.
						</p>
					{:else}
						<p class="text-sm" style="color: rgba(255,255,255,0.35);">No data.</p>
					{/if}
				</div>
			</div>

			<!-- Confirmation -->
			<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(239,68,68,0.20);">
				<div class="px-5 py-4 space-y-3">
					<p class="text-sm font-semibold" style="color: #f87171;">Warning: Dangerous — data will be permanently wiped.</p>
					<div>
						<label class="block text-xs font-medium mb-1.5" style="color: rgba(255,255,255,0.45);" for="cleanup-confirm">Type DELETE to confirm</label>
						<input id="cleanup-confirm" type="text" bind:value={cleanupConfirmText} placeholder="DELETE" autocomplete="off" />
					</div>
					<button
						onclick={runCleanup}
						disabled={cleanupConfirmText !== 'DELETE' || cleanupRunning || !cleanupSelectedDate}
						class="flex items-center gap-1.5 px-4 py-2 text-sm font-medium text-white rounded-lg disabled:opacity-40 transition-all"
						style="background: #dc2626;"
					>
						<Eraser size={13} /> {cleanupRunning ? 'Cleaning up…' : 'Clean up'}
					</button>
				</div>
			</div>
			{/if}
		</div>

	<!-- CHANGELOG -->
	{:else if activeTab === 'changelog'}
		<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
			<div class="px-5 py-4 border-b" style="border-color: rgba(255,255,255,0.05);">
				<p class="text-sm" style="color: rgba(255,255,255,0.40);">Current version: <span class="font-semibold text-white/80">{currentVersion || 'unknown'}</span></p>
			</div>
			<div>
				{#if changelogVersions.length === 0}
					<div class="px-5 py-10 text-center text-sm" style="color: rgba(255,255,255,0.30);">No changelog available.</div>
				{:else}
					{#each changelogVersions as ver, i}
						<div class="px-5 py-4 {i < changelogVersions.length - 1 ? 'border-b' : ''}" style="border-color: rgba(255,255,255,0.05);">
							<div class="flex items-center gap-3 mb-2">
								<span class="text-sm font-bold text-white/80">v{ver.version}</span>
								<span class="text-xs" style="color: rgba(255,255,255,0.35);">{ver.date}</span>
							</div>
							<ul class="space-y-1">
								{#each ver.changes as change}
									<li class="text-sm flex items-start gap-2" style="color: rgba(255,255,255,0.55);">
										<span class="text-blue-400 mt-1 flex-shrink-0">•</span>
										{change}
									</li>
								{/each}
							</ul>
						</div>
					{/each}
				{/if}
			</div>
		</div>

	<!-- OPEN SOURCE -->
	{:else if activeTab === 'opensource'}
		<div class="rounded-xl border overflow-hidden mb-4" style="background: #111113; border-color: rgba(255,255,255,0.05);">
			<div class="px-5 py-5">
				<h3 class="text-sm font-semibold text-white/80 mb-2">About SyncVault</h3>
				<p class="text-sm" style="color: rgba(255,255,255,0.55);">SyncVault is an open-source file sync and backup solution, built as an alternative to Synology Drive.</p>
				<p class="text-sm mt-2" style="color: rgba(255,255,255,0.55);">Created by <span class="font-medium text-white/70">Niel Heesakkers</span> — vibe-coded with <a href="https://claude.ai" target="_blank" rel="noopener" class="text-blue-400 hover:text-blue-300 transition-colors">Claude</a> by Anthropic.</p>
				<p class="text-sm mt-3" style="color: rgba(255,255,255,0.40);">Version {currentVersion || 'unknown'}</p>
				<p class="text-sm mt-2" style="color: rgba(255,255,255,0.40);">Contact: <a href="mailto:development@heesakkers.com" class="text-blue-400 hover:text-blue-300 transition-colors">development@heesakkers.com</a></p>
			</div>
		</div>

		<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
			<div class="px-5 py-4 border-b" style="border-color: rgba(255,255,255,0.05);">
				<h3 class="text-sm font-semibold text-white/70">Open Source Libraries</h3>
			</div>
			<table class="min-w-full">
				<thead>
					<tr style="border-bottom: 1px solid rgba(255,255,255,0.05);">
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Library</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">License</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: rgba(255,255,255,0.30);">Used for</th>
					</tr>
				</thead>
				<tbody>
					{#each openSourceLibs as lib, i}
						<tr class="{i < openSourceLibs.length - 1 ? 'border-b' : ''}" style="border-color: rgba(255,255,255,0.04);">
							<td class="px-4 py-3.5">
								<a href={lib.url} target="_blank" rel="noopener" class="text-sm font-medium text-blue-400 hover:text-blue-300 transition-colors">{lib.name}</a>
							</td>
							<td class="px-4 py-3.5">
								<span class="text-[11px] font-mono px-2 py-0.5 rounded" style="background: rgba(255,255,255,0.06); color: rgba(255,255,255,0.45);">{lib.license}</span>
							</td>
							<td class="px-4 py-3.5 hidden sm:table-cell">
								<span class="text-sm" style="color: rgba(255,255,255,0.40);">{lib.desc}</span>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

<style>
	.backup-row {
		border-bottom: 1px solid rgba(255,255,255,0.04);
	}
	.backup-row:hover {
		background: rgba(255,255,255,0.02);
	}
	.backup-row:last-child {
		border-bottom: none;
	}
	.calendar-day {
		text-align: center;
	}
	.calendar-day:hover {
		background: rgba(255,255,255,0.06);
		color: rgba(255,255,255,0.70);
	}
</style>
