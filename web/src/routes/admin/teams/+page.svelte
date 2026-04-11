<script lang="ts">
	import { onMount } from 'svelte';
	import { FolderTree, Plus, Trash2, ChevronDown, ChevronRight, UserPlus, X, AlertTriangle, Edit2 } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import Modal from '$lib/components/Modal.svelte';

	interface Member {
		user_id: string;
		username: string;
		permission: string;
	}

	interface Team {
		id: string;
		name: string;
		member_count?: number;
		members?: Member[];
	}

	interface UserOption {
		id: string;
		username: string;
	}

	let teams = $state<Team[]>([]);
	let loading = $state(true);
	let expandedTeam = $state<string | null>(null);
	let teamMembers = $state<Record<string, Member[]>>({});
	let loadingMembers = $state<Record<string, boolean>>({});

	let showCreate = $state(false);
	let newTeamName = $state('');
	let creating = $state(false);

	let showAddMember = $state<string | null>(null); // team id
	let allUsers = $state<UserOption[]>([]);
	let addMemberUserId = $state('');
	let addMemberPermission = $state('read');
	let addingMember = $state(false);

	// Edit team
	let showEditTeam = $state(false);
	let editTeamTarget = $state<Team | null>(null);
	let editTeamName = $state('');
	let editTeamQuota = $state('');
	let editTeamQuotaUnit = $state('GB');
	let editingTeam = $state(false);

	function openEditTeam(team: Team) {
		editTeamTarget = team;
		editTeamName = team.name;
		const qb = (team as any).quota_bytes || 0;
		if (qb >= 1099511627776) { editTeamQuota = String(Math.round(qb / 1099511627776)); editTeamQuotaUnit = 'TB'; }
		else if (qb >= 1073741824) { editTeamQuota = String(Math.round(qb / 1073741824)); editTeamQuotaUnit = 'GB'; }
		else if (qb >= 1048576) { editTeamQuota = String(Math.round(qb / 1048576)); editTeamQuotaUnit = 'MB'; }
		else { editTeamQuota = qb > 0 ? String(qb) : ''; editTeamQuotaUnit = 'GB'; }
		showEditTeam = true;
	}

	async function saveEditTeam() {
		if (!editTeamTarget) return;
		editingTeam = true;
		try {
			let quotaBytes = 0;
			if (editTeamQuota) {
				const val = parseFloat(editTeamQuota);
				if (editTeamQuotaUnit === 'TB') quotaBytes = val * 1099511627776;
				else if (editTeamQuotaUnit === 'GB') quotaBytes = val * 1073741824;
				else quotaBytes = val * 1048576;
			}
			const res = await api.put(`/api/teams/${editTeamTarget.id}`, { name: editTeamName, quota_bytes: Math.round(quotaBytes) });
			if (res.ok) {
				showToast('Team updated', 'success');
				showEditTeam = false;
				loadTeams();
			} else {
				showToast('Failed to update team', 'error');
			}
		} finally {
			editingTeam = false;
		}
	}

	let showDeleteTeam = $state(false);
	let deleteTeamTarget = $state<Team | null>(null);
	let deleteAction = $state<'delete' | 'transfer'>('delete');
	let transferUserId = $state('');

	onMount(loadTeams);

	async function loadTeams() {
		loading = true;
		try {
			const res = await api.get('/api/teams');
			if (res.ok) {
				const data = await res.json();
				teams = data.teams || data || [];
			} else {
				showToast('Failed to load teams', 'error');
			}
		} finally {
			loading = false;
		}
	}

	async function loadMembers(teamId: string) {
		loadingMembers = { ...loadingMembers, [teamId]: true };
		try {
			const res = await api.get(`/api/teams/${teamId}/members`);
			if (res.ok) {
				const data = await res.json();
				teamMembers = { ...teamMembers, [teamId]: data.members || data || [] };
			}
		} finally {
			loadingMembers = { ...loadingMembers, [teamId]: false };
		}
	}

	function toggleTeam(teamId: string) {
		if (expandedTeam === teamId) {
			expandedTeam = null;
		} else {
			expandedTeam = teamId;
			if (!teamMembers[teamId]) loadMembers(teamId);
		}
	}

	async function createTeam() {
		if (!newTeamName.trim()) return;
		creating = true;
		try {
			const res = await api.post('/api/teams', { name: newTeamName.trim() });
			if (res.ok) {
				showToast('Team created', 'success');
				showCreate = false;
				newTeamName = '';
				loadTeams();
			} else {
				showToast('Failed to create team', 'error');
			}
		} finally {
			creating = false;
		}
	}

	async function openAddMember(teamId: string) {
		showAddMember = teamId;
		addMemberUserId = '';
		addMemberPermission = 'read';
		if (allUsers.length === 0) {
			const res = await api.get('/api/admin/users');
			if (res.ok) {
				const data = await res.json();
				allUsers = (data.users || data || []).map((u: { id: string; username: string }) => ({
					id: u.id,
					username: u.username
				}));
			}
		}
	}

	async function addMember() {
		if (!showAddMember || !addMemberUserId) return;
		const teamId = showAddMember;
		addingMember = true;
		try {
			const res = await api.put(`/api/teams/${teamId}/members/${addMemberUserId}`, {
				permission: addMemberPermission
			});
			if (res.ok) {
				showToast('Member added', 'success');
				showAddMember = null;
				loadMembers(teamId);
			} else {
				showToast('Failed to add member', 'error');
			}
		} finally {
			addingMember = false;
		}
	}

	async function updatePermission(teamId: string, userId: string, permission: string) {
		const res = await api.put(`/api/teams/${teamId}/members/${userId}`, { permission });
		if (res.ok) {
			showToast('Permission updated', 'success');
			loadMembers(teamId);
		} else {
			showToast('Failed to update permission', 'error');
		}
	}

	async function removeMember(teamId: string, userId: string) {
		const res = await api.delete(`/api/teams/${teamId}/members/${userId}`);
		if (res.ok) {
			showToast('Member removed', 'success');
			teamMembers = {
				...teamMembers,
				[teamId]: teamMembers[teamId]?.filter((m) => m.user_id !== userId) || []
			};
		} else {
			showToast('Failed to remove member', 'error');
		}
	}

	function openDeleteTeam(team: Team) {
		deleteTeamTarget = team;
		deleteAction = 'delete';
		transferUserId = '';
		showDeleteTeam = true;
		if (allUsers.length === 0) {
			api.get('/api/admin/users').then(async (res) => {
				if (res.ok) {
					const data = await res.json();
					allUsers = (data.users || data || []).map((u: { id: string; username: string }) => ({
						id: u.id,
						username: u.username
					}));
				}
			});
		}
	}

	async function deleteTeam() {
		if (!deleteTeamTarget) return;

		if (deleteAction === 'transfer' && transferUserId) {
			const res = await api.post(`/api/teams/${deleteTeamTarget.id}/transfer`, { user_id: transferUserId });
			if (!res.ok) {
				showToast('Failed to transfer folder', 'error');
				return;
			}
		}

		const res = await api.delete(`/api/teams/${deleteTeamTarget.id}`);
		if (res.ok) {
			showToast(deleteAction === 'transfer' ? 'Team deleted, folder transferred' : 'Team and folder deleted', 'success');
			teams = teams.filter((t) => t.id !== deleteTeamTarget!.id);
			showDeleteTeam = false;
			deleteTeamTarget = null;
		} else {
			showToast('Failed to delete team', 'error');
		}
	}
</script>

<svelte:head>
	<title>Teams — SyncVault Admin</title>
</svelte:head>

<div class="p-6 space-y-5" style="background: var(--bg-base); min-height: 100%;">
	<div class="flex items-center justify-between">
		<div>
			<h1 class="text-base font-semibold" style="color: var(--text-primary);">Teams</h1>
			<p class="text-sm mt-1" style="color: var(--text-tertiary);">Manage team access and permissions.</p>
		</div>
		<button
			onclick={() => (showCreate = true)}
			class="flex items-center gap-2 bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-all duration-150"
		>
			<Plus size={15} /> Create Team
		</button>
	</div>

	<div class="rounded-xl border overflow-hidden" style="background: var(--bg-elevated); border-color: var(--border);">
		{#if loading}
			<div class="space-y-0">
				{#each [1,2,3] as _}
					<div class="flex items-center gap-3 px-4 py-3.5 border-b" style="border-color: var(--border);">
						<div class="skeleton h-4 rounded w-4"></div>
						<div class="skeleton h-4 rounded w-4"></div>
						<div class="skeleton h-4 rounded w-32"></div>
						<div class="skeleton h-4 rounded w-16 ml-2"></div>
					</div>
				{/each}
			</div>
		{:else if teams.length === 0}
			<div class="text-center py-16">
				<FolderTree size={40} style="color: var(--text-tertiary); margin: 0 auto 12px;" />
				<p class="text-sm font-medium text-[var(--text-tertiary)]">No teams yet</p>
				<p class="text-xs mt-1" style="color: var(--text-tertiary);">Create a team to manage group access.</p>
			</div>
		{:else}
			<div>
				{#each teams as team, i}
					<div class="team-group" class:border-b={i < teams.length - 1}>
						<!-- Team row -->
						<div class="flex items-center gap-2 px-4 py-3.5 team-row">
							<button
								onclick={() => toggleTeam(team.id)}
								class="flex items-center gap-2.5 flex-1 text-left min-w-0"
							>
								{#if expandedTeam === team.id}
									<ChevronDown size={14} style="color: var(--text-tertiary); flex-shrink: 0;" />
								{:else}
									<ChevronRight size={14} style="color: var(--text-tertiary); flex-shrink: 0;" />
								{/if}
								<FolderTree size={16} class="text-blue-400 flex-shrink-0" />
								<span class="text-sm font-medium text-[var(--text-primary)] truncate">{team.name}</span>
								<span class="text-xs flex-shrink-0" style="color: var(--text-tertiary);">
									{team.member_count ?? teamMembers[team.id]?.length ?? 0} members
								</span>
							</button>
							<div class="flex items-center gap-0.5 flex-shrink-0">
								<button
									onclick={() => openEditTeam(team)}
									title="Edit team"
									class="p-1.5 rounded-md transition-colors"
									style="color: var(--text-tertiary);"
									onmouseenter={(e) => (e.currentTarget as HTMLElement).style.background = 'var(--bg-active)'}
									onmouseleave={(e) => (e.currentTarget as HTMLElement).style.background = ''}
								>
									<Edit2 size={14} />
								</button>
								<button
									onclick={() => openAddMember(team.id)}
									title="Add member"
									class="p-1.5 rounded-md text-blue-400 transition-colors"
									onmouseenter={(e) => (e.currentTarget as HTMLElement).style.background = 'rgba(59,130,246,0.10)'}
									onmouseleave={(e) => (e.currentTarget as HTMLElement).style.background = ''}
								>
									<UserPlus size={14} />
								</button>
								<button
									onclick={() => openDeleteTeam(team)}
									title="Delete team"
									class="p-1.5 rounded-md text-red-400 transition-colors"
									onmouseenter={(e) => (e.currentTarget as HTMLElement).style.background = 'rgba(239,68,68,0.10)'}
									onmouseleave={(e) => (e.currentTarget as HTMLElement).style.background = ''}
								>
									<Trash2 size={14} />
								</button>
							</div>
						</div>

						<!-- Members list (expanded) -->
						{#if expandedTeam === team.id}
							<div style="background: var(--bg-hover); border-top: 1px solid var(--border);">
								{#if loadingMembers[team.id]}
									<div class="flex items-center justify-center py-6">
										<div class="w-4 h-4 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
									</div>
								{:else if !teamMembers[team.id] || teamMembers[team.id].length === 0}
									<p class="px-10 py-4 text-sm" style="color: var(--text-tertiary);">No members yet. Add one using the button above.</p>
								{:else}
									<table class="min-w-full">
										<thead>
											<tr style="border-bottom: 1px solid var(--border);">
												<th class="px-10 py-2 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Member</th>
												<th class="px-4 py-2 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-tertiary);">Permission</th>
												<th class="px-4 py-2 w-10"></th>
											</tr>
										</thead>
										<tbody>
											{#each teamMembers[team.id] as member}
												<tr class="member-row">
													<td class="px-10 py-2.5">
														<span class="text-sm text-[var(--text-secondary)]">{member.username}</span>
													</td>
													<td class="px-4 py-2.5">
														<select
															value={member.permission}
															onchange={(e) => updatePermission(team.id, member.user_id, (e.target as HTMLSelectElement).value)}
															class="text-sm rounded-lg px-2 py-1"
															style="background: var(--bg-active); border: 1px solid var(--border); color: var(--text-secondary);"
														>
															<option value="read">Read</option>
															<option value="write">Write</option>
															<option value="readwrite">Read & Write</option>
														</select>
													</td>
													<td class="px-4 py-2.5">
														<button
															onclick={() => removeMember(team.id, member.user_id)}
															class="p-1 rounded transition-colors text-red-400"
															onmouseenter={(e) => (e.currentTarget as HTMLElement).style.background = 'rgba(239,68,68,0.10)'}
															onmouseleave={(e) => (e.currentTarget as HTMLElement).style.background = ''}
														>
															<X size={13} />
														</button>
													</td>
												</tr>
											{/each}
										</tbody>
									</table>
								{/if}
							</div>
						{/if}
					</div>
				{/each}
			</div>
		{/if}
	</div>
</div>

<!-- Create team modal -->
{#if showCreate}
	<Modal title="Create Team" onclose={() => (showCreate = false)}>
		{#snippet children()}
			<div>
				<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Team name</label>
				<input type="text" bind:value={newTeamName} placeholder="Engineering, Design, etc." onkeydown={(e) => e.key === 'Enter' && createTeam()} />
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showCreate = false)} class="rounded-lg px-4 py-2 text-sm font-medium transition-all duration-150 text-[var(--text-secondary)]" style="background: var(--bg-active); border: 1px solid var(--border);">Cancel</button>
			<button onclick={createTeam} disabled={creating || !newTeamName.trim()} class="rounded-lg px-4 py-2 text-sm font-medium bg-blue-600 hover:bg-blue-500 disabled:opacity-50 text-white transition-all duration-150">
				{creating ? 'Creating…' : 'Create'}
			</button>
		{/snippet}
	</Modal>
{/if}

<!-- Add member modal -->
{#if showAddMember}
	<Modal title="Add Member" onclose={() => (showAddMember = null)}>
		{#snippet children()}
			<div class="space-y-3">
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">User</label>
					<select bind:value={addMemberUserId}>
						<option value="">Select a user…</option>
						{#each allUsers as u}
							<option value={u.id}>{u.username}</option>
						{/each}
					</select>
				</div>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Permission</label>
					<select bind:value={addMemberPermission}>
						<option value="read">Read</option>
						<option value="write">Write</option>
						<option value="readwrite">Read & Write</option>
					</select>
				</div>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showAddMember = null)} class="rounded-lg px-4 py-2 text-sm font-medium transition-all duration-150 text-[var(--text-secondary)]" style="background: var(--bg-active); border: 1px solid var(--border);">Cancel</button>
			<button onclick={addMember} disabled={addingMember || !addMemberUserId} class="rounded-lg px-4 py-2 text-sm font-medium bg-blue-600 hover:bg-blue-500 disabled:opacity-50 text-white transition-all duration-150">
				{addingMember ? 'Adding…' : 'Add Member'}
			</button>
		{/snippet}
	</Modal>
{/if}

<!-- Edit team modal -->
{#if showEditTeam && editTeamTarget}
	<Modal title="Edit Team: {editTeamTarget.name}" onclose={() => (showEditTeam = false)}>
		{#snippet children()}
			<div class="space-y-3">
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Team name</label>
					<input type="text" bind:value={editTeamName} />
				</div>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Storage quota (0 = unlimited)</label>
					<div class="flex items-center gap-2">
						<input type="number" min="0" bind:value={editTeamQuota} placeholder="0" class="w-32" />
						<select bind:value={editTeamQuotaUnit} class="w-24">
							<option value="MB">MB</option>
							<option value="GB">GB</option>
							<option value="TB">TB</option>
						</select>
					</div>
				</div>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showEditTeam = false)} class="rounded-lg px-4 py-2 text-sm font-medium transition-all duration-150 text-[var(--text-secondary)]" style="background: var(--bg-active); border: 1px solid var(--border);">Cancel</button>
			<button onclick={saveEditTeam} disabled={editingTeam || !editTeamName.trim()} class="rounded-lg px-4 py-2 text-sm font-medium bg-blue-600 hover:bg-blue-500 disabled:opacity-50 text-white transition-all duration-150">
				{editingTeam ? 'Saving…' : 'Save'}
			</button>
		{/snippet}
	</Modal>
{/if}

<!-- Delete team confirm -->
{#if showDeleteTeam && deleteTeamTarget}
	<Modal title="Delete Team: {deleteTeamTarget.name}" onclose={() => { showDeleteTeam = false; deleteTeamTarget = null; }}>
		{#snippet children()}
			<div class="space-y-4">
				<div class="flex items-start gap-3 p-3 rounded-lg border" style="background: rgba(239,68,68,0.07); border-color: rgba(239,68,68,0.20);">
					<AlertTriangle size={18} class="text-red-400 flex-shrink-0 mt-0.5" />
					<div>
						<p class="text-sm font-medium text-red-400">This will permanently delete the team</p>
						<p class="text-xs mt-1 text-red-400/70">All members will lose access. The team folder "Team-{deleteTeamTarget.name}" and its contents will also be affected.</p>
					</div>
				</div>

				<div class="space-y-2">
					<label
						class="flex items-center gap-3 p-3 rounded-lg border cursor-pointer transition-colors"
						style="{deleteAction === 'delete' ? 'border-color: rgba(239,68,68,0.30); background: rgba(239,68,68,0.07);' : 'border-color: var(--border);'}"
					>
						<input type="radio" bind:group={deleteAction} value="delete" />
						<div>
							<span class="text-sm font-medium text-[var(--text-secondary)]">Delete folder and all files</span>
							<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">Everything in Team-{deleteTeamTarget.name} will be permanently deleted</p>
						</div>
					</label>

					<label
						class="flex items-center gap-3 p-3 rounded-lg border cursor-pointer transition-colors"
						style="{deleteAction === 'transfer' ? 'border-color: rgba(59,130,246,0.30); background: rgba(59,130,246,0.07);' : 'border-color: var(--border);'}"
					>
						<input type="radio" bind:group={deleteAction} value="transfer" />
						<div>
							<span class="text-sm font-medium text-[var(--text-secondary)]">Transfer folder to a user</span>
							<p class="text-xs mt-0.5" style="color: var(--text-tertiary);">The folder becomes a personal folder of the selected user</p>
						</div>
					</label>
				</div>

				{#if deleteAction === 'transfer'}
					<div>
						<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Transfer to</label>
						<select bind:value={transferUserId}>
							<option value="">Select a user…</option>
							{#each allUsers as u}
								<option value={u.id}>{u.username}</option>
							{/each}
						</select>
					</div>
				{/if}
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => { showDeleteTeam = false; deleteTeamTarget = null; }}
				class="rounded-lg px-4 py-2 text-sm font-medium transition-all duration-150 text-[var(--text-secondary)]"
				style="background: var(--bg-active); border: 1px solid var(--border);">Cancel</button>
			<button onclick={deleteTeam}
				disabled={deleteAction === 'transfer' && !transferUserId}
				class="rounded-lg px-4 py-2 text-sm font-medium text-white transition-all duration-150 disabled:opacity-50"
				style="{deleteAction === 'delete' ? 'background: rgba(239,68,68,0.80);' : 'background: #2563eb;'}"
>
				{deleteAction === 'delete' ? 'Delete Team & Files' : 'Transfer & Delete Team'}
			</button>
		{/snippet}
	</Modal>
{/if}

<style>
	.team-group {
		border-bottom: 1px solid var(--border);
	}
	.team-group:last-child {
		border-bottom: none;
	}
	.team-row:hover {
		background: var(--bg-hover);
	}
	.member-row {
		border-bottom: 1px solid var(--border);
	}
	.member-row:last-child {
		border-bottom: none;
	}
	.member-row:hover {
		background: var(--bg-hover);
	}
</style>
