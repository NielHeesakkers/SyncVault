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

<div class="p-6" style="background: #0a0a0b; min-height: 100%;">
	<div class="mb-6">
		<h1 class="text-base font-semibold text-white">Shared Links</h1>
		<p class="text-sm mt-1" style="color: rgba(255,255,255,0.35);">Links you have created to share files externally.</p>
	</div>

	<div class="rounded-xl border overflow-hidden" style="background: #111113; border-color: rgba(255,255,255,0.05);">
		{#if loading}
			<div class="px-4 py-3 border-b" style="border-color: rgba(255,255,255,0.05);">
				<div class="flex gap-4">
					<div class="skeleton h-3 rounded w-32"></div>
					<div class="skeleton h-3 rounded w-24"></div>
				</div>
			</div>
			{#each [1,2,3] as _}
				<div class="px-4 py-3.5 border-b flex items-center gap-3" style="border-color: rgba(255,255,255,0.04);">
					<div class="skeleton h-3 rounded w-36"></div>
					<div class="skeleton h-3 rounded w-24 ml-4"></div>
					<div class="skeleton h-3 rounded w-16 ml-auto"></div>
				</div>
			{/each}
		{:else if links.length === 0}
			<div class="flex flex-col items-center justify-center py-20">
				<div class="w-14 h-14 rounded-2xl flex items-center justify-center mb-4" style="background: rgba(255,255,255,0.04);">
					<Link size={24} style="color: rgba(255,255,255,0.20);" />
				</div>
				<p class="text-base font-medium" style="color: rgba(255,255,255,0.40);">No shared links</p>
				<p class="text-sm mt-1.5" style="color: rgba(255,255,255,0.25);">Create share links from the file browser.</p>
			</div>
		{:else}
			<table class="min-w-full">
				<thead>
					<tr style="border-bottom: 1px solid rgba(255,255,255,0.05);">
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">File</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider" style="color: rgba(255,255,255,0.30);">Link</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden sm:table-cell" style="color: rgba(255,255,255,0.30);">Downloads</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: rgba(255,255,255,0.30);">Expires</th>
						<th class="px-4 py-3 text-left text-[10px] font-semibold uppercase tracking-wider hidden md:table-cell" style="color: rgba(255,255,255,0.30);">Created</th>
						<th class="px-4 py-3 w-20"></th>
					</tr>
				</thead>
				<tbody>
					{#each links as link}
						<tr class="shared-row">
							<td class="px-4 py-3.5">
								<span class="text-sm font-medium text-white/70">{link.file_name || 'Unknown file'}</span>
							</td>
							<td class="px-4 py-3.5">
								<div class="flex items-center gap-2">
									<span class="text-xs font-mono truncate max-w-32" style="color: rgba(255,255,255,0.35);">/s/{link.token}</span>
									{#if link.password_protected}
										<span class="text-[10px] font-medium px-1.5 py-0.5 rounded" style="background: rgba(245,158,11,0.12); color: #fbbf24; border: 1px solid rgba(245,158,11,0.20);">Password</span>
									{/if}
								</div>
							</td>
							<td class="px-4 py-3.5 hidden sm:table-cell">
								<span class="text-sm" style="color: rgba(255,255,255,0.40);">
									{link.download_count ?? 0}{link.max_downloads ? `/${link.max_downloads}` : ''}
								</span>
							</td>
							<td class="px-4 py-3.5 hidden md:table-cell">
								<span class="text-sm" style="color: rgba(255,255,255,0.40);">
									{link.expires_at ? formatDate(link.expires_at) : 'Never'}
								</span>
							</td>
							<td class="px-4 py-3.5 hidden md:table-cell">
								<span class="text-sm" style="color: rgba(255,255,255,0.40);">{formatDateAbsolute(link.created_at)}</span>
							</td>
							<td class="px-4 py-3.5">
								<div class="flex items-center gap-1 justify-end">
									<button
										onclick={() => copyLink(link)}
										title="Copy link"
										class="p-1.5 text-white/30 hover:text-blue-400 rounded-md hover:bg-blue-500/10 transition-all"
									>
										<Copy size={14} />
									</button>
									<button
										onclick={() => confirmDelete(link)}
										title="Delete link"
										class="p-1.5 text-white/30 hover:text-red-400 rounded-md hover:bg-red-500/10 transition-all"
									>
										<Trash2 size={14} />
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

<style>
	.shared-row {
		border-bottom: 1px solid rgba(255,255,255,0.04);
	}
	.shared-row:hover {
		background: rgba(255,255,255,0.03);
	}
	.shared-row:last-child {
		border-bottom: none;
	}
</style>
