<script lang="ts">
	import { onMount } from 'svelte';
	import { FolderTree, Plus, Trash2, ChevronDown, ChevronRight, UserPlus, X, AlertTriangle, Edit2 } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import Modal from '$lib/components/Modal.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';

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
		// Load users for transfer option
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

		// If transferring, move the team folder to the selected user first
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

<div class="p-6">
	<div class="mb-6 flex items-center justify-between">
		<div>
			<h1 class="text-xl font-semibold text-gray-900">Teams</h1>
			<p class="text-sm text-gray-500 mt-1">Manage team access and permissions.</p>
		</div>
		<button
			onclick={() => (showCreate = true)}
			class="flex items-center gap-2 bg-blue-500 hover:bg-blue-600 text-white text-sm font-medium rounded-md px-4 py-2 transition-colors"
		>
			<Plus size={16} /> Create Team
		</button>
	</div>

	<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
		{#if loading}
			<div class="flex items-center justify-center py-16">
				<div class="w-7 h-7 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
			</div>
		{:else if teams.length === 0}
			<div class="text-center py-16 text-gray-400">
				<FolderTree size={48} class="mx-auto mb-3 opacity-30" />
				<p class="text-base font-medium">No teams yet</p>
				<p class="text-sm mt-1">Create a team to manage group access.</p>
			</div>
		{:else}
			<div class="divide-y divide-gray-200">
				{#each teams as team}
					<div>
						<!-- Team row -->
						<div class="flex items-center gap-3 px-4 py-3 hover:bg-gray-50 transition-colors">
							<button
								onclick={() => toggleTeam(team.id)}
								class="flex items-center gap-3 flex-1 text-left"
							>
								{#if expandedTeam === team.id}
									<ChevronDown size={16} class="text-gray-400 flex-shrink-0" />
								{:else}
									<ChevronRight size={16} class="text-gray-400 flex-shrink-0" />
								{/if}
								<FolderTree size={18} class="text-blue-500 flex-shrink-0" />
								<span class="text-sm font-medium text-gray-900">{team.name}</span>
								<span class="text-xs text-gray-500 ml-1">
									({team.member_count ?? teamMembers[team.id]?.length ?? 0} members)
								</span>
							</button>
							<div class="flex items-center gap-1">
								<button
									onclick={() => openEditTeam(team)}
									title="Edit team"
									class="p-1.5 text-gray-400 hover:text-blue-600 rounded hover:bg-gray-100 transition-colors"
								>
									<Edit2 size={15} />
								</button>
								<button
									onclick={() => openAddMember(team.id)}
									title="Add member"
									class="p-1.5 text-gray-400 hover:text-blue-600 rounded hover:bg-gray-100 transition-colors"
								>
									<UserPlus size={15} />
								</button>
								<button
									onclick={() => openDeleteTeam(team)}
									title="Delete team"
									class="p-1.5 text-gray-400 hover:text-red-600 rounded hover:bg-gray-100 transition-colors"
								>
									<Trash2 size={15} />
								</button>
							</div>
						</div>

						<!-- Members list (expanded) -->
						{#if expandedTeam === team.id}
							<div class="bg-gray-50 border-t border-gray-100">
								{#if loadingMembers[team.id]}
									<div class="flex items-center justify-center py-6">
										<div class="w-5 h-5 border-2 border-blue-400 border-t-transparent rounded-full animate-spin"></div>
									</div>
								{:else if !teamMembers[team.id] || teamMembers[team.id].length === 0}
									<p class="px-10 py-4 text-sm text-gray-400">No members yet. Add one using the button above.</p>
								{:else}
									<table class="min-w-full">
										<thead>
											<tr class="text-xs text-gray-400 uppercase tracking-wider">
												<th class="px-10 py-2 text-left">Member</th>
												<th class="px-4 py-2 text-left">Permission</th>
												<th class="px-4 py-2 w-10"></th>
											</tr>
										</thead>
										<tbody class="divide-y divide-gray-100">
											{#each teamMembers[team.id] as member}
												<tr class="hover:bg-gray-100/50">
													<td class="px-10 py-2">
														<span class="text-sm text-gray-800">{member.username}</span>
													</td>
													<td class="px-4 py-2">
														<select
															value={member.permission}
															onchange={(e) => updatePermission(team.id, member.user_id, (e.target as HTMLSelectElement).value)}
															class="text-sm border border-gray-300 rounded-md px-2 py-1 focus:border-blue-500 focus:outline-none"
														>
															<option value="read">Read</option>
															<option value="write">Write</option>
															<option value="readwrite">Read & Write</option>
														</select>
													</td>
													<td class="px-4 py-2">
														<button
															onclick={() => removeMember(team.id, member.user_id)}
															class="p-1 text-gray-400 hover:text-red-500 transition-colors"
														>
															<X size={14} />
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
				<label class="block text-sm font-medium text-gray-700 mb-1">Team name</label>
				<input type="text" bind:value={newTeamName} placeholder="Engineering, Design, etc." class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" onkeydown={(e) => e.key === 'Enter' && createTeam()} />
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showCreate = false)} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={createTeam} disabled={creating || !newTeamName.trim()} class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors">
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
					<label class="block text-sm font-medium text-gray-700 mb-1">User</label>
					<select bind:value={addMemberUserId} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500">
						<option value="">Select a user…</option>
						{#each allUsers as u}
							<option value={u.id}>{u.username}</option>
						{/each}
					</select>
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Permission</label>
					<select bind:value={addMemberPermission} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500">
						<option value="read">Read</option>
						<option value="write">Write</option>
						<option value="readwrite">Read & Write</option>
					</select>
				</div>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showAddMember = null)} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={addMember} disabled={addingMember || !addMemberUserId} class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors">
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
					<label class="block text-sm font-medium text-gray-700 mb-1">Team name</label>
					<input type="text" bind:value={editTeamName} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Storage quota (0 = unlimited)</label>
					<div class="flex items-center gap-2">
						<input type="number" min="0" bind:value={editTeamQuota} placeholder="0"
							class="w-32 rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
						<select bind:value={editTeamQuotaUnit}
							class="rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none">
							<option value="MB">MB</option>
							<option value="GB">GB</option>
							<option value="TB">TB</option>
						</select>
					</div>
				</div>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showEditTeam = false)} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={saveEditTeam} disabled={editingTeam || !editTeamName.trim()} class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors">
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
				<div class="flex items-start gap-3 p-3 bg-red-50 rounded-lg border border-red-100">
					<AlertTriangle size={20} class="text-red-500 flex-shrink-0 mt-0.5" />
					<div>
						<p class="text-sm font-medium text-red-800">This will permanently delete the team</p>
						<p class="text-xs text-red-600 mt-1">All members will lose access. The team folder "Team-{deleteTeamTarget.name}" and its contents will also be affected.</p>
					</div>
				</div>

				<div class="space-y-2">
					<label class="flex items-center gap-3 p-3 rounded-lg border cursor-pointer transition-colors {deleteAction === 'delete' ? 'border-red-300 bg-red-50' : 'border-gray-200 hover:bg-gray-50'}">
						<input type="radio" bind:group={deleteAction} value="delete" class="text-red-500 focus:ring-red-500" />
						<div>
							<span class="text-sm font-medium text-gray-900">Delete folder and all files</span>
							<p class="text-xs text-gray-500">Everything in Team-{deleteTeamTarget.name} will be permanently deleted</p>
						</div>
					</label>

					<label class="flex items-center gap-3 p-3 rounded-lg border cursor-pointer transition-colors {deleteAction === 'transfer' ? 'border-blue-300 bg-blue-50' : 'border-gray-200 hover:bg-gray-50'}">
						<input type="radio" bind:group={deleteAction} value="transfer" class="text-blue-500 focus:ring-blue-500" />
						<div>
							<span class="text-sm font-medium text-gray-900">Transfer folder to a user</span>
							<p class="text-xs text-gray-500">The folder becomes a personal folder of the selected user</p>
						</div>
					</label>
				</div>

				{#if deleteAction === 'transfer'}
					<div>
						<label class="block text-sm font-medium text-gray-700 mb-1">Transfer to</label>
						<select bind:value={transferUserId} class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500">
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
				class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button onclick={deleteTeam}
				disabled={deleteAction === 'transfer' && !transferUserId}
				class="rounded-md px-4 py-2 text-sm font-medium text-white transition-colors disabled:opacity-50
				{deleteAction === 'delete' ? 'bg-red-500 hover:bg-red-600' : 'bg-blue-500 hover:bg-blue-600'}">
				{deleteAction === 'delete' ? 'Delete Team & Files' : 'Transfer & Delete Team'}
			</button>
		{/snippet}
	</Modal>
{/if}
