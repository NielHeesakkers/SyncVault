import { writable } from 'svelte/store';
import { browser } from '$app/environment';

// Theme
function createThemeStore() {
	const initial = browser ? (localStorage.getItem('syncvault-theme') || 'dark') : 'dark';
	const { subscribe, set, update } = writable<'dark' | 'light'>(initial);

	return {
		subscribe,
		set(value: 'dark' | 'light') {
			set(value);
			if (browser) {
				localStorage.setItem('syncvault-theme', value);
				document.documentElement.setAttribute('data-theme', value);
			}
		},
		toggle() {
			update(current => {
				const next = current === 'dark' ? 'light' : 'dark';
				if (browser) {
					localStorage.setItem('syncvault-theme', next);
					document.documentElement.setAttribute('data-theme', next);
				}
				return next;
			});
		}
	};
}

export const theme = createThemeStore();

export interface User {
	id?: string;
	username: string;
	email: string;
	role: string;
}

export interface BreadcrumbItem {
	id: string | null;
	name: string;
}

export const currentUser = writable<User | null>(null);
export const currentPath = writable<BreadcrumbItem[]>([]);

export interface Toast {
	id: number;
	type: 'success' | 'error' | 'info';
	message: string;
}

export const toasts = writable<Toast[]>([]);

let toastId = 0;

export function showToast(message: string, type: Toast['type'] = 'info', duration = 4000) {
	const id = ++toastId;
	toasts.update((all) => [...all, { id, type, message }]);
	setTimeout(() => {
		toasts.update((all) => all.filter((t) => t.id !== id));
	}, duration);
}
