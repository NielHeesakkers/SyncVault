<script lang="ts">
	import { onMount } from 'svelte';
	import { Mail, Send, Save, Settings2, BookOpen, HardDrive, Code, Download, Upload, Trash2 } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes, formatDate } from '$lib/utils';

	// Tab state
	let activeTab = $state('general');
	const tabs = [
		{ id: 'general', label: 'General', icon: Settings2 },
		{ id: 'notifications', label: 'Notifications', icon: Mail },
		{ id: 'backup', label: 'Backup', icon: HardDrive },
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
			}
			if (versionRes.ok) {
				const data = await versionRes.json();
				currentVersion = data.version || '';
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
				'backup.auto_enabled': backupAutoEnabled ? 'true' : 'false'
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
		try {
			const res = await api.post('/api/admin/settings/test-email', { email: testEmailAddress });
			if (res.ok) {
				showToast('Test email sent to ' + testEmailAddress, 'success');
				showTestEmail = false;
			} else {
				const data = await res.json().catch(() => ({}));
				showToast(data.error || 'Failed to send', 'error');
			}
		} finally {
			testing = false;
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

<div class="p-6 max-w-3xl">
	<div class="mb-6">
		<h1 class="text-xl font-semibold text-gray-900">Settings</h1>
		<p class="text-sm text-gray-500 mt-1">Server configuration and system info.</p>
	</div>

	<!-- Tabs -->
	<div class="flex gap-1 border-b border-gray-200 mb-6">
		{#each tabs as tab}
			<button
				onclick={() => (activeTab = tab.id)}
				class="flex items-center gap-2 px-4 py-2.5 text-sm font-medium border-b-2 transition-colors -mb-px
				{activeTab === tab.id
					? 'border-blue-500 text-blue-600'
					: 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}"
			>
				<tab.icon size={15} />
				{tab.label}
			</button>
		{/each}
	</div>

	{#if loading}
		<div class="flex items-center justify-center py-16">
			<div class="w-7 h-7 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
		</div>

	<!-- GENERAL -->
	{:else if activeTab === 'general'}
		<div class="space-y-6">
			<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
				<div class="px-6 py-4 border-b border-gray-100">
					<h3 class="text-sm font-semibold text-gray-800">Server</h3>
				</div>
				<div class="px-6 py-5">
					<label class="block text-sm font-medium text-gray-700 mb-1" for="base-url">Base URL</label>
					<input id="base-url" type="text" bind:value={baseUrl} placeholder="https://sync.example.com"
						class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
					<p class="text-xs text-gray-400 mt-1">Used for share links. Leave empty to use the current browser URL.</p>
				</div>
			</div>

			<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
				<div class="px-6 py-4 border-b border-gray-100">
					<h3 class="text-sm font-semibold text-gray-800">Trash</h3>
				</div>
				<div class="px-6 py-5">
					<label class="block text-sm font-medium text-gray-700 mb-1" for="trash-days">Retention period (days)</label>
					<input id="trash-days" type="number" min="1" bind:value={trashDays}
						class="w-32 rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
					<p class="text-xs text-gray-400 mt-1">Files in trash are permanently deleted after this many days.</p>
				</div>
			</div>

			<div class="flex justify-end">
				<button onclick={saveSettings} disabled={saving}
					class="flex items-center gap-1 px-4 py-2 text-sm font-medium text-white bg-blue-500 rounded-md hover:bg-blue-600 disabled:opacity-50">
					<Save size={14} /> {saving ? 'Saving…' : 'Save'}
				</button>
			</div>
		</div>

	<!-- NOTIFICATIONS -->
	{:else if activeTab === 'notifications'}
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
			<div class="px-6 py-5 space-y-5">
				<div class="flex items-center justify-between">
					<div>
						<p class="text-sm font-medium text-gray-700">Enable SMTP</p>
						<p class="text-xs text-gray-500 mt-0.5">Send emails for welcome, password reset, quota warnings</p>
					</div>
					<button role="switch" aria-checked={smtpEnabled}
						onclick={() => (smtpEnabled = !smtpEnabled)}
						class="relative inline-flex h-6 w-11 items-center rounded-full transition-colors {smtpEnabled ? 'bg-blue-500' : 'bg-gray-200'}">
						<span class="inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform {smtpEnabled ? 'translate-x-6' : 'translate-x-1'}"></span>
					</button>
				</div>
				<div class="border-t border-gray-100 pt-5 space-y-4">
					{#each [
						{ id: 'smtp-host', label: 'SMTP Host', value: smtpHost, placeholder: 'smtp.gmail.com', type: 'text' },
						{ id: 'smtp-port', label: 'SMTP Port', value: smtpPort, placeholder: '587', type: 'number' },
						{ id: 'smtp-user', label: 'SMTP User', value: smtpUser, placeholder: 'you@example.com', type: 'text' },
						{ id: 'smtp-password', label: 'SMTP Password', value: smtpPassword, placeholder: 'App password', type: 'password' },
						{ id: 'smtp-from', label: 'From Address', value: smtpFrom, placeholder: 'SyncVault <noreply@example.com>', type: 'text' }
					] as field}
						<div>
							<label class="block text-sm font-medium text-gray-700 mb-1" for={field.id}>{field.label}</label>
							<input id={field.id} type={field.type} value={field.value} placeholder={field.placeholder}
								oninput={(e) => {
									const v = (e.target as HTMLInputElement).value;
									if (field.id === 'smtp-host') smtpHost = v;
									else if (field.id === 'smtp-port') smtpPort = v;
									else if (field.id === 'smtp-user') smtpUser = v;
									else if (field.id === 'smtp-password') smtpPassword = v;
									else if (field.id === 'smtp-from') smtpFrom = v;
								}}
								class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
						</div>
					{/each}
				</div>
			</div>
			<div class="px-6 py-4 border-t border-gray-100 bg-gray-50 flex items-center justify-between">
				<button onclick={openTestEmail} disabled={!smtpEnabled}
					class="flex items-center gap-2 rounded-md px-4 py-2 text-sm font-medium border border-gray-300 bg-white hover:bg-gray-50 disabled:opacity-50 text-gray-700">
					<Send size={15} /> Send Test Email
				</button>
				<button onclick={saveSettings} disabled={saving}
					class="flex items-center gap-1 px-4 py-2 text-sm font-medium text-white bg-blue-500 rounded-md hover:bg-blue-600 disabled:opacity-50">
					<Save size={14} /> {saving ? 'Saving…' : 'Save'}
				</button>
			</div>
		</div>

		{#if showTestEmail}
		<div class="fixed inset-0 z-50 flex items-center justify-center bg-black/30" onclick={() => (showTestEmail = false)}>
			<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
			<div class="bg-white rounded-lg shadow-xl p-6 w-96 space-y-4" onclick={(e) => e.stopPropagation()}>
				<h3 class="text-lg font-semibold text-gray-900">Send Test Email</h3>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1" for="test-email">Email address</label>
					<input id="test-email" type="email" bind:value={testEmailAddress} placeholder="you@example.com"
						class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
				<div class="flex justify-end gap-3">
					<button onclick={() => (showTestEmail = false)}
						class="px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 rounded-md hover:bg-gray-50">Cancel</button>
					<button onclick={sendTestEmail} disabled={testing || !testEmailAddress}
						class="flex items-center gap-1 px-4 py-2 text-sm font-medium text-white bg-blue-500 rounded-md hover:bg-blue-600 disabled:opacity-50">
						<Send size={14} /> {testing ? 'Sending…' : 'Send'}
					</button>
				</div>
			</div>
		</div>
		{/if}

	<!-- BACKUP -->
	{:else if activeTab === 'backup'}
		<div class="space-y-4">
			<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
				<div class="px-6 py-5">
					<div class="flex items-center justify-between mb-4">
						<div>
							<p class="text-sm font-medium text-gray-700">Automatic daily backup</p>
							<p class="text-xs text-gray-500 mt-0.5">Creates a backup of all settings, users, teams, and metadata daily</p>
						</div>
						<button role="switch" aria-checked={backupAutoEnabled}
							onclick={() => { backupAutoEnabled = !backupAutoEnabled; saveSettings(); }}
							class="relative inline-flex h-6 w-11 items-center rounded-full transition-colors {backupAutoEnabled ? 'bg-blue-500' : 'bg-gray-200'}">
							<span class="inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform {backupAutoEnabled ? 'translate-x-6' : 'translate-x-1'}"></span>
						</button>
					</div>
					<p class="text-xs text-gray-400">Backups are stored in the Docker volume at <code class="bg-gray-100 px-1 rounded">/data/backups/</code></p>
				</div>
				<div class="px-6 py-3 border-t border-gray-100 bg-gray-50 flex justify-between items-center">
					<span class="text-xs text-gray-500">{backups.length} backup{backups.length !== 1 ? 's' : ''} available</span>
					<div class="flex items-center gap-2">
						<input type="file" accept=".zip" bind:this={fileInput} onchange={uploadRestore} class="hidden" />
						<button onclick={() => fileInput.click()}
							class="flex items-center gap-1 px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 rounded-md hover:bg-gray-50">
							<Upload size={14} /> Restore from file
						</button>
						<button onclick={createBackup} disabled={backupCreating}
							class="flex items-center gap-1 px-4 py-2 text-sm font-medium text-white bg-blue-500 rounded-md hover:bg-blue-600 disabled:opacity-50">
							<HardDrive size={14} /> {backupCreating ? 'Creating…' : 'Create Backup Now'}
						</button>
					</div>
				</div>
			</div>

			{#if backups.length > 0}
			<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
				<table class="min-w-full divide-y divide-gray-200">
					<thead class="bg-gray-50">
						<tr>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Backup</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Size</th>
							<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Date</th>
							<th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Actions</th>
						</tr>
					</thead>
					<tbody class="bg-white divide-y divide-gray-200">
						{#each backups as backup}
							<tr class="hover:bg-gray-50">
								<td class="px-4 py-3">
									<span class="text-sm font-medium text-gray-900">{backup.name}</span>
								</td>
								<td class="px-4 py-3">
									<span class="text-sm text-gray-500">{formatBytes(backup.size)}</span>
								</td>
								<td class="px-4 py-3">
									<span class="text-sm text-gray-500">{formatDate(backup.created_at)}</span>
								</td>
								<td class="px-4 py-3">
									<div class="flex items-center justify-end gap-2">
										<button onclick={() => downloadBackup(backup.name)} title="Download"
											class="flex items-center gap-1 text-xs text-blue-600 hover:text-blue-800 font-medium px-2 py-1 rounded hover:bg-blue-50">
											<Download size={13} /> Download
										</button>
										<button onclick={() => restoreBackup(backup.name)} title="Restore"
											class="flex items-center gap-1 text-xs text-gray-600 hover:text-gray-800 font-medium px-2 py-1 rounded hover:bg-gray-100">
											<Upload size={13} /> Restore
										</button>
										<button onclick={() => deleteBackup(backup.name)} title="Delete"
											class="flex items-center gap-1 text-xs text-red-500 hover:text-red-700 font-medium px-2 py-1 rounded hover:bg-red-50">
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

	<!-- CHANGELOG -->
	{:else if activeTab === 'changelog'}
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
			<div class="px-6 py-4 border-b border-gray-100">
				<p class="text-sm text-gray-500">Current version: <span class="font-semibold text-gray-900">{currentVersion || 'unknown'}</span></p>
			</div>
			<div class="divide-y divide-gray-100">
				{#if changelogVersions.length === 0}
					<div class="px-6 py-10 text-center text-sm text-gray-400">No changelog available.</div>
				{:else}
					{#each changelogVersions as ver}
						<div class="px-6 py-4">
							<div class="flex items-center gap-3 mb-2">
								<span class="text-sm font-bold text-gray-900">v{ver.version}</span>
								<span class="text-xs text-gray-400">{ver.date}</span>
							</div>
							<ul class="space-y-1">
								{#each ver.changes as change}
									<li class="text-sm text-gray-600 flex items-start gap-2">
										<span class="text-blue-400 mt-1">•</span>
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
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden mb-6">
			<div class="px-6 py-5">
				<h3 class="text-base font-semibold text-gray-900 mb-2">About SyncVault</h3>
				<p class="text-sm text-gray-600">SyncVault is an open-source file sync and backup solution, built as an alternative to Synology Drive.</p>
				<p class="text-sm text-gray-600 mt-2">Created by <span class="font-medium">Niel Heesakkers</span> — vibe-coded with <a href="https://claude.ai" target="_blank" rel="noopener" class="text-blue-600 hover:underline">Claude</a> by Anthropic.</p>
				<p class="text-sm text-gray-500 mt-3">Version {currentVersion || 'unknown'}</p>
			</div>
		</div>

		<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
			<div class="px-6 py-4 border-b border-gray-100">
				<h3 class="text-sm font-semibold text-gray-800">Open Source Libraries</h3>
			</div>
			<table class="min-w-full divide-y divide-gray-200">
				<thead class="bg-gray-50">
					<tr>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Library</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">License</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden sm:table-cell">Used for</th>
					</tr>
				</thead>
				<tbody class="bg-white divide-y divide-gray-200">
					{#each openSourceLibs as lib}
						<tr class="hover:bg-gray-50">
							<td class="px-4 py-3">
								<a href={lib.url} target="_blank" rel="noopener" class="text-sm font-medium text-blue-600 hover:underline">{lib.name}</a>
							</td>
							<td class="px-4 py-3">
								<span class="text-xs font-mono bg-gray-100 text-gray-600 px-2 py-0.5 rounded">{lib.license}</span>
							</td>
							<td class="px-4 py-3 hidden sm:table-cell">
								<span class="text-sm text-gray-500">{lib.desc}</span>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>
