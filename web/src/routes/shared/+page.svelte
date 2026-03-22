<script lang="ts">
	import { onMount } from 'svelte';
	import { Copy, Trash2, Link } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatDate, formatDateAbsolute } from '$lib/utils';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';

	interface ShareLink {
		id: string;
		token: string;
		file_name?: string;
		file_id?: string;
		url?: string;
		download_count?: number;
		max_downloads?: number;
		expires_at?: string;
		created_at?: string;
		password_protected?: boolean;
	}

	let links = $state<ShareLink[]>([]);
	let loading = $state(true);

	let deleteTarget = $state<ShareLink | null>(null);
	let showDelete = $state(false);

	onMount(loadLinks);

	async function loadLinks() {
		loading = true;
		try {
			const res = await api.get('/api/shares/mine');
			if (res.ok) {
				const data = await res.json();
				links = data.shares || data || [];
			} else {
				showToast('Failed to load share links', 'error');
			}
		} finally {
			loading = false;
		}
	}

	function copyLink(link: ShareLink) {
		const url = link.url || `${window.location.origin}/s/${link.token}`;
		navigator.clipboard.writeText(url).then(() => {
			showToast('Link copied to clipboard', 'success');
		});
	}

	function confirmDelete(link: ShareLink) {
		deleteTarget = link;
		showDelete = true;
	}

	async function doDelete() {
		if (!deleteTarget) return;
		const endpoint = deleteTarget.file_id
			? `/api/files/${deleteTarget.file_id}/shares/${deleteTarget.id}`
			: `/api/shares/${deleteTarget.id}`;
		const res = await api.delete(endpoint);
		if (res.ok) {
			showToast('Share link deleted', 'success');
			links = links.filter((l) => l.id !== deleteTarget!.id);
			showDelete = false;
			deleteTarget = null;
		} else {
			showToast('Failed to delete share link', 'error');
		}
	}
</script>

<svelte:head>
	<title>Shared — SyncVault</title>
</svelte:head>

<div class="p-6">
	<div class="mb-6">
		<h1 class="text-xl font-semibold text-gray-900">Shared Links</h1>
		<p class="text-sm text-gray-500 mt-1">Links you have created to share files externally.</p>
	</div>

	<div class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
		{#if loading}
			<div class="flex items-center justify-center py-16">
				<div class="w-7 h-7 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
			</div>
		{:else if links.length === 0}
			<div class="text-center py-16 text-gray-400">
				<Link size={48} class="mx-auto mb-3 opacity-30" />
				<p class="text-base font-medium">No share links</p>
				<p class="text-sm mt-1">Create share links from the file browser.</p>
			</div>
		{:else}
			<table class="min-w-full divide-y divide-gray-200">
				<thead class="bg-gray-50">
					<tr>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">File</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Link</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden sm:table-cell">Downloads</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Expires</th>
						<th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider hidden md:table-cell">Created</th>
						<th class="px-4 py-3 w-20"></th>
					</tr>
				</thead>
				<tbody class="bg-white divide-y divide-gray-200">
					{#each links as link}
						<tr class="hover:bg-gray-50">
							<td class="px-4 py-3">
								<span class="text-sm font-medium text-gray-900">{link.file_name || 'Unknown file'}</span>
							</td>
							<td class="px-4 py-3">
								<div class="flex items-center gap-2">
									<span class="text-xs font-mono text-gray-500 truncate max-w-32">/s/{link.token}</span>
									{#if link.password_protected}
										<span class="text-xs bg-yellow-50 text-yellow-700 border border-yellow-200 rounded px-1.5 py-0.5">Password</span>
									{/if}
								</div>
							</td>
							<td class="px-4 py-3 hidden sm:table-cell">
								<span class="text-sm text-gray-500">
									{link.download_count ?? 0}{link.max_downloads ? `/${link.max_downloads}` : ''}
								</span>
							</td>
							<td class="px-4 py-3 hidden md:table-cell">
								<span class="text-sm text-gray-500">
									{link.expires_at ? formatDate(link.expires_at) : 'Never'}
								</span>
							</td>
							<td class="px-4 py-3 hidden md:table-cell">
								<span class="text-sm text-gray-500">{formatDateAbsolute(link.created_at)}</span>
							</td>
							<td class="px-4 py-3">
								<div class="flex items-center gap-1">
									<button
										onclick={() => copyLink(link)}
										title="Copy link"
										class="p-1.5 text-gray-400 hover:text-blue-600 rounded hover:bg-gray-100 transition-colors"
									>
										<Copy size={15} />
									</button>
	<button
										onclick={() => confirmDelete(link)}
										title="Delete link"
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

{#if showDelete && deleteTarget}
	<ConfirmDialog
		title="Delete Share Link"
		message="Are you sure you want to delete the share link for '{deleteTarget.file_name}'? This cannot be undone."
		confirmLabel="Delete"
		onconfirm={doDelete}
		oncancel={() => { showDelete = false; deleteTarget = null; }}
	/>
{/if}
