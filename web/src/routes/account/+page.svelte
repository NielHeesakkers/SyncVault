<script lang="ts">
	import { onMount } from 'svelte';
	import { User, Mail, Shield, HardDrive, Camera, Save } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes } from '$lib/utils';
	import StorageBar from '$lib/components/StorageBar.svelte';

	let displayName = $state('');
	let email = $state('');
	let username = $state('');
	let role = $state('');
	let hasAvatar = $state(false);
	let storageUsed = $state(0);
	let storageQuota = $state(0);
	let saving = $state(false);

	// Password change
	let currentPassword = $state('');
	let newPassword = $state('');
	let confirmPassword = $state('');
	let changingPassword = $state(false);

	let avatarUrl = $state('');

	onMount(async () => {
		const [meRes, storageRes] = await Promise.all([
			api.get('/api/me'),
			api.get('/api/me/storage')
		]);

		if (meRes.ok) {
			const data = await meRes.json();
			username = data.username || '';
			email = data.email || '';
			displayName = data.display_name || '';
			role = data.role || 'user';
			hasAvatar = data.has_avatar || false;
			if (hasAvatar) {
				avatarUrl = '/api/me/avatar?' + Date.now();
			}
		}
		if (storageRes.ok) {
			const data = await storageRes.json();
			storageUsed = data.used || 0;
			storageQuota = data.quota || 0;
		}
	});

	async function saveProfile() {
		saving = true;
		try {
			const res = await api.put('/api/me/profile', { display_name: displayName, email });
			if (res.ok) {
				showToast('Profile updated', 'success');
			} else {
				const data = await res.json();
				showToast(data.error || 'Failed to update profile', 'error');
			}
		} catch {
			showToast('Failed to update profile', 'error');
		} finally {
			saving = false;
		}
	}

	async function changePassword() {
		if (newPassword !== confirmPassword) {
			showToast('Passwords do not match', 'error');
			return;
		}
		if (newPassword.length < 4) {
			showToast('Password must be at least 4 characters', 'error');
			return;
		}
		changingPassword = true;
		try {
			const res = await api.put('/api/me/password', {
				current_password: currentPassword,
				new_password: newPassword
			});
			if (res.ok) {
				showToast('Password changed', 'success');
				currentPassword = '';
				newPassword = '';
				confirmPassword = '';
			} else {
				const data = await res.json();
				showToast(data.error || 'Failed to change password', 'error');
			}
		} catch {
			showToast('Failed to change password', 'error');
		} finally {
			changingPassword = false;
		}
	}

	async function uploadAvatar(e: Event) {
		const input = e.target as HTMLInputElement;
		if (!input.files?.length) return;
		const file = input.files[0];
		if (file.size > 5 * 1024 * 1024) {
			showToast('Avatar must be under 5 MB', 'error');
			return;
		}
		const formData = new FormData();
		formData.append('avatar', file);
		try {
			const res = await fetch('/api/me/avatar', {
				method: 'POST',
				headers: { 'Authorization': `Bearer ${localStorage.getItem('access_token')}` },
				body: formData
			});
			if (res.ok) {
				hasAvatar = true;
				avatarUrl = '/api/me/avatar?' + Date.now();
				showToast('Avatar updated', 'success');
			} else {
				showToast('Failed to upload avatar', 'error');
			}
		} catch {
			showToast('Failed to upload avatar', 'error');
		}
	}
</script>

<svelte:head>
	<title>Account — SyncVault</title>
</svelte:head>

<div class="p-6 space-y-5 max-w-2xl" style="background: var(--bg-base); min-height: 100%;">
	<div>
		<h1 class="text-base font-semibold" style="color: var(--text-primary);">Account</h1>
		<p class="text-sm mt-1" style="color: var(--text-tertiary);">Manage your profile, password, and storage.</p>
	</div>

	<!-- Profile Section -->
	<div class="rounded-xl border p-6" style="background: var(--bg-elevated); border-color: var(--border);">
		<div class="flex items-center gap-3 mb-5">
			<div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: rgba(59,130,246,0.15);">
				<User size={16} class="text-blue-400" />
			</div>
			<h2 class="text-sm font-semibold" style="color: var(--text-primary);">Profile</h2>
		</div>

		<div class="flex items-start gap-6 mb-6">
			<!-- Avatar -->
			<label class="relative cursor-pointer group flex-shrink-0">
				<div class="w-20 h-20 rounded-full overflow-hidden border-2 border-dashed flex items-center justify-center" style="border-color: var(--border); background: var(--bg-overlay);">
					{#if hasAvatar && avatarUrl}
						<img src={avatarUrl} alt="Avatar" class="w-full h-full object-cover" />
					{:else}
						<span class="text-2xl font-bold" style="color: var(--text-tertiary);">{(displayName || username || '?')[0].toUpperCase()}</span>
					{/if}
				</div>
				<div class="absolute inset-0 rounded-full bg-black/40 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity">
					<Camera size={18} class="text-white" />
				</div>
				<input type="file" accept="image/*" class="hidden" onchange={uploadAvatar} />
			</label>

			<div class="flex-1 space-y-4">
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Username</label>
					<input type="text" value={username} readonly class="w-full px-3 py-2 rounded-lg text-sm border" style="background: var(--bg-overlay); border-color: var(--border); color: var(--text-tertiary);" />
				</div>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Display Name</label>
					<input type="text" bind:value={displayName} placeholder="Your display name" class="w-full px-3 py-2 rounded-lg text-sm border" style="background: var(--bg-base); border-color: var(--border); color: var(--text-primary);" />
				</div>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Email</label>
					<input type="email" bind:value={email} class="w-full px-3 py-2 rounded-lg text-sm border" style="background: var(--bg-base); border-color: var(--border); color: var(--text-primary);" />
				</div>
			</div>
		</div>

		<div class="flex justify-end">
			<button onclick={saveProfile} disabled={saving} class="px-4 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-500 disabled:opacity-40 rounded-lg transition-all flex items-center gap-2">
				<Save size={14} />
				{saving ? 'Saving...' : 'Save Changes'}
			</button>
		</div>
	</div>

	<!-- Storage Section -->
	<div class="rounded-xl border p-6" style="background: var(--bg-elevated); border-color: var(--border);">
		<div class="flex items-center gap-3 mb-5">
			<div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: rgba(34,197,94,0.15);">
				<HardDrive size={16} class="text-green-400" />
			</div>
			<h2 class="text-sm font-semibold" style="color: var(--text-primary);">Storage</h2>
		</div>
		<StorageBar used={storageUsed} total={storageQuota || storageUsed * 2} />
		<div class="flex gap-8 mt-4">
			<div>
				<p class="text-lg font-bold" style="color: var(--text-primary);">{formatBytes(storageUsed)}</p>
				<p class="text-xs" style="color: var(--text-tertiary);">Used</p>
			</div>
			{#if storageQuota > 0}
			<div>
				<p class="text-lg font-bold" style="color: var(--text-primary);">{formatBytes(storageQuota)}</p>
				<p class="text-xs" style="color: var(--text-tertiary);">Quota</p>
			</div>
			{:else}
			<div>
				<p class="text-lg font-bold" style="color: var(--text-primary);">Unlimited</p>
				<p class="text-xs" style="color: var(--text-tertiary);">Quota</p>
			</div>
			{/if}
		</div>
	</div>

	<!-- Password Section -->
	<div class="rounded-xl border p-6" style="background: var(--bg-elevated); border-color: var(--border);">
		<div class="flex items-center gap-3 mb-5">
			<div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: rgba(239,68,68,0.15);">
				<Shield size={16} class="text-red-400" />
			</div>
			<h2 class="text-sm font-semibold" style="color: var(--text-primary);">Change Password</h2>
		</div>

		<div class="space-y-4 max-w-sm">
			<div>
				<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Current Password</label>
				<input type="password" bind:value={currentPassword} class="w-full px-3 py-2 rounded-lg text-sm border" style="background: var(--bg-base); border-color: var(--border); color: var(--text-primary);" />
			</div>
			<div>
				<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">New Password</label>
				<input type="password" bind:value={newPassword} class="w-full px-3 py-2 rounded-lg text-sm border" style="background: var(--bg-base); border-color: var(--border); color: var(--text-primary);" />
			</div>
			<div>
				<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Confirm New Password</label>
				<input type="password" bind:value={confirmPassword} class="w-full px-3 py-2 rounded-lg text-sm border" style="background: var(--bg-base); border-color: var(--border); color: var(--text-primary);" />
			</div>
		</div>

		<div class="flex justify-end mt-5">
			<button onclick={changePassword} disabled={changingPassword || !currentPassword || !newPassword} class="px-4 py-2 text-sm font-medium text-white bg-red-600 hover:bg-red-500 disabled:opacity-40 rounded-lg transition-all">
				{changingPassword ? 'Changing...' : 'Change Password'}
			</button>
		</div>
	</div>
</div>
