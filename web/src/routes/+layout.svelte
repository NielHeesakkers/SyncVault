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
		Bell,
		LayoutDashboard
	} from 'lucide-svelte';
	import { Sun, Moon } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { currentUser, showToast, theme } from '$lib/stores';
	import ToastContainer from '$lib/components/ToastContainer.svelte';
	import Modal from '$lib/components/Modal.svelte';

	let { children } = $props();

	const publicRoutes = ['/login'];
	let isPublic = $derived(publicRoutes.some((r) => $page.url.pathname.startsWith(r)));
	let userMenuOpen = $state(false);
	let user = $derived($currentUser);

	// Server version
	let serverVersion = $state('');

	// Notifications
	let unreadCount = $state(0);
	let notifications = $state<any[]>([]);
	let showNotifications = $state(false);
	let prevUnreadCount = $state(0);
	let badgeBounce = $state(false);

	async function loadNotifications() {
		try {
			const res = await api.get('/api/notifications');
			if (res.ok) {
				const data = await res.json();
				notifications = data.notifications || [];
				const newCount = data.unread_count || 0;
				if (newCount > prevUnreadCount && prevUnreadCount >= 0) {
					badgeBounce = true;
					setTimeout(() => (badgeBounce = false), 700);
				}
				prevUnreadCount = newCount;
				unreadCount = newCount;
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

	onMount(async () => {
		// Apply saved theme
		const savedTheme = localStorage.getItem('syncvault-theme') || 'dark';
		document.documentElement.setAttribute('data-theme', savedTheme);
		theme.set(savedTheme as 'dark' | 'light');

		try {
			const res = await fetch('/api/health');
			if (res.ok) {
				const data = await res.json();
				serverVersion = data.version || '';
			}
		} catch { /* non-fatal */ }

		if (!isPublic) {
			if (!api.isLoggedIn()) {
				goto('/login');
				return;
			}
			const storedUser = api.getUser();
			if (storedUser) currentUser.set(storedUser);
			prevUnreadCount = -1;
			loadNotifications();
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
		{ href: '/dashboard', label: 'Dashboard', icon: LayoutDashboard },
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

	function getUserInitials(username: string | undefined): string {
		if (!username) return '?';
		return username.slice(0, 2).toUpperCase();
	}
</script>

{#if isPublic}
	{@render children()}
{:else}
	<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
	<div class="flex h-screen overflow-hidden" style="background: var(--bg-base);" onclick={closeUserMenu}>
		<!-- Sidebar -->
		<aside class="w-56 flex-shrink-0 flex flex-col border-r" style="background: var(--sidebar-bg); border-color: var(--sidebar-border);">
			<!-- Logo -->
			<div class="px-4 py-5 flex items-center gap-2.5">
				<div class="w-7 h-7 rounded-lg bg-blue-600 flex items-center justify-center flex-shrink-0">
					<Shield size={14} class="text-white" />
				</div>
				<span class="text-sm font-semibold tracking-tight text-white">SyncVault</span>
			</div>

			<!-- Navigation -->
			<nav class="flex-1 px-2 pb-4 overflow-y-auto">
				<ul class="space-y-0.5">
					{#each navItems as item}
						<li>
							<a
								href={item.href}
								class="flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm font-medium transition-all duration-150 relative
								{isActive(item.href)
									? 'text-white'
									: 'text-white/50 hover:text-white/80 hover:bg-white/[0.04]'}"
								style={isActive(item.href) ? 'background: var(--sidebar-active-bg);' : ''}
							>
								{#if isActive(item.href)}
									<span class="absolute left-0 top-1/2 -translate-y-1/2 w-0.5 h-4 bg-blue-500 rounded-r-full"></span>
								{/if}
								<item.icon size={16} />
								{item.label}
							</a>
						</li>
					{/each}
				</ul>

				{#if user?.role === 'admin'}
					<div class="mt-5">
						<p class="px-3 mb-1.5 text-[10px] font-semibold uppercase tracking-widest" style="color: var(--sidebar-text); opacity: 0.35;">
							Admin
						</p>
						<ul class="space-y-0.5">
							{#each adminItems as item}
								<li>
									<a
										href={item.href}
										class="flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm font-medium transition-all duration-150 relative
										{isActive(item.href)
											? 'text-white'
											: 'text-white/50 hover:text-white/80 hover:bg-white/[0.04]'}"
										style={isActive(item.href) ? 'background: var(--sidebar-active-bg);' : ''}
									>
										{#if isActive(item.href)}
											<span class="absolute left-0 top-1/2 -translate-y-1/2 w-0.5 h-4 bg-blue-500 rounded-r-full"></span>
										{/if}
										<item.icon size={16} />
										{item.label}
									</a>
								</li>
							{/each}
						</ul>
					</div>
				{/if}
			</nav>

			<!-- User section at bottom -->
			<div class="px-2 py-3 border-t" style="border-color: var(--sidebar-border);">
				<!-- Theme toggle + Notification row -->
				<div class="px-1 mb-1 flex items-center gap-1">
					<button
						onclick={() => theme.toggle()}
						class="flex items-center justify-center w-8 h-8 rounded-lg text-white/40 hover:text-white/70 hover:bg-white/[0.04] transition-all duration-150"
						title={$theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}
					>
						{#if $theme === 'dark'}
							<Sun size={15} />
						{:else}
							<Moon size={15} />
						{/if}
					</button>
					<div class="relative inline-block">
						<button
							onclick={(e) => { e.stopPropagation(); showNotifications = !showNotifications; if (showNotifications) { markAllRead(); } }}
							class="flex items-center gap-2 px-2 py-1.5 rounded-lg text-sm transition-all duration-150 text-white/40 hover:text-white/70 hover:bg-white/[0.04]"
						>
							<Bell size={15} />
							<span class="text-xs">Notifications</span>
							{#if unreadCount > 0}
								<span class="ml-auto w-4 h-4 bg-red-500 text-white text-[9px] font-bold rounded-full flex items-center justify-center {badgeBounce ? 'badge-bounce' : ''}">{unreadCount}</span>
							{/if}
						</button>

						{#if showNotifications}
							<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
							<div class="absolute bottom-full left-0 mb-2 w-80 rounded-xl shadow-2xl border z-50 max-h-96 overflow-y-auto"
								style="background: var(--bg-overlay); border-color: var(--border);"
								onclick={(e) => e.stopPropagation()}>
								<div class="px-4 py-3 border-b flex items-center justify-between" style="border-color: var(--border-strong);">
									<span class="text-sm font-semibold" style="color: var(--text-primary);">Notifications</span>
									<button onclick={() => (showNotifications = false)} class="text-xs transition-colors" style="color: var(--text-tertiary);">Close</button>
								</div>
								{#if notifications.length === 0}
									<div class="px-4 py-6 text-center text-sm" style="color: var(--text-tertiary);">No notifications</div>
								{:else}
									{#each notifications as notif}
										<div class="px-4 py-3 border-b {notif.read ? '' : 'bg-blue-500/5'}" style="border-color: var(--border);">
											<p class="text-sm font-medium" style="color: var(--text-primary);">{notif.title}</p>
											<p class="text-xs mt-0.5" style="color: var(--text-secondary);">{notif.message}</p>
											{#if notif.type === 'team_invite' && !notif.acted}
												<div class="flex gap-2 mt-2">
													<button onclick={() => acceptNotification(notif.id)}
														class="px-3 py-1 text-xs font-medium text-white bg-blue-600 rounded-md hover:bg-blue-500 transition-colors">Accept</button>
													<button onclick={() => declineNotification(notif.id)}
														class="px-3 py-1 text-xs font-medium border rounded-md hover:bg-white/5 transition-colors" style="color: var(--text-secondary); border-color: var(--border);">Decline</button>
												</div>
											{:else if notif.acted}
												<span class="text-xs text-green-500 mt-1 inline-block">Accepted</span>
											{/if}
										</div>
									{/each}
								{/if}
							</div>
						{/if}
					</div>
				</div>

				<!-- User row -->
				<div class="relative">
					<button
						onclick={(e) => { e.stopPropagation(); userMenuOpen = !userMenuOpen; }}
						class="w-full flex items-center gap-2.5 px-2 py-2 rounded-lg transition-all duration-150 hover:bg-white/[0.04] group"
					>
						<div class="w-7 h-7 rounded-full bg-blue-600 flex items-center justify-center text-white text-[10px] font-bold flex-shrink-0">
							{getUserInitials(user?.username)}
						</div>
						<div class="flex-1 min-w-0 text-left">
							<p class="text-xs font-medium text-white/80 truncate">{user?.username ?? ''}</p>
							{#if serverVersion}
								<p class="text-[10px] text-white/25">v{serverVersion}</p>
							{/if}
						</div>
						<ChevronDown size={12} class="text-white/30 group-hover:text-white/50 transition-colors flex-shrink-0" />
					</button>

					{#if userMenuOpen}
						<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
						<div
							class="absolute bottom-full left-0 mb-1 w-48 rounded-xl shadow-2xl border py-1 z-40"
							style="background: var(--bg-overlay); border-color: var(--border);"
							onclick={(e) => e.stopPropagation()}
						>
							<button
								onclick={openChangePwd}
								class="flex items-center gap-2 w-full px-3 py-2 text-sm text-white/60 hover:text-white hover:bg-white/[0.05] transition-colors"
							>
								<KeyRound size={14} /> Change Password
							</button>
							<div class="my-1 border-t" style="border-color: var(--border-strong);"></div>
							<button
								onclick={() => api.logout()}
								class="flex items-center gap-2 w-full px-3 py-2 text-sm text-red-400 hover:text-red-300 hover:bg-red-500/10 transition-colors"
							>
								<LogOut size={14} /> Logout
							</button>
						</div>
					{/if}
				</div>
			</div>
		</aside>

		<!-- Main content area -->
		<div class="flex-1 flex flex-col min-w-0" style="background: var(--bg-base);">
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
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Current password</label>
					<input type="password" bind:value={changePwdForm.current_password} placeholder="Enter current password" />
				</div>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">New password</label>
					<input type="password" bind:value={changePwdForm.new_password} placeholder="Enter new password" />
				</div>
				<div>
					<label class="block text-xs font-medium mb-1.5" style="color: var(--text-secondary);">Confirm new password</label>
					<input type="password" bind:value={changePwdForm.confirm_password} placeholder="Confirm new password"
						style={changePwdForm.confirm_password && changePwdForm.new_password !== changePwdForm.confirm_password ? 'border-color: var(--accent-red);' : ''} />
					{#if changePwdForm.confirm_password && changePwdForm.new_password !== changePwdForm.confirm_password}
						<p class="text-xs text-red-400 mt-1">Passwords do not match</p>
					{/if}
				</div>
			</div>
		{/snippet}
		{#snippet footer()}
			<button onclick={() => (showChangePwd = false)} class="px-4 py-2 text-sm font-medium text-white/60 border rounded-lg hover:bg-white/5 transition-all duration-150" style="border-color: var(--border);">Cancel</button>
			<button
				onclick={doChangePassword}
				disabled={changingPwd || !changePwdForm.current_password || !changePwdForm.new_password || changePwdForm.new_password !== changePwdForm.confirm_password}
				class="px-4 py-2 text-sm font-medium bg-blue-600 hover:bg-blue-500 disabled:opacity-40 text-white rounded-lg transition-all duration-150"
			>
				{changingPwd ? 'Changing…' : 'Change Password'}
			</button>
		{/snippet}
	</Modal>
{/if}
