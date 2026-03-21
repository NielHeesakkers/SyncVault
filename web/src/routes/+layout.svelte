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
		Shield
	} from 'lucide-svelte';
	import { api } from '$lib/api';
	import { currentUser } from '$lib/stores';
	import ToastContainer from '$lib/components/ToastContainer.svelte';

	let { children } = $props();

	const publicRoutes = ['/login'];
	let isPublic = $derived(publicRoutes.some((r) => $page.url.pathname.startsWith(r)));
	let userMenuOpen = $state(false);
	let user = $derived($currentUser);

	onMount(() => {
		if (!isPublic) {
			if (!api.isLoggedIn()) {
				goto('/login');
				return;
			}
			const storedUser = api.getUser();
			if (storedUser) currentUser.set(storedUser);
		}
	});

	function closeUserMenu() {
		userMenuOpen = false;
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
		{ href: '/admin/activity', label: 'Activity', icon: Activity }
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

			<!-- User section at bottom -->
			<div class="px-3 py-3 border-t border-white/10">
				<div class="px-3 py-2 text-xs text-white/40 truncate">
					{user?.username || ''}
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
							class="absolute right-0 top-full mt-1 w-44 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-40"
							onclick={(e) => e.stopPropagation()}
						>
							<a
								href="/settings"
								class="flex items-center gap-2 px-4 py-2 text-sm text-gray-700 hover:bg-gray-50"
								onclick={closeUserMenu}
							>
								<Settings size={15} /> Settings
							</a>
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
