<script lang="ts">
	import { onMount } from 'svelte';
	import { FolderTree, Plus, Trash2, ChevronDown, ChevronRight, UserPlus, X } from 'lucide-svelte';
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

	let showDeleteTeam = $state(false);
	let deleteTeamTarget = $state<Team | null>(null);

	onMount(loadTeams);

	async function loadTeams() {
		loading = true;
		try {
			const res = await api.get('/api/admin/teams');
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
			const res = await api.get(`/api/admin/teams/${teamId}/members`);
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
			const res = await api.post('/api/admin/teams', { name: newTeamName.trim() });
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
		addingMember = true;
		try {
			const res = await api.post(`/api/admin/teams/${showAddMember}/members`, {
				user_id: addMemberUserId,
				permission: addMemberPermission
			});
			if (res.ok) {
				showToast('Member added', 'success');
				showAddMember = null;
				loadMembers(showAddMember ?? expandedTeam ?? '');
			} else {
				showToast('Failed to add member', 'error');
			}
		} finally {
			addingMember = false;
		}
	}

	async function updatePermission(teamId: string, userId: string, permission: string) {
		const res = await api.put(`/api/admin/teams/${teamId}/members/${userId}`, { permission });
		if (res.ok) {
			showToast('Permission updated', 'success');
			loadMembers(teamId);
		} else {
			showToast('Failed to update permission', 'error');
		}
	}

	async function removeMember(teamId: string, userId: string) {
		const res = await api.delete(`/api/admin/teams/${teamId}/members/${userId}`);
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

	async function deleteTeam() {
		if (!deleteTeamTarget) return;
		const res = await api.delete(`/api/admin/teams/${deleteTeamTarget.id}`);
		if (res.ok) {
			showToast('Team deleted', 'success');
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
									onclick={() => openAddMember(team.id)}
									title="Add member"
									class="p-1.5 text-gray-400 hover:text-blue-600 rounded hover:bg-gray-100 transition-colors"
								>
									<UserPlus size={15} />
								</button>
								<button
									onclick={() => { deleteTeamTarget = team; showDeleteTeam = true; }}
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
															<option value="admin">Admin</option>
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
						<option value="admin">Admin</option>
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

<!-- Delete team confirm -->
{#if showDeleteTeam && deleteTeamTarget}
	<ConfirmDialog
		title="Delete Team"
		message="Delete team '{deleteTeamTarget.name}'? Members will lose team-based access."
		confirmLabel="Delete Team"
		onconfirm={deleteTeam}
		oncancel={() => { showDeleteTeam = false; deleteTeamTarget = null; }}
	/>
{/if}
