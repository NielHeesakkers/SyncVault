<script lang="ts">
	import { X, Download, Clock, Share2, Copy, Trash2, Plus, Eye, EyeOff } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { showToast } from '$lib/stores';
	import { formatBytes, formatDateAbsolute, formatDate } from '$lib/utils';

	interface FileItem {
		id: string;
		name: string;
		size: number;
		mime_type?: string;
		type: 'file' | 'folder';
		owner?: string;
		created_at?: string;
		updated_at?: string;
		folder_id?: string | null;
	}

	interface Version {
		id: string;
		version: number;
		size: number;
		created_at: string;
		created_by?: string;
	}

	interface ShareLink {
		id: string;
		token: string;
		url?: string;
		password_protected?: boolean;
		expires_at?: string;
		max_downloads?: number;
		download_count?: number;
		created_at?: string;
	}

	interface Props {
		file: FileItem | null;
		onclose: () => void;
	}

	let { file, onclose }: Props = $props();

	let activeTab = $state<'details' | 'versions' | 'sharing'>('details');
	let versions = $state<Version[]>([]);
	let shareLinks = $state<ShareLink[]>([]);
	let loadingVersions = $state(false);
	let loadingShares = $state(false);

	// Share form state
	let sharePassword = $state('');
	let shareExpires = $state('');
	let shareMaxDownloads = $state('');
	let showSharePassword = $state(false);
	let creatingShare = $state(false);

	$effect(() => {
		if (file && activeTab === 'versions') loadVersions();
		if (file && activeTab === 'sharing') loadShares();
	});

	$effect(() => {
		if (file) activeTab = 'details';
	});

	async function loadVersions() {
		if (!file) return;
		loadingVersions = true;
		try {
			const res = await api.get(`/api/files/${file.id}/versions`);
			if (res.ok) {
				const data = await res.json();
				versions = data.versions || data || [];
			}
		} catch {
			showToast('Failed to load versions', 'error');
		} finally {
			loadingVersions = false;
		}
	}

	async function loadShares() {
		if (!file) return;
		loadingShares = true;
		try {
			const res = await api.get(`/api/files/${file.id}/shares`);
			if (res.ok) {
				const data = await res.json();
				shareLinks = data.shares || data || [];
			}
		} catch {
			showToast('Failed to load shares', 'error');
		} finally {
			loadingShares = false;
		}
	}

	async function downloadVersion(versionNum: number) {
		if (!file) return;
		const res = await api.get(`/api/files/${file.id}/versions/${versionNum}/download`);
		if (res.ok) {
			const blob = await res.blob();
			const url = URL.createObjectURL(blob);
			const a = document.createElement('a');
			a.href = url;
			a.download = file.name;
			a.click();
			URL.revokeObjectURL(url);
		} else {
			showToast('Download failed', 'error');
		}
	}

	async function restoreVersion(versionNum: number) {
		if (!file) return;
		const res = await api.post(`/api/files/${file.id}/versions/${versionNum}/restore`, {});
		if (res.ok) {
			showToast('Version restored successfully', 'success');
			loadVersions();
		} else {
			showToast('Failed to restore version', 'error');
		}
	}

	async function createShare() {
		if (!file) return;
		creatingShare = true;
		try {
			const body: Record<string, unknown> = {};
			if (sharePassword) body.password = sharePassword;
			if (shareExpires) body.expires_at = new Date(shareExpires).toISOString();
			if (shareMaxDownloads) body.max_downloads = parseInt(shareMaxDownloads);

			const res = await api.post(`/api/files/${file.id}/shares`, body);
			if (res.ok) {
				showToast('Share link created', 'success');
				sharePassword = '';
				shareExpires = '';
				shareMaxDownloads = '';
				loadShares();
			} else {
				showToast('Failed to create share link', 'error');
			}
		} finally {
			creatingShare = false;
		}
	}

	async function deleteShare(shareId: string) {
		if (!file) return;
		const res = await api.delete(`/api/files/${file.id}/shares/${shareId}`);
		if (res.ok) {
			showToast('Share link deleted', 'success');
			shareLinks = shareLinks.filter((s) => s.id !== shareId);
		} else {
			showToast('Failed to delete share link', 'error');
		}
	}

	function copyShareLink(link: ShareLink) {
		const url = link.url || `${window.location.origin}/s/${link.token}`;
		navigator.clipboard.writeText(url).then(() => {
			showToast('Link copied to clipboard', 'success');
		});
	}
</script>

{#if file}
	<div class="fixed inset-y-0 right-0 w-96 bg-white border-l border-gray-200 shadow-xl z-30 flex flex-col">
		<!-- Header -->
		<div class="flex items-center justify-between px-5 py-4 border-b border-gray-200">
			<h2 class="text-base font-semibold text-gray-900 truncate pr-4">{file.name}</h2>
			<button onclick={onclose} class="text-gray-400 hover:text-gray-600 flex-shrink-0 transition-colors">
				<X size={20} />
			</button>
		</div>

		<!-- Tabs -->
		<div class="flex border-b border-gray-200">
			{#each (['details', 'versions', 'sharing'] as const) as tab}
				<button
					onclick={() => (activeTab = tab)}
					class="flex-1 py-3 text-sm font-medium capitalize transition-colors
					{activeTab === tab
						? 'text-blue-600 border-b-2 border-blue-500'
						: 'text-gray-500 hover:text-gray-700'}"
				>
					{tab}
				</button>
			{/each}
		</div>

		<!-- Content -->
		<div class="flex-1 overflow-y-auto p-5">
			<!-- Details tab -->
			{#if activeTab === 'details'}
				<dl class="space-y-4">
					<div>
						<dt class="text-xs font-medium text-gray-500 uppercase tracking-wide">Name</dt>
						<dd class="mt-1 text-sm text-gray-900 break-all">{file.name}</dd>
					</div>
					<div>
						<dt class="text-xs font-medium text-gray-500 uppercase tracking-wide">Size</dt>
						<dd class="mt-1 text-sm text-gray-900">{formatBytes(file.size)}</dd>
					</div>
					{#if file.mime_type}
						<div>
							<dt class="text-xs font-medium text-gray-500 uppercase tracking-wide">Type</dt>
							<dd class="mt-1 text-sm text-gray-900">{file.mime_type}</dd>
						</div>
					{/if}
					{#if file.owner}
						<div>
							<dt class="text-xs font-medium text-gray-500 uppercase tracking-wide">Owner</dt>
							<dd class="mt-1 text-sm text-gray-900">{file.owner}</dd>
						</div>
					{/if}
					{#if file.created_at}
						<div>
							<dt class="text-xs font-medium text-gray-500 uppercase tracking-wide">Created</dt>
							<dd class="mt-1 text-sm text-gray-900">{formatDateAbsolute(file.created_at)}</dd>
						</div>
					{/if}
					{#if file.updated_at}
						<div>
							<dt class="text-xs font-medium text-gray-500 uppercase tracking-wide">Modified</dt>
							<dd class="mt-1 text-sm text-gray-900">{formatDateAbsolute(file.updated_at)}</dd>
						</div>
					{/if}
				</dl>

				<div class="mt-6">
					<a
						href="/api/files/{file.id}/download"
						class="flex items-center justify-center gap-2 w-full bg-blue-500 hover:bg-blue-600 text-white text-sm font-medium rounded-md px-4 py-2 transition-colors"
					>
						<Download size={16} /> Download
					</a>
				</div>

			<!-- Versions tab -->
			{:else if activeTab === 'versions'}
				{#if loadingVersions}
					<div class="flex items-center justify-center py-12">
						<div class="w-6 h-6 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
					</div>
				{:else if versions.length === 0}
					<div class="text-center py-12 text-gray-400">
						<Clock size={40} class="mx-auto mb-3 opacity-40" />
						<p class="text-sm">No version history available</p>
					</div>
				{:else}
					{@const latestVersion = Math.max(...versions.map((v) => v.version))}
					<ul class="space-y-3">
						{#each versions as v}
							{@const isCurrent = v.version === latestVersion}
							<li class="rounded-lg p-3 {isCurrent ? 'bg-blue-50 border border-blue-200' : 'bg-gray-50'}">
								<div class="flex items-center justify-between mb-1">
									<span class="text-sm font-medium text-gray-900">
										Version {v.version}
										{#if isCurrent}<span class="ml-2 text-xs bg-blue-100 text-blue-700 rounded px-1.5 py-0.5">Current</span>{/if}
									</span>
									<span class="text-xs text-gray-500">{formatBytes(v.size)}</span>
								</div>
								<p class="text-xs text-gray-500">{formatDate(v.created_at)}</p>
								{#if v.created_by}
									<p class="text-xs text-gray-400 mb-2">by {v.created_by}</p>
								{:else}
									<div class="mb-2"></div>
								{/if}
								<div class="flex gap-2">
									<button
										onclick={() => downloadVersion(v.version)}
										class="flex items-center gap-1 text-xs text-blue-600 hover:text-blue-800"
									>
										<Download size={12} /> Download
									</button>
									{#if !isCurrent}
										<button
											onclick={() => restoreVersion(v.version)}
											class="flex items-center gap-1 text-xs text-green-600 hover:text-green-800"
										>
											Restore
										</button>
									{/if}
								</div>
							</li>
						{/each}
					</ul>
				{/if}

			<!-- Sharing tab -->
			{:else if activeTab === 'sharing'}
				<!-- Create share form -->
				<div class="bg-gray-50 rounded-lg p-4 mb-5">
					<h3 class="text-sm font-semibold text-gray-900 mb-3">Create Share Link</h3>
					<div class="space-y-3">
						<div>
							<label class="block text-xs font-medium text-gray-600 mb-1">Password (optional)</label>
							<div class="relative">
								<input
									type={showSharePassword ? 'text' : 'password'}
									bind:value={sharePassword}
									placeholder="No password"
									class="w-full text-sm border border-gray-300 rounded-md px-3 py-1.5 pr-8 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
								/>
								<button
									onclick={() => (showSharePassword = !showSharePassword)}
									class="absolute right-2 top-1/2 -translate-y-1/2 text-gray-400"
								>
									{#if showSharePassword}<EyeOff size={14} />{:else}<Eye size={14} />{/if}
								</button>
							</div>
						</div>
						<div>
							<label class="block text-xs font-medium text-gray-600 mb-1">Expires (optional)</label>
							<input
								type="datetime-local"
								bind:value={shareExpires}
								class="w-full text-sm border border-gray-300 rounded-md px-3 py-1.5 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
							/>
						</div>
						<div>
							<label class="block text-xs font-medium text-gray-600 mb-1">Max downloads (optional)</label>
							<input
								type="number"
								bind:value={shareMaxDownloads}
								placeholder="Unlimited"
								min="1"
								class="w-full text-sm border border-gray-300 rounded-md px-3 py-1.5 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
							/>
						</div>
						<button
							onclick={createShare}
							disabled={creatingShare}
							class="flex items-center justify-center gap-2 w-full bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white text-sm font-medium rounded-md px-4 py-2 transition-colors"
						>
							<Plus size={15} />
							{creatingShare ? 'Creating…' : 'Create Link'}
						</button>
					</div>
				</div>

				<!-- Existing share links -->
				{#if loadingShares}
					<div class="flex items-center justify-center py-6">
						<div class="w-5 h-5 border-2 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
					</div>
				{:else if shareLinks.length === 0}
					<div class="text-center py-6 text-gray-400">
						<Share2 size={32} class="mx-auto mb-2 opacity-40" />
						<p class="text-sm">No share links yet</p>
					</div>
				{:else}
					<ul class="space-y-3">
						{#each shareLinks as link}
							<li class="border border-gray-200 rounded-lg p-3">
								<div class="flex items-center justify-between mb-1">
									<span class="text-xs font-mono text-gray-600 truncate">/s/{link.token}</span>
									<div class="flex gap-1 ml-2 flex-shrink-0">
										<button
											onclick={() => copyShareLink(link)}
											title="Copy link"
											class="p-1 text-gray-400 hover:text-blue-600 transition-colors"
										>
											<Copy size={14} />
										</button>
										<button
											onclick={() => deleteShare(link.id)}
											title="Delete link"
											class="p-1 text-gray-400 hover:text-red-600 transition-colors"
										>
											<Trash2 size={14} />
										</button>
									</div>
								</div>
								<div class="flex flex-wrap gap-2 text-xs text-gray-500">
									{#if link.password_protected}
										<span class="bg-yellow-50 text-yellow-700 px-1.5 py-0.5 rounded">Password</span>
									{/if}
									{#if link.expires_at}
										<span>Expires {formatDate(link.expires_at)}</span>
									{/if}
									{#if link.max_downloads}
										<span>{link.download_count ?? 0}/{link.max_downloads} downloads</span>
									{/if}
									{#if !link.password_protected && !link.expires_at && !link.max_downloads}
										<span class="text-green-600">Public link</span>
									{/if}
								</div>
							</li>
						{/each}
					</ul>
				{/if}
			{/if}
		</div>
	</div>
{/if}
