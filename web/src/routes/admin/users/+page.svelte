<script lang="ts">
	import { onMount } from 'svelte';
	import { UserPlus, Edit2, Key, Trash2, Users, Shield, User } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes } from '$lib/utils';
	import Modal from '$lib/components/Modal.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import StorageBar from '$lib/components/StorageBar.svelte';

	interface UserRecord {
		id: string;
		username: string;
		email: string;
		role: string;
		storage_used?: number;
		storage_quota?: number;
		created_at?: string;
	}

	let users = $state<UserRecord[]>([]);
	let loading = $state(true);

	// Create user modal
	let showCreate = $state(false);
	let createForm = $state({ username: '', email: '', password: '', role: 'user' });
	let creating = $state(false);

	// Edit user modal
	let showEdit = $state(false);
	let editTarget = $state<UserRecord | null>(null);
	let editForm = $state({ email: '', role: 'user', storage_quota: '' });
	let editing = $state(false);

	// Reset password modal
	let showResetPwd = $state(false);
	let resetTarget = $state<UserRecord | null>(null);
	let newPassword = $state('');
	let confirmPassword = $state('');
	let resettingPwd = $state(false);

	// Delete
	let showDelete = $state(false);
	let deleteTarget = $state<UserRecord | null>(null);

	onMount(loadUsers);

	async function loadUsers() {
		loading = true;
		try {
			const res = await api.get('/api/admin/users');
			if (res.ok) {
				const data = await res.json();
				users = data.users || data || [];
			} else {
				showToast('Failed to load users', 'error');
			}
		} finally {
			loading = false;
		}
	}

	async function createUser() {
		creating = true;
		try {
			const res = await api.post('/api/users', createForm);
			if (res.ok) {
				showToast('User created', 'success');
				showCreate = false;
				createForm = { username: '', email: '', password: '', role: 'user' };
				loadUsers();
			} else {
				const data = await res.json().catch(() => ({}));
				showToast(data.message || 'Failed to create user', 'error');
			}
		} finally {
			creating = false;
		}
	}

	function startEdit(user: UserRecord) {
		editTarget = user;
		editForm = {
			email: user.email,
			role: user.role,
			storage_quota: user.storage_quota ? String(user.storage_quota) : ''
		};
		showEdit = true;
	}

	async function saveEdit() {
		if (!editTarget) return;
		editing = true;
		try {
			const body: Record<string, unknown> = {
				email: editForm.email,
				role: editForm.role
			};
			if (editForm.storage_quota) body.storage_quota = parseInt(editForm.storage_quota);
			const res = await api.put(`/api/admin/users/${editTarget.id}`, body);
			if (res.ok) {
				showToast('User updated', 'success');
				showEdit = false;
				editTarget = null;
				loadUsers();
			} else {
				showToast('Failed to update user', 'error');
			}
		} finally {
			editing = false;
		}
	}

	function startResetPwd(user: UserRecord) {
		resetTarget = user;
		newPassword = '';
		confirmPassword = '';
		showResetPwd = true;
	}

	async function doResetPwd() {
		if (!resetTarget || !newPassword.trim()) return;
		if (newPassword !== confirmPassword) {
			showToast('Passwords do not match', 'error');
			return;
		}
		resettingPwd = true;
		try {
			const res = await api.post(`/api/admin/users/${resetTarget.id}/reset-password`, {
				password: newPassword
			});
			if (res.ok) {
				showToast('Password reset successfully', 'success');
				showResetPwd = false;
				resetTarget = null;
				newPassword = '';
				confirmPassword = '';
			} else {
				showToast('Failed to reset password', 'error');
			}
		} finally {
			resettingPwd = false;
		}
	}

	function confirmDelete(user: UserRecord) {
		deleteTarget = user;
		showDelete = true;
	}

	async function doDelete() {
		if (!deleteTarget) return;
		const res = await api.delete(`/api/admin/users/${deleteTarget.id}`);
		if (res.ok) {
			showToast('User deleted', 'success');
			users = users.filter((u) => u.id !== deleteTarget!.id);
			showDelete = false;
			deleteTarget = null;
		} else {
			showToast('Failed to delete user', 'error');
		}
	}
</script>

<svelte:head>
	<title>Users — SyncVault Admin</title>
</svelte:head>

<div class="p-6">
	<div class="mb-6 flex items-center justify-between">
		<div>
			<h1 class="text-xl font-semibold text-gray-900">Users</h1>
			<p class="text-sm text-gray-500 mt-1">{users.length} user{users.length !== 1 ? 's' : ''} total</p>
		</div>
		<button
			onclick={() => (showCreate = true)}
			class="flex items-center gap-2 bg-blue-500 hover:bg-blue-600 text-white text-sm font-medium rounded-md px-4 py-2 transition-colors"
		>
			<UserPlus size={16} /> Create User
		</button>
	</div>

	<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
		{#if loading}
			<div class="flex items-center justify-center py-16">
				<div class="w-7 h-7 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
			</div>
		{:else if users.length === 0}
			<div class="text-center py-16 text-gray-400">
				<Users size={48} class="mx-auto mb-3 opacity-30" />
				<p class="text-base font-medium">No users found</p>
			</div>
		{:else}
			<table class="min-w-full divide-y divide-gray-200">
				<thead class="bg-gray-50">
					<tr>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">User</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden sm:table-cell">Role</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden lg:table-cell">Storage</th>
						<th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Actions</th>
					</tr>
				</thead>
				<tbody class="bg-white divide-y divide-gray-200">
					{#each users as user}
						<tr class="hover:bg-gray-50">
							<td class="px-4 py-3">
								<div class="flex items-center gap-3">
									<div class="w-8 h-8 rounded-full bg-blue-100 flex items-center justify-center text-blue-600 text-sm font-bold flex-shrink-0">
										{user.username[0].toUpperCase()}
									</div>
									<div>
										<p class="text-sm font-medium text-gray-900">{user.username}</p>
										<p class="text-xs text-gray-500">{user.email}</p>
									</div>
								</div>
							</td>
							<td class="px-4 py-3 hidden sm:table-cell">
								<span class="inline-flex items-center gap-1 text-xs font-medium rounded-full px-2.5 py-0.5
								{user.role === 'admin' ? 'bg-purple-100 text-purple-700' : 'bg-gray-100 text-gray-600'}">
									{#if user.role === 'admin'}<Shield size={11} />{:else}<User size={11} />{/if}
									{user.role}
								</span>
							</td>
							<td class="px-4 py-3 hidden lg:table-cell">
								{#if user.storage_quota}
									<div class="w-40">
										<StorageBar used={user.storage_used ?? 0} total={user.storage_quota} />
									</div>
								{:else}
									<span class="text-sm text-gray-400">{formatBytes(user.storage_used ?? 0)}</span>
								{/if}
							</td>
							<td class="px-4 py-3">
								<div class="flex items-center justify-end gap-1">
									<button
										onclick={() => startEdit(user)}
										title="Edit user"
										class="p-1.5 text-gray-400 hover:text-blue-600 rounded hover:bg-gray-100 transition-colors"
									>
										<Edit2 size={15} />
									</button>
									<button
										onclick={() => startResetPwd(user)}
										title="Reset password"
										class="p-1.5 text-gray-400 hover:text-yellow-600 rounded hover:bg-gray-100 transition-colors"
									>
										<Key size={15} />
									</button>
									<button
										onclick={() => confirmDelete(user)}
										title="Delete user"
										class="p-1.5 text-gray-400 hover:text-red-600 rounded hover:bg-gray-100 transition-colors"
									>
										<Trash2 size={15} />
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

<!-- Create user modal -->
{#if showCreate}
	<Modal title="Create User" onclose={() => { showCreate = false; }}>
		{#snippet children()}
			<div class="space-y-3">
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Username</label>
					<input type="text" bind:value={createForm.username} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Email</label>
					<input type="email" bind:value={createForm.email} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Password</label>
					<input type="password" bind:value={createForm.password} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Role</label>
					<select bind:value={createForm.role} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500">
						<option value="user">User</option>
						<option value="admin">Admin</option>
					</select>
				</div>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showCreate = false)} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={createUser} disabled={creating || !createForm.username || !createForm.password} class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors">
				{creating ? 'Creating…' : 'Create'}
			</button>
		{/snippet}
	</Modal>
{/if}

<!-- Edit user modal -->
{#if showEdit && editTarget}
	<Modal title="Edit User: {editTarget.username}" onclose={() => (showEdit = false)}>
		{#snippet children()}
			<div class="space-y-3">
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Email</label>
					<input type="email" bind:value={editForm.email} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Role</label>
					<select bind:value={editForm.role} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500">
						<option value="user">User</option>
						<option value="admin">Admin</option>
					</select>
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Storage quota (bytes, empty = unlimited)</label>
					<input type="number" bind:value={editForm.storage_quota} placeholder="e.g. 10737418240 for 10 GB" class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showEdit = false)} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={saveEdit} disabled={editing} class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors">
				{editing ? 'Saving…' : 'Save'}
			</button>
		{/snippet}
	</Modal>
{/if}

<!-- Reset password modal -->
{#if showResetPwd && resetTarget}
	<Modal title="Reset Password: {resetTarget.username}" onclose={() => (showResetPwd = false)}>
		{#snippet children()}
			<div class="space-y-3">
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">New password</label>
					<input type="password" bind:value={newPassword} placeholder="Enter new password" class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Confirm password</label>
					<input type="password" bind:value={confirmPassword} placeholder="Confirm new password" class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500
						{confirmPassword && newPassword !== confirmPassword ? 'border-red-400 focus:border-red-400 focus:ring-red-400' : ''}" />
					{#if confirmPassword && newPassword !== confirmPassword}
						<p class="text-xs text-red-500 mt-1">Passwords do not match</p>
					{/if}
				</div>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showResetPwd = false)} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={doResetPwd} disabled={resettingPwd || !newPassword.trim() || newPassword !== confirmPassword} class="rounded-md px-4 py-2 text-sm font-medium bg-yellow-500 hover:bg-yellow-600 disabled:bg-yellow-300 text-white transition-colors">
				{resettingPwd ? 'Resetting…' : 'Reset Password'}
			</button>
		{/snippet}
	</Modal>
{/if}

<!-- Delete confirm -->
{#if showDelete && deleteTarget}
	<ConfirmDialog
		title="Delete User"
		message="Delete '{deleteTarget.username}'? All their files will also be deleted. This cannot be undone."
		confirmLabel="Delete User"
		onconfirm={doDelete}
		oncancel={() => { showDelete = false; deleteTarget = null; }}
	/>
{/if}
