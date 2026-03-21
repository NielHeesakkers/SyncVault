<script lang="ts">
	import { onMount } from 'svelte';
	import { Mail, Send, Save } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';

	interface SmtpForm {
		'smtp.enabled': boolean;
		'smtp.host': string;
		'smtp.port': string;
		'smtp.user': string;
		'smtp.password': string;
		'smtp.from': string;
	}

	let loading = $state(true);
	let saving = $state(false);
	let testing = $state(false);

	let form = $state<SmtpForm>({
		'smtp.enabled': false,
		'smtp.host': '',
		'smtp.port': '587',
		'smtp.user': '',
		'smtp.password': '',
		'smtp.from': 'SyncVault <noreply@example.com>'
	});

	onMount(loadSettings);

	async function loadSettings() {
		loading = true;
		try {
			const res = await api.get('/api/admin/settings');
			if (res.ok) {
				const data: Record<string, string> = await res.json();
				if ('smtp.enabled' in data) {
					form['smtp.enabled'] = data['smtp.enabled'] === 'true' || data['smtp.enabled'] === '1';
				}
				if (data['smtp.host']) form['smtp.host'] = data['smtp.host'];
				if (data['smtp.port']) form['smtp.port'] = data['smtp.port'];
				if (data['smtp.user']) form['smtp.user'] = data['smtp.user'];
				if (data['smtp.password']) form['smtp.password'] = data['smtp.password'];
				if (data['smtp.from']) form['smtp.from'] = data['smtp.from'];
			} else {
				showToast('Failed to load settings', 'error');
			}
		} finally {
			loading = false;
		}
	}

	async function saveSettings() {
		saving = true;
		try {
			const payload: Record<string, string> = {
				'smtp.enabled': form['smtp.enabled'] ? 'true' : 'false',
				'smtp.host': form['smtp.host'],
				'smtp.port': form['smtp.port'],
				'smtp.user': form['smtp.user'],
				'smtp.password': form['smtp.password'],
				'smtp.from': form['smtp.from']
			};
			const res = await api.put('/api/admin/settings', payload);
			if (res.ok) {
				showToast('Settings saved', 'success');
			} else {
				const data = await res.json().catch(() => ({}));
				showToast(data.error || 'Failed to save settings', 'error');
			}
		} finally {
			saving = false;
		}
	}

	async function sendTestEmail() {
		testing = true;
		try {
			const res = await api.post('/api/admin/settings/test-email', {});
			if (res.ok) {
				const data = await res.json().catch(() => ({}));
				showToast(data.status || 'Test email sent', 'success');
			} else {
				const data = await res.json().catch(() => ({}));
				showToast(data.error || 'Failed to send test email', 'error');
			}
		} finally {
			testing = false;
		}
	}
</script>

<svelte:head>
	<title>Settings — SyncVault Admin</title>
</svelte:head>

<div class="p-6 max-w-2xl">
	<div class="mb-6">
		<h1 class="text-xl font-semibold text-gray-900">Settings</h1>
		<p class="text-sm text-gray-500 mt-1">Server configuration — changes take effect immediately.</p>
	</div>

	{#if loading}
		<div class="flex items-center justify-center py-16">
			<div class="w-7 h-7 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
		</div>
	{:else}
		<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
			<!-- Section header -->
			<div class="px-6 py-4 border-b border-gray-100 flex items-center gap-2">
				<Mail size={18} class="text-gray-500" />
				<h2 class="text-sm font-semibold text-gray-800">SMTP Email</h2>
			</div>

			<div class="px-6 py-5 space-y-5">
				<!-- Enabled toggle -->
				<div class="flex items-center justify-between">
					<div>
						<p class="text-sm font-medium text-gray-700">Enable SMTP</p>
						<p class="text-xs text-gray-500 mt-0.5">Send transactional emails (welcome, password reset, quota warnings)</p>
					</div>
					<button
						role="switch"
						aria-checked={form['smtp.enabled']}
						onclick={() => (form['smtp.enabled'] = !form['smtp.enabled'])}
						class="relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2
						{form['smtp.enabled'] ? 'bg-blue-500' : 'bg-gray-200'}"
					>
						<span
							class="inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform
							{form['smtp.enabled'] ? 'translate-x-6' : 'translate-x-1'}"
						></span>
					</button>
				</div>

				<div class="border-t border-gray-100 pt-5 space-y-4">
					<!-- SMTP Host -->
					<div>
						<label class="block text-sm font-medium text-gray-700 mb-1" for="smtp-host">
							SMTP Host
						</label>
						<input
							id="smtp-host"
							type="text"
							bind:value={form['smtp.host']}
							placeholder="smtp.gmail.com"
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						/>
					</div>

					<!-- SMTP Port -->
					<div>
						<label class="block text-sm font-medium text-gray-700 mb-1" for="smtp-port">
							SMTP Port
						</label>
						<input
							id="smtp-port"
							type="number"
							bind:value={form['smtp.port']}
							placeholder="587"
							min="1"
							max="65535"
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						/>
					</div>

					<!-- SMTP User -->
					<div>
						<label class="block text-sm font-medium text-gray-700 mb-1" for="smtp-user">
							SMTP User
						</label>
						<input
							id="smtp-user"
							type="text"
							bind:value={form['smtp.user']}
							placeholder="you@example.com"
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						/>
					</div>

					<!-- SMTP Password -->
					<div>
						<label class="block text-sm font-medium text-gray-700 mb-1" for="smtp-password">
							SMTP Password
						</label>
						<input
							id="smtp-password"
							type="password"
							bind:value={form['smtp.password']}
							placeholder="App password or SMTP password"
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						/>
					</div>

					<!-- From Address -->
					<div>
						<label class="block text-sm font-medium text-gray-700 mb-1" for="smtp-from">
							From Address
						</label>
						<input
							id="smtp-from"
							type="text"
							bind:value={form['smtp.from']}
							placeholder='SyncVault <noreply@example.com>'
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
						/>
					</div>
				</div>
			</div>

			<!-- Actions -->
			<div class="px-6 py-4 border-t border-gray-100 bg-gray-50 flex items-center justify-between">
				<button
					onclick={sendTestEmail}
					disabled={testing || !form['smtp.enabled']}
					class="flex items-center gap-2 rounded-md px-4 py-2 text-sm font-medium border border-gray-300 bg-white hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed transition-colors text-gray-700"
				>
					<Send size={15} />
					{testing ? 'Sending…' : 'Send Test Email'}
				</button>

				<button
					onclick={saveSettings}
					disabled={saving}
					class="flex items-center gap-2 rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors"
				>
					<Save size={15} />
					{saving ? 'Saving…' : 'Save'}
				</button>
			</div>
		</div>
	{/if}
</div>
