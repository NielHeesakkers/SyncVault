<script lang="ts">
	import '../app.css';
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';
	import {
		FolderOpen,
		Link,
		Trash2,
		Users,
		FolderTree,
		HardDrive,
		Activity,
		ChevronDown,
		LogOut,
		Settings,
		Shield,
		KeyRound,
		BookOpen,
		Clock,
		Bell
	} from 'lucide-svelte';
	import { api } from '$lib/api';
	import { currentUser, showToast } from '$lib/stores';
	import ToastContainer from '$lib/components/ToastContainer.svelte';
	import Modal from '$lib/components/Modal.svelte';

	let { children } = $props();

	const publicRoutes = ['/login'];
	let isPublic = $derived(publicRoutes.some((r) => $page.url.pathname.startsWith(r)));
	let userMenuOpen = $state(false);
	let user = $derived($currentUser);

	// Notifications
	let unreadCount = $state(0);
	let notifications = $state<any[]>([]);
	let showNotifications = $state(false);

	async function loadNotifications() {
		try {
			const res = await api.get('/api/notifications');
			if (res.ok) {
				const data = await res.json();
				notifications = data.notifications || [];
				unreadCount = data.unread_count || 0;
			}
		} catch { /* non-fatal */ }
	}

	async function acceptNotification(id: string) {
		const res = await api.post(`/api/notifications/${id}/accept`, {});
		if (res.ok) {
			showToast('Team invite accepted', 'success');
			loadNotifications();
		}
	}

	async function declineNotification(id: string) {
		const res = await api.post(`/api/notifications/${id}/decline`, {});
		if (res.ok) {
			loadNotifications();
		}
	}

	async function markAllRead() {
		await api.post('/api/notifications/read', {});
		unreadCount = 0;
	}

	// Change password modal
	let showChangePwd = $state(false);
	let changePwdForm = $state({ current_password: '', new_password: '', confirm_password: '' });
	let changingPwd = $state(false);

	onMount(() => {
		if (!isPublic) {
			if (!api.isLoggedIn()) {
				goto('/login');
				return;
			}
			const storedUser = api.getUser();
			if (storedUser) currentUser.set(storedUser);
			loadNotifications();
			// Poll every 30s
			const interval = setInterval(loadNotifications, 30000);
			return () => clearInterval(interval);
		}
	});

	function closeUserMenu() {
		userMenuOpen = false;
	}

	function openChangePwd() {
		changePwdForm = { current_password: '', new_password: '', confirm_password: '' };
		showChangePwd = true;
		closeUserMenu();
	}

	async function doChangePassword() {
		if (!changePwdForm.current_password || !changePwdForm.new_password) return;
		if (changePwdForm.new_password !== changePwdForm.confirm_password) {
			showToast('Passwords do not match', 'error');
			return;
		}
		changingPwd = true;
		try {
			const res = await api.put('/api/me/password', {
				current_password: changePwdForm.current_password,
				new_password: changePwdForm.new_password
			});
			if (res.ok) {
				showToast('Password changed successfully', 'success');
				showChangePwd = false;
				changePwdForm = { current_password: '', new_password: '', confirm_password: '' };
			} else {
				const data = await res.json().catch(() => ({}));
				showToast(data.error || 'Failed to change password', 'error');
			}
		} finally {
			changingPwd = false;
		}
	}

	const navItems = [
		{ href: '/files', label: 'Files', icon: FolderOpen },
		{ href: '/shared', label: 'Shared', icon: Link },
		{ href: '/trash', label: 'Trash', icon: Trash2 }
	];

	const adminItems = [
		{ href: '/admin/users', label: 'Users', icon: Users },
		{ href: '/admin/teams', label: 'Teams', icon: FolderTree },
		{ href: '/admin/storage', label: 'Storage', icon: HardDrive },
		{ href: '/admin/activity', label: 'Activity', icon: Activity },
		{ href: '/admin/settings', label: 'Settings', icon: Settings }
	];

	function isActive(href: string): boolean {
		return $page.url.pathname === href || $page.url.pathname.startsWith(href + '/');
	}
</script>

{#if isPublic}
	{@render children()}
{:else}
	<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
	<div class="flex h-screen bg-gray-50 overflow-hidden" onclick={closeUserMenu}>
		<!-- Sidebar -->
		<aside class="w-60 flex-shrink-0 bg-[#1e1e2e] text-white flex flex-col">
			<!-- Logo -->
			<div class="px-5 py-5 border-b border-white/10">
				<div class="flex items-center gap-2">
					<Shield size={22} class="text-blue-400" />
					<span class="text-lg font-bold tracking-tight">SyncVault</span>
				</div>
			</div>

			<!-- Navigation -->
			<nav class="flex-1 px-3 py-4 overflow-y-auto">
				<ul class="space-y-1">
					{#each navItems as item}
						<li>
							<a
								href={item.href}
								class="flex items-center gap-3 px-3 py-2 rounded-md text-sm font-medium transition-colors
								{isActive(item.href)
									? 'bg-white/15 text-white'
									: 'text-white/70 hover:bg-white/10 hover:text-white'}"
							>
								<item.icon size={18} />
								{item.label}
							</a>
						</li>
					{/each}
				</ul>

				{#if user?.role === 'admin'}
					<div class="mt-6">
						<p class="px-3 mb-2 text-xs font-semibold uppercase tracking-wider text-white/40">
							Admin
						</p>
						<ul class="space-y-1">
							{#each adminItems as item}
								<li>
									<a
										href={item.href}
										class="flex items-center gap-3 px-3 py-2 rounded-md text-sm font-medium transition-colors
										{isActive(item.href)
											? 'bg-white/15 text-white'
											: 'text-white/70 hover:bg-white/10 hover:text-white'}"
									>
										<item.icon size={18} />
										{item.label}
									</a>
								</li>
							{/each}
						</ul>
					</div>
				{/if}
			</nav>

			<!-- Changelog + User section at bottom -->
			<div class="px-3 py-3 border-t border-white/10">
				<a
					href="/changelog"
					class="flex items-center gap-3 px-3 py-2 rounded-md text-sm font-medium transition-colors
					{isActive('/changelog')
						? 'bg-white/15 text-white'
						: 'text-white/70 hover:bg-white/10 hover:text-white'}"
				>
					<BookOpen size={18} />
					Changelog
				</a>
				<div class="px-3 py-2 text-xs text-white/40 truncate">
					{user?.username || ''}
				</div>
				<div class="px-3 py-1 text-xs text-white/20">
					v1.5
				</div>
			</div>
		</aside>

		<!-- Main content area -->
		<div class="flex-1 flex flex-col min-w-0">
			<!-- Top bar -->
			<header class="h-14 bg-white border-b border-gray-200 flex items-center justify-between px-6 flex-shrink-0">
				<div class="flex-1">
					<!-- breadcrumb slot filled by child pages via store -->
				</div>

				<!-- Notifications bell -->
				<div class="relative">
					<button
						onclick={(e) => { e.stopPropagation(); showNotifications = !showNotifications; if (showNotifications) { markAllRead(); } }}
						class="relative p-2 text-gray-500 hover:text-gray-700 rounded-md hover:bg-gray-100 transition-colors"
					>
						<Bell size={18} />
						{#if unreadCount > 0}
							<span class="absolute -top-0.5 -right-0.5 w-4 h-4 bg-red-500 text-white text-[10px] font-bold rounded-full flex items-center justify-center">{unreadCount}</span>
						{/if}
					</button>

					{#if showNotifications}
						<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
						<div class="absolute right-0 top-full mt-1 w-80 bg-white rounded-lg shadow-lg border border-gray-200 z-50 max-h-96 overflow-y-auto"
							onclick={(e) => e.stopPropagation()}>
							<div class="px-4 py-3 border-b border-gray-100 flex items-center justify-between">
								<span class="text-sm font-semibold text-gray-900">Notifications</span>
								<button onclick={() => (showNotifications = false)} class="text-xs text-gray-400 hover:text-gray-600">Close</button>
							</div>
							{#if notifications.length === 0}
								<div class="px-4 py-6 text-center text-sm text-gray-400">No notifications</div>
							{:else}
								{#each notifications as notif}
									<div class="px-4 py-3 border-b border-gray-50 {notif.read ? '' : 'bg-blue-50'}">
										<p class="text-sm font-medium text-gray-900">{notif.title}</p>
										<p class="text-xs text-gray-500 mt-0.5">{notif.message}</p>
										{#if notif.type === 'team_invite' && !notif.acted}
											<div class="flex gap-2 mt-2">
												<button onclick={() => acceptNotification(notif.id)}
													class="px-3 py-1 text-xs font-medium text-white bg-blue-500 rounded hover:bg-blue-600">Accept</button>
												<button onclick={() => declineNotification(notif.id)}
													class="px-3 py-1 text-xs font-medium text-gray-600 border border-gray-300 rounded hover:bg-gray-50">Decline</button>
											</div>
										{:else if notif.acted}
											<span class="text-xs text-green-600 mt-1 inline-block">Accepted</span>
										{/if}
									</div>
								{/each}
							{/if}
						</div>
					{/if}
				</div>

				<!-- User menu -->
				<div class="relative">
					<button
						onclick={(e) => { e.stopPropagation(); userMenuOpen = !userMenuOpen; }}
						class="flex items-center gap-2 text-sm font-medium text-gray-700 hover:text-gray-900 px-3 py-2 rounded-md hover:bg-gray-100 transition-colors"
					>
						<div class="w-7 h-7 rounded-full bg-blue-500 flex items-center justify-center text-white text-xs font-bold">
							{(user?.username ?? '?')[0].toUpperCase()}
						</div>
						<span class="hidden sm:inline">{user?.username ?? ''}</span>
						<ChevronDown size={14} />
					</button>

					{#if userMenuOpen}
						<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
						<div
							class="absolute right-0 top-full mt-1 w-48 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-40"
							onclick={(e) => e.stopPropagation()}
						>
							<a
								href="/settings"
								class="flex items-center gap-2 px-4 py-2 text-sm text-gray-700 hover:bg-gray-50"
								onclick={closeUserMenu}
							>
								<Settings size={15} /> Settings
							</a>
							<button
								onclick={openChangePwd}
								class="flex items-center gap-2 w-full px-4 py-2 text-sm text-gray-700 hover:bg-gray-50"
							>
								<KeyRound size={15} /> Change Password
							</button>
							<hr class="my-1 border-gray-100" />
							<button
								onclick={() => api.logout()}
								class="flex items-center gap-2 w-full px-4 py-2 text-sm text-red-600 hover:bg-red-50"
							>
								<LogOut size={15} /> Logout
							</button>
						</div>
					{/if}
				</div>
			</header>

			<!-- Page content -->
			<main class="flex-1 overflow-auto">
				{@render children()}
			</main>
		</div>
	</div>
{/if}

<ToastContainer />

<!-- Change Password modal -->
{#if showChangePwd}
	<Modal title="Change Password" onclose={() => (showChangePwd = false)}>
		{#snippet children()}
			<div class="space-y-3">
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Current password</label>
					<input type="password" bind:value={changePwdForm.current_password} placeholder="Enter current password" class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">New password</label>
					<input type="password" bind:value={changePwdForm.new_password} placeholder="Enter new password" class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500" />
				</div>
				<div>
					<label class="block text-sm font-medium text-gray-700 mb-1">Confirm new password</label>
					<input type="password" bind:value={changePwdForm.confirm_password} placeholder="Confirm new password" class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500
						{changePwdForm.confirm_password && changePwdForm.new_password !== changePwdForm.confirm_password ? 'border-red-400 focus:border-red-400 focus:ring-red-400' : ''}" />
					{#if changePwdForm.confirm_password && changePwdForm.new_password !== changePwdForm.confirm_password}
						<p class="text-xs text-red-500 mt-1">Passwords do not match</p>
					{/if}
				</div>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showChangePwd = false)} class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50">Cancel</button>
			<button
				onclick={doChangePassword}
				disabled={changingPwd || !changePwdForm.current_password || !changePwdForm.new_password || changePwdForm.new_password !== changePwdForm.confirm_password}
				class="rounded-md px-4 py-2 text-sm font-medium bg-blue-500 hover:bg-blue-600 disabled:bg-blue-300 text-white transition-colors"
			>
				{changingPwd ? 'Changing…' : 'Change Password'}
			</button>
		{/snippet}
	</Modal>
{/if}
