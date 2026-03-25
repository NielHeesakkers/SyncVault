<script lang="ts">
	import { onMount } from 'svelte';
	import { UserPlus, Edit2, Users, Shield, User, Key, RefreshCw, Trash2, Download } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes } from '$lib/utils';
	import Modal from '$lib/components/Modal.svelte';
	import StorageBar from '$lib/components/StorageBar.svelte';

	interface UserRecord {
		id: string;
		username: string;
		email: string;
		role: string;
		storage_used?: number;
		storage_quota?: number;
		has_token?: boolean;
		created_at?: string;
	}

	let users = $state<UserRecord[]>([]);
	let loading = $state(true);

	// Create user modal
	let showCreate = $state(false);
	let createForm = $state({ username: '', email: '', password: '', role: 'user' });
	let creating = $state(false);

	// Edit user modal (combined: edit, tokens, delete)
	let showEdit = $state(false);
	let editTarget = $state<UserRecord | null>(null);
	let editTab = $state<'details' | 'tokens' | 'delete'>('details');
	let editForm = $state({ email: '', role: 'user', storage_quota: '', storage_quota_unit: 'GB', newPassword: '', confirmPassword: '' });
	let editing = $state(false);
	let deleteConfirmText = $state('');
	let deleteAction = $state<'delete' | 'transfer'>('delete');
	let transferToUserId = $state('');

	// Teams
	interface Team { id: string; name: string; }
	interface TeamMember { user_id: string; permission: string; }
	let teams = $state<Team[]>([]);
	let createTeamSelections = $state<Record<string, string>>({});
	let editTeamSelections = $state<Record<string, string>>({});

	onMount(() => { loadUsers(); loadTeams(); });

	async function loadTeams() {
		try {
			const res = await api.get('/api/teams');
			if (res.ok) { const data = await res.json(); teams = data.teams || data || []; }
		} catch {}
	}

	async function loadUserTeams(userId: string): Promise<Record<string, string>> {
		const selections: Record<string, string> = {};
		for (const team of teams) {
			try {
				const res = await api.get(`/api/teams/${team.id}/members`);
				if (res.ok) {
					const data = await res.json();
					const members: TeamMember[] = data.members || data || [];
					const member = members.find((m: TeamMember) => m.user_id === userId);
					if (member) selections[team.id] = member.permission;
				}
			} catch {}
		}
		return selections;
	}

	async function saveTeamMemberships(userId: string, selections: Record<string, string>) {
		for (const team of teams) {
			const permission = selections[team.id];
			if (permission) {
				await api.put(`/api/teams/${team.id}/members/${userId}`, { permission });
			} else {
				await api.delete(`/api/teams/${team.id}/members/${userId}`);
			}
		}
	}

	async function loadUsers() {
		loading = true;
		try {
			const res = await api.get('/api/admin/users');
			if (res.ok) { const data = await res.json(); users = data.users || data || []; }
			else showToast('Failed to load users', 'error');
		} finally { loading = false; }
	}

	function openCreate() {
		createForm = { username: '', email: '', password: '', role: 'user' };
		createTeamSelections = {};
		showCreate = true;
	}

	async function createUser() {
		creating = true;
		try {
			const res = await api.post('/api/users', createForm);
			if (res.ok) {
				const data = await res.json();
				try { if (data.id) await saveTeamMemberships(data.id, createTeamSelections); } catch {}
				showToast('User created', 'success');
				showCreate = false;
				await loadUsers();
			} else {
				const data = await res.json().catch(() => ({}));
				showToast(data.error || 'Failed to create user', 'error');
			}
		} finally { creating = false; }
	}

	async function openEdit(user: UserRecord) {
		editTarget = user;
		editTab = 'details';
		deleteConfirmText = '';
		deleteAction = 'delete';
		transferToUserId = '';
		const qb = user.storage_quota || 0;
		let quotaVal = '', quotaUnit = 'GB';
		if (qb >= 1099511627776) { quotaVal = String(Math.round(qb / 1099511627776)); quotaUnit = 'TB'; }
		else if (qb >= 1073741824) { quotaVal = String(Math.round(qb / 1073741824)); quotaUnit = 'GB'; }
		else if (qb >= 1048576) { quotaVal = String(Math.round(qb / 1048576)); quotaUnit = 'MB'; }
		else if (qb > 0) { quotaVal = String(qb); quotaUnit = 'MB'; }
		editForm = { email: user.email, role: user.role, storage_quota: quotaVal, storage_quota_unit: quotaUnit, newPassword: '', confirmPassword: '' };
		editTeamSelections = await loadUserTeams(user.id);
		showEdit = true;
	}

	async function saveEdit() {
		if (!editTarget) return;
		if (editForm.newPassword || editForm.confirmPassword) {
			if (editForm.newPassword !== editForm.confirmPassword) { showToast('Passwords do not match', 'error'); return; }
		}
		editing = true;
		try {
			const body: Record<string, unknown> = { email: editForm.email, role: editForm.role };
			if (editForm.storage_quota) {
				let qb = parseFloat(editForm.storage_quota);
				if (editForm.storage_quota_unit === 'TB') qb *= 1099511627776;
				else if (editForm.storage_quota_unit === 'GB') qb *= 1073741824;
				else qb *= 1048576;
				body.storage_quota = Math.round(qb);
			}
			const res = await api.put(`/api/admin/users/${editTarget.id}`, body);
			if (!res.ok) { const data = await res.json().catch(() => ({})); showToast(data.error || 'Failed to update user', 'error'); return; }
			await saveTeamMemberships(editTarget.id, editTeamSelections);
			if (editForm.newPassword) {
				const pwRes = await api.post(`/api/admin/users/${editTarget.id}/reset-password`, { password: editForm.newPassword });
				if (!pwRes.ok) { showToast('User updated but password reset failed', 'error'); showEdit = false; loadUsers(); return; }
			}
			showToast(editForm.newPassword ? 'User updated and password reset' : 'User updated', 'success');
			showEdit = false;
			loadUsers();
		} finally { editing = false; }
	}

	async function downloadToken(user: UserRecord) {
		try {
			const res = await api.get(`/api/admin/users/${user.id}/token`);
			if (res.status === 410) { showToast('Token already used — generate a new one first', 'error'); return; }
			if (!res.ok) { showToast('No token available', 'error'); return; }
			const blob = await res.blob();
			const url = URL.createObjectURL(blob);
			const a = document.createElement('a');
			a.href = url; a.download = `${user.username}.syncvault`; a.click();
			URL.revokeObjectURL(url);
			showToast('Token downloaded (one-time use)', 'success');
			await loadUsers();
			if (editTarget?.id === user.id) editTarget = { ...editTarget, has_token: false };
		} catch { showToast('Failed to download token', 'error'); }
	}

	async function refreshToken(user: UserRecord) {
		try {
			const res = await api.post(`/api/admin/users/${user.id}/token/refresh`, {});
			if (!res.ok) { showToast('Failed to generate token', 'error'); return; }
			showToast('New token generated — PIN emailed to user', 'success');
			await loadUsers();
			if (editTarget?.id === user.id) editTarget = { ...editTarget, has_token: true };
		} catch { showToast('Failed to generate token', 'error'); }
	}

	async function doDelete() {
		if (!editTarget || deleteConfirmText !== 'DELETE') return;
		if (deleteAction === 'transfer' && transferToUserId) {
			const res = await api.post(`/api/admin/users/${editTarget.id}/transfer`, { user_id: transferToUserId });
			if (!res.ok) { showToast('Failed to transfer files', 'error'); return; }
		}
		const res = await api.delete(`/api/admin/users/${editTarget.id}`);
		if (res.ok) {
			showToast(deleteAction === 'transfer' ? 'User deleted, files transferred' : 'User deleted', 'success');
			users = users.filter(u => u.id !== editTarget!.id);
			showEdit = false; editTarget = null;
		} else { showToast('Failed to delete user', 'error'); }
	}
</script>

<svelte:head><title>Users — SyncVault Admin</title></svelte:head>

<div class="p-6">
	<div class="mb-6 flex items-center justify-between">
		<div>
			<h1 class="text-xl font-semibold text-gray-900">Users</h1>
			<p class="text-sm text-gray-500 mt-1">{users.length} user{users.length !== 1 ? 's' : ''} total</p>
		</div>
		<button onclick={openCreate}
			class="flex items-center gap-2 bg-blue-500 hover:bg-blue-600 text-white text-sm font-medium rounded-md px-4 py-2 transition-colors">
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
						<tr class="hover:bg-gray-50 cursor-pointer" onclick={() => openEdit(user)}>
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
									<div class="w-40"><StorageBar used={user.storage_used ?? 0} total={user.storage_quota} /></div>
								{:else}
									<span class="text-sm text-gray-400">{formatBytes(user.storage_used ?? 0)}</span>
								{/if}
							</td>
							<td class="px-4 py-3">
								<div class="flex items-center justify-end gap-1">
									<button onclick={(e) => { e.stopPropagation(); openEdit(user); }}
										title="Edit user" class="p-1.5 text-gray-400 hover:text-blue-600 rounded hover:bg-gray-100 transition-colors">
										<Edit2 size={15} />
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
				{#if teams.length > 0}
					<div>
						<label class="block text-sm font-medium text-gray-700 mb-1">Team Folders</label>
						<div class="space-y-2 border border-gray-200 rounded-md p-3">
							{#each teams as team}
								<div class="flex items-center justify-between">
									<span class="text-sm text-gray-700">{team.name}</span>
									<select value={createTeamSelections[team.id] || ''}
										onchange={(e) => { const v = (e.target as HTMLSelectElement).value; if (v) createTeamSelections[team.id] = v; else delete createTeamSelections[team.id]; createTeamSelections = { ...createTeamSelections }; }}
										class="rounded-md border border-gray-300 px-2 py-1 text-sm focus:border-blue-500 focus:outline-none">
										<option value="">No access</option>
										<option value="read">Read</option>
										<option value="write">Write</option>
										<option value="readwrite">Read & Write</option>
									</select>
								</div>
							{/each}
						</div>
					</div>
				{/if}
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showCreate = false)} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={createUser} disabled={creating || !createForm.username || !createForm.password}
				class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors">
				{creating ? 'Creating…' : 'Create'}
			</button>
		{/snippet}
	</Modal>
{/if}

<!-- Edit user modal (tabs: Details, Connection Token, Delete) -->
{#if showEdit && editTarget}
	<Modal title={editTarget.username} onclose={() => { showEdit = false; editTarget = null; }}>
		{#snippet children()}
			<!-- Tab bar -->
			<div class="flex gap-1 border-b border-gray-200 -mx-6 px-6 mb-4">
				<button onclick={() => editTab = 'details'}
					class="px-3 py-2 text-sm font-medium border-b-2 transition-colors {editTab === 'details' ? 'border-blue-500 text-blue-600' : 'border-transparent text-gray-500 hover:text-gray-700'}">
					Details
				</button>
				<button onclick={() => editTab = 'tokens'}
					class="px-3 py-2 text-sm font-medium border-b-2 transition-colors {editTab === 'tokens' ? 'border-blue-500 text-blue-600' : 'border-transparent text-gray-500 hover:text-gray-700'}">
					Connection Token
				</button>
				<button onclick={() => { editTab = 'delete'; deleteConfirmText = ''; }}
					class="px-3 py-2 text-sm font-medium border-b-2 transition-colors {editTab === 'delete' ? 'border-red-500 text-red-600' : 'border-transparent text-gray-500 hover:text-gray-700'}">
					Delete
				</button>
			</div>

			{#if editTab === 'details'}
				<div class="space-y-3">
					<div>
						<label class="block text-sm font-medium text-gray-700 mb-1">Username</label>
						<input type="text" value={editTarget.username} readonly
							class="w-full rounded-md border border-gray-200 bg-gray-50 px-3 py-2 text-sm text-gray-500 cursor-not-allowed" />
					</div>
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
						<label class="block text-sm font-medium text-gray-700 mb-1">Storage quota (0 = unlimited)</label>
						<div class="flex items-center gap-2">
							<input type="number" min="0" bind:value={editForm.storage_quota} placeholder="0"
								class="w-32 rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
							<select bind:value={editForm.storage_quota_unit}
								class="rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none">
								<option value="MB">MB</option>
								<option value="GB">GB</option>
								<option value="TB">TB</option>
							</select>
						</div>
					</div>
					{#if teams.length > 0}
						<div>
							<label class="block text-sm font-medium text-gray-700 mb-1">Team Folders</label>
							<div class="space-y-2 border border-gray-200 rounded-md p-3">
								{#each teams as team}
									<div class="flex items-center justify-between">
										<span class="text-sm text-gray-700">{team.name}</span>
										<select value={editTeamSelections[team.id] || ''}
											onchange={(e) => { const v = (e.target as HTMLSelectElement).value; if (v) editTeamSelections[team.id] = v; else delete editTeamSelections[team.id]; editTeamSelections = { ...editTeamSelections }; }}
											class="rounded-md border border-gray-300 px-2 py-1 text-sm focus:border-blue-500 focus:outline-none">
											<option value="">No access</option>
											<option value="read">Read</option>
											<option value="write">Write</option>
											<option value="readwrite">Read & Write</option>
										</select>
									</div>
								{/each}
							</div>
						</div>
					{/if}
					<div class="border-t border-gray-100 pt-3">
						<p class="text-xs font-medium text-gray-500 uppercase tracking-wide mb-2">Reset Password (optional)</p>
						<div class="space-y-2">
							<input type="password" bind:value={editForm.newPassword} placeholder="New password"
								class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
							<input type="password" bind:value={editForm.confirmPassword} placeholder="Confirm password"
								class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500
								{editForm.confirmPassword && editForm.newPassword !== editForm.confirmPassword ? 'border-red-400 focus:border-red-400 focus:ring-red-400' : ''}" />
							{#if editForm.confirmPassword && editForm.newPassword !== editForm.confirmPassword}
								<p class="text-xs text-red-500">Passwords do not match</p>
							{/if}
						</div>
					</div>
				</div>

			{:else if editTab === 'tokens'}
				<div class="space-y-4">
					<p class="text-sm text-gray-600">Connection tokens allow users to connect the macOS app without manually entering server details. The token is encrypted with a 6-character PIN that is emailed to the user.</p>

					<div class="flex items-center gap-3 p-4 bg-gray-50 rounded-lg border border-gray-200">
						<Key size={24} class="text-gray-400 flex-shrink-0" />
						<div class="flex-1">
							{#if editTarget.has_token}
								<p class="text-sm font-medium text-gray-900">Token available</p>
								<p class="text-xs text-gray-500">One-time download — will be invalidated after download</p>
							{:else}
								<p class="text-sm font-medium text-gray-500">No active token</p>
								<p class="text-xs text-gray-400">Generate a new token to create a .syncvault file</p>
							{/if}
						</div>
					</div>

					<div class="flex gap-2">
						{#if editTarget.has_token}
							<button onclick={() => downloadToken(editTarget!)}
								class="flex items-center gap-2 rounded-md px-4 py-2 text-sm font-medium bg-green-500 hover:bg-green-600 text-white transition-colors">
								<Download size={14} /> Download .syncvault
							</button>
						{/if}
						<button onclick={() => refreshToken(editTarget!)}
							class="flex items-center gap-2 rounded-md px-4 py-2 text-sm font-medium bg-orange-500 hover:bg-orange-600 text-white transition-colors">
							<RefreshCw size={14} /> {editTarget.has_token ? 'Regenerate Token' : 'Generate Token'}
						</button>
					</div>
				</div>

			{:else if editTab === 'delete'}
				<div class="space-y-4">
					<div class="flex items-start gap-3 p-3 bg-red-50 rounded-lg border border-red-100">
						<Trash2 size={20} class="text-red-500 flex-shrink-0 mt-0.5" />
						<div>
							<p class="text-sm font-medium text-red-800">Permanently delete this user account</p>
							<p class="text-xs text-red-600 mt-1">This action cannot be undone. All data will be removed or transferred.</p>
						</div>
					</div>

					<div class="space-y-2">
						<label class="flex items-center gap-3 p-3 rounded-lg border cursor-pointer transition-colors {deleteAction === 'delete' ? 'border-red-300 bg-red-50' : 'border-gray-200 hover:bg-gray-50'}">
							<input type="radio" bind:group={deleteAction} value="delete" class="text-red-500 focus:ring-red-500" />
							<div>
								<span class="text-sm font-medium text-gray-900">Delete all files</span>
								<p class="text-xs text-gray-500">All files, versions, and shared links will be permanently deleted</p>
							</div>
						</label>
						<label class="flex items-center gap-3 p-3 rounded-lg border cursor-pointer transition-colors {deleteAction === 'transfer' ? 'border-blue-300 bg-blue-50' : 'border-gray-200 hover:bg-gray-50'}">
							<input type="radio" bind:group={deleteAction} value="transfer" class="text-blue-500 focus:ring-blue-500" />
							<div>
								<span class="text-sm font-medium text-gray-900">Transfer files to another user</span>
								<p class="text-xs text-gray-500">The user's folder will be moved to another user's home folder</p>
							</div>
						</label>
					</div>

					{#if deleteAction === 'transfer'}
						<div>
							<label class="block text-sm font-medium text-gray-700 mb-1">Transfer to</label>
							<select bind:value={transferToUserId} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500">
								<option value="">Select a user…</option>
								{#each users.filter(u => u.id !== editTarget?.id) as u}
									<option value={u.id}>{u.username}</option>
								{/each}
							</select>
						</div>
					{/if}

					<div class="border-t border-gray-100 pt-3">
						<label class="block text-sm font-medium text-gray-700 mb-1">Type <span class="font-bold text-red-600">DELETE</span> to confirm</label>
						<input type="text" bind:value={deleteConfirmText} placeholder="DELETE"
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-red-500 focus:outline-none focus:ring-1 focus:ring-red-500" />
					</div>

					<button onclick={doDelete}
						disabled={deleteConfirmText !== 'DELETE' || (deleteAction === 'transfer' && !transferToUserId)}
						class="w-full rounded-md px-4 py-2 text-sm font-medium text-white bg-red-600 hover:bg-red-700 disabled:bg-gray-300 disabled:cursor-not-allowed transition-colors">
						Delete User
					</button>
				</div>
			{/if}
		{/snippet}
		{#snippet footer()}
			{#if editTab === 'details'}
				<button onclick={() => { showEdit = false; editTarget = null; }}
					class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
				<button onclick={saveEdit}
					disabled={editing || !!(editForm.newPassword && editForm.newPassword !== editForm.confirmPassword)}
					class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors">
					{editing ? 'Saving…' : 'Save'}
				</button>
			{:else}
				<button onclick={() => { showEdit = false; editTarget = null; }}
					class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Close</button>
			{/if}
		{/snippet}
	</Modal>
{/if}
