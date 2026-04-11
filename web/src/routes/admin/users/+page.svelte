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

	let showCreate = $state(false);
	let createForm = $state({ username: '', email: '', password: '', role: 'user' });
	let creating = $state(false);

	let showEdit = $state(false);
	let editTarget = $state<UserRecord | null>(null);
	let editTab = $state<'details' | 'tokens' | 'delete'>('details');
	let editForm = $state({ email: '', role: 'user', storage_quota: '', storage_quota_unit: 'GB', newPassword: '', confirmPassword: '' });
	let editing = $state(false);
	let deleteConfirmText = $state('');
	let deleteAction = $state<'delete' | 'transfer'>('delete');
	let transferToUserId = $state('');

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

<div class="p-6" style="background: var(--bg-base); min-height: 100%;">
	<div class="mb-6 flex items-center justify-between">
		<div>
			<h1 class="text-base font-semibold" style="color: var(--text-primary);">Users</h1>
			<p class="text-sm mt-1" style="color: var(--text-tertiary);">{users.length} user{users.length !== 1 ? 's' : ''} total</p>
		</div>
		<button onclick={openCreate}
			class="flex items-center gap-2 bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-all duration-150">
			<UserPlus size={15} /> Create User
		</button>
	</div>

	<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
		{#if loading}
			<div class="px-4 py-3 border-b" style="border-color: var(--border);">
				<div class="flex gap-8">
					{#each [1,2,3,4] as _}
						<div class="skeleton h-3 rounded w-16"></div>
					{/each}
				</div>
			</div>
			{#each [1,2,3,4] as _}
				<div class="px-4 py-3.5 border-b flex items-center gap-3" style="border-color: var(--border);">
					<div class="skeleton w-8 h-8 rounded-full flex-shrink-0"></div>
					<div class="space-y-1.5 flex-1">
						<div class="skeleton h-3 rounded w-32"></div>
						<div class="skeleton h-2.5 rounded w-48"></div>
					</div>
					<div class="skeleton h-5 rounded-full w-12 ml-auto"></div>
				</div>
			{/each}
		{:else if users.length === 0}
			<div class="flex flex-col items-center justify-center py-20">
				<div class="w-14 h-14 rounded-2xl flex items-center justify-center mb-4" style="background: var(--bg-active);">
					<Users size={24} style="color: var(--text-tertiary);" />
				</div>
				<p class="text-base font-medium" style="color: var(--text-tertiary);">No users found</p>
			</div>
		{:else}
			<table class="min-w-full">
				<thead>
					<tr style="border-bottom: 1px solid var(--border);">
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">User</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: var(--text-tertiary);">Role</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden lg:table-cell" style="color: var(--text-tertiary);">Storage</th>
						<th class="px-4 py-3 text-right text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Actions</th>
					</tr>
				</thead>
				<tbody>
					{#each users as user}
						<tr class="user-row cursor-pointer" onclick={() => openEdit(user)}>
							<td class="px-4 py-3.5">
								<div class="flex items-center gap-3">
									<div class="w-8 h-8 rounded-full bg-blue-600/20 flex items-center justify-center text-blue-400 text-xs font-bold flex-shrink-0">
										{user.username[0].toUpperCase()}
									</div>
									<div>
										<p class="text-sm font-medium text-[var(--text-primary)]">{user.username}</p>
										<p class="text-xs" style="color: var(--text-tertiary);">{user.email}</p>
									</div>
								</div>
							</td>
							<td class="px-4 py-3.5 hidden sm:table-cell">
								<span class="inline-flex items-center gap-1 text-[11px] font-medium rounded-full px-2.5 py-0.5"
									style="{user.role === 'admin' ? 'background: rgba(168,85,247,0.12); color: #c084fc; border: 1px solid rgba(168,85,247,0.20);' : 'background: var(--bg-active); color: var(--text-secondary); border: 1px solid var(--border);'}">
									{#if user.role === 'admin'}<Shield size={10} />{:else}<User size={10} />{/if}
									{user.role}
								</span>
							</td>
							<td class="px-4 py-3.5 hidden lg:table-cell">
								{#if user.storage_quota}
									<div class="w-40"><StorageBar used={user.storage_used ?? 0} total={user.storage_quota} /></div>
								{:else}
									<span class="text-sm" style="color: var(--text-tertiary);">{formatBytes(user.storage_used ?? 0)}</span>
								{/if}
							</td>
							<td class="px-4 py-3.5">
								<div class="flex items-center justify-end gap-1">
									<button onclick={(e) => { e.stopPropagation(); openEdit(user); }}
										title="Edit user" class="p-1.5 text-[var(--text-tertiary)] hover:text-blue-400 rounded-md hover:bg-blue-500/10 transition-all">
										<Edit2 size={14} />
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
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Username</label>
					<input type="text" bind:value={createForm.username} />
				</div>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Email</label>
					<input type="email" bind:value={createForm.email} />
				</div>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Password</label>
					<input type="password" bind:value={createForm.password} />
				</div>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Role</label>
					<select bind:value={createForm.role}>
						<option value="user">User</option>
						<option value="admin">Admin</option>
					</select>
				</div>
				{#if teams.length > 0}
					<div>
						<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Team Folders</label>
						<div class="space-y-2 border rounded-lg p-3" style="border-color: var(--border); background: var(--bg-hover);">
							{#each teams as team}
								<div class="flex items-center justify-between gap-3">
									<span class="text-sm text-[var(--text-secondary)]">{team.name}</span>
									<select value={createTeamSelections[team.id] || ''}
										onchange={(e) => { const v = (e.target as HTMLSelectElement).value; if (v) createTeamSelections[team.id] = v; else delete createTeamSelections[team.id]; createTeamSelections = { ...createTeamSelections }; }}
										style="width: auto;">
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
			<button onclick={() => (showCreate = false)} class="px-4 py-2 text-sm font-medium text-[var(--text-secondary)] border rounded-lg hover:bg-[var(--bg-hover)] transition-all" style="border-color: var(--border);">Cancel</button>
			<button onclick={createUser} disabled={creating || !createForm.username || !createForm.password}
				class="px-4 py-2 text-sm font-medium bg-blue-600 hover:bg-blue-500 disabled:opacity-40 text-white rounded-lg transition-all">
				{creating ? 'Creating…' : 'Create'}
			</button>
		{/snippet}
	</Modal>
{/if}

<!-- Edit user modal -->
{#if showEdit && editTarget}
	<Modal title={editTarget.username} onclose={() => { showEdit = false; editTarget = null; }}>
		{#snippet children()}
			<!-- Tab bar -->
			<div class="flex gap-0 border-b -mx-6 px-6 mb-4" style="border-color: var(--border);">
				<button onclick={() => editTab = 'details'}
					class="px-4 py-2 text-sm font-medium border-b-2 transition-colors"
					style="{editTab === 'details' ? 'border-color: #3b82f6; color: #60a5fa;' : 'border-color: transparent; color: var(--text-tertiary);'}">
					Details
				</button>
				<button onclick={() => editTab = 'tokens'}
					class="px-4 py-2 text-sm font-medium border-b-2 transition-colors"
					style="{editTab === 'tokens' ? 'border-color: #3b82f6; color: #60a5fa;' : 'border-color: transparent; color: var(--text-tertiary);'}">
					Connection Token
				</button>
				<button onclick={() => { editTab = 'delete'; deleteConfirmText = ''; }}
					class="px-4 py-2 text-sm font-medium border-b-2 transition-colors"
					style="{editTab === 'delete' ? 'border-color: #ef4444; color: #f87171;' : 'border-color: transparent; color: var(--text-tertiary);'}">
					Delete
				</button>
			</div>

			{#if editTab === 'details'}
				<div class="space-y-3">
					<div>
						<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Username</label>
						<input type="text" value={editTarget.username} readonly style="opacity: 0.5; cursor: not-allowed;" />
					</div>
					<div>
						<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Email</label>
						<input type="email" bind:value={editForm.email} />
					</div>
					<div>
						<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Role</label>
						<select bind:value={editForm.role}>
							<option value="user">User</option>
							<option value="admin">Admin</option>
						</select>
					</div>
					<div>
						<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Storage quota (0 = unlimited)</label>
						<div class="flex items-center gap-2">
							<input type="number" min="0" bind:value={editForm.storage_quota} placeholder="0" style="width: 120px;" />
							<select bind:value={editForm.storage_quota_unit} style="width: auto;">
								<option value="MB">MB</option>
								<option value="GB">GB</option>
								<option value="TB">TB</option>
							</select>
						</div>
					</div>
					{#if teams.length > 0}
						<div>
							<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Team Folders</label>
							<div class="space-y-2 border rounded-lg p-3" style="border-color: var(--border); background: var(--bg-hover);">
								{#each teams as team}
									<div class="flex items-center justify-between gap-3">
										<span class="text-sm text-[var(--text-secondary)]">{team.name}</span>
										<select value={editTeamSelections[team.id] || ''}
											onchange={(e) => { const v = (e.target as HTMLSelectElement).value; if (v) editTeamSelections[team.id] = v; else delete editTeamSelections[team.id]; editTeamSelections = { ...editTeamSelections }; }}
											style="width: auto;">
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
					<div class="border-t pt-3" style="border-color: var(--border);">
						<p class="text-[10px] font-semibold uppercase tracking-wider mb-2" style="color: var(--text-tertiary);">Reset Password (optional)</p>
						<div class="space-y-2">
							<input type="password" bind:value={editForm.newPassword} placeholder="New password" />
							<input type="password" bind:value={editForm.confirmPassword} placeholder="Confirm password"
								style="{editForm.confirmPassword && editForm.newPassword !== editForm.confirmPassword ? 'border-color: #ef4444;' : ''}" />
							{#if editForm.confirmPassword && editForm.newPassword !== editForm.confirmPassword}
								<p class="text-xs text-red-400">Passwords do not match</p>
							{/if}
						</div>
					</div>
				</div>

			{:else if editTab === 'tokens'}
				<div class="space-y-4">
					<p class="text-sm" style="color: var(--text-secondary);">Connection tokens allow users to connect the macOS app without manually entering server details. The token is encrypted with a 6-character PIN that is emailed to the user.</p>

					<div class="flex items-center gap-3 p-4 rounded-lg border" style="background: var(--bg-hover); border-color: var(--border);">
						<Key size={20} style="color: var(--text-tertiary); flex-shrink: 0;" />
						<div class="flex-1">
							{#if editTarget.has_token}
								<p class="text-sm font-medium text-[var(--text-secondary)]">Token available</p>
								<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">One-time download — will be invalidated after download</p>
							{:else}
								<p class="text-sm font-medium" style="color: var(--text-tertiary);">No active token</p>
								<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">Generate a new token to create a .syncvault file</p>
							{/if}
						</div>
					</div>

					<div class="flex gap-2">
						{#if editTarget.has_token}
							<button onclick={() => downloadToken(editTarget!)}
								class="flex items-center gap-2 px-4 py-2 text-sm font-medium rounded-lg transition-all" style="background: rgba(34,197,94,0.12); color: #4ade80; border: 1px solid rgba(34,197,94,0.20);">
								<Download size={14} /> Download .syncvault
							</button>
						{/if}
						<button onclick={() => refreshToken(editTarget!)}
							class="flex items-center gap-2 px-4 py-2 text-sm font-medium rounded-lg transition-all" style="background: rgba(245,158,11,0.12); color: #fbbf24; border: 1px solid rgba(245,158,11,0.20);">
							<RefreshCw size={14} /> {editTarget.has_token ? 'Regenerate Token' : 'Generate Token'}
						</button>
					</div>
				</div>

			{:else if editTab === 'delete'}
				<div class="space-y-4">
					<div class="flex items-start gap-3 p-3 rounded-lg border" style="background: rgba(239,68,68,0.08); border-color: rgba(239,68,68,0.20);">
						<Trash2 size={18} class="text-red-400 flex-shrink-0 mt-0.5" />
						<div>
							<p class="text-sm font-medium text-red-300">Permanently delete this user account</p>
							<p class="text-xs mt-1 text-red-400/70">This action cannot be undone. All data will be removed or transferred.</p>
						</div>
					</div>

					<div class="space-y-2">
						<label class="flex items-center gap-3 p-3 rounded-lg border cursor-pointer transition-colors"
							style="{deleteAction === 'delete' ? 'border-color: rgba(239,68,68,0.30); background: rgba(239,68,68,0.06);' : 'border-color: var(--border); background: var(--bg-hover);'}">
							<input type="radio" bind:group={deleteAction} value="delete" />
							<div>
								<span class="text-sm font-medium text-[var(--text-secondary)]">Delete all files</span>
								<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">All files, versions, and shared links will be permanently deleted</p>
							</div>
						</label>
						<label class="flex items-center gap-3 p-3 rounded-lg border cursor-pointer transition-colors"
							style="{deleteAction === 'transfer' ? 'border-color: rgba(59,130,246,0.30); background: rgba(59,130,246,0.06);' : 'border-color: var(--border); background: var(--bg-hover);'}">
							<input type="radio" bind:group={deleteAction} value="transfer" />
							<div>
								<span class="text-sm font-medium text-[var(--text-secondary)]">Transfer files to another user</span>
								<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">The user's folder will be moved to another user's home folder</p>
							</div>
						</label>
					</div>

					{#if deleteAction === 'transfer'}
						<div>
							<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Transfer to</label>
							<select bind:value={transferToUserId}>
								<option value="">Select a user…</option>
								{#each users.filter(u => u.id !== editTarget?.id) as u}
									<option value={u.id}>{u.username}</option>
								{/each}
							</select>
						</div>
					{/if}

					<div class="border-t pt-3" style="border-color: var(--border);">
						<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Type <span class="font-bold text-red-400">DELETE</span> to confirm</label>
						<input type="text" bind:value={deleteConfirmText} placeholder="DELETE" style="border-color: rgba(239,68,68,0.25);" />
					</div>

					<button onclick={doDelete}
						disabled={deleteConfirmText !== 'DELETE' || (deleteAction === 'transfer' && !transferToUserId)}
						class="w-full px-4 py-2 text-sm font-medium rounded-lg transition-all bg-red-600/10 text-red-400 hover:bg-red-600/20 border border-red-500/20 disabled:opacity-30 disabled:cursor-not-allowed">
						Delete User
					</button>
				</div>
			{/if}
		{/snippet}
		{#snippet footer()}
			{#if editTab === 'details'}
				<button onclick={() => { showEdit = false; editTarget = null; }} class="px-4 py-2 text-sm font-medium text-[var(--text-secondary)] border rounded-lg hover:bg-[var(--bg-hover)] transition-all" style="border-color: var(--border);">Cancel</button>
				<button onclick={saveEdit}
					disabled={editing || !!(editForm.newPassword && editForm.newPassword !== editForm.confirmPassword)}
					class="px-4 py-2 text-sm font-medium bg-blue-600 hover:bg-blue-500 disabled:opacity-40 text-white rounded-lg transition-all">
					{editing ? 'Saving…' : 'Save'}
				</button>
			{:else}
				<button onclick={() => { showEdit = false; editTarget = null; }} class="px-4 py-2 text-sm font-medium text-[var(--text-secondary)] border rounded-lg hover:bg-[var(--bg-hover)] transition-all" style="border-color: var(--border);">Close</button>
			{/if}
		{/snippet}
	</Modal>
{/if}

<style>
	.user-row {
		border-bottom: 1px solid var(--border);
	}
	.user-row:hover {
		background: var(--bg-hover);
	}
	.user-row:last-child {
		border-bottom: none;
	}
</style>
