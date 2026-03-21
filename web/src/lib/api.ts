import { goto } from '$app/navigation';

const API_BASE = '';

async function request(path: string, options: RequestInit & { headers?: Record<string, string> } = {}): Promise<Response> {
	const token = localStorage.getItem('access_token');
	const headers: Record<string, string> = {
		'Content-Type': 'application/json',
		...options.headers
	};
	if (token) headers['Authorization'] = `Bearer ${token}`;

	const res = await fetch(`${API_BASE}${path}`, { ...options, headers });

	if (res.status === 401) {
		localStorage.removeItem('access_token');
		localStorage.removeItem('refresh_token');
		localStorage.removeItem('user');
		goto('/login');
	}

	return res;
}

export const api = {
	get: (path: string) => request(path),

	post: (path: string, body: unknown) =>
		request(path, { method: 'POST', body: JSON.stringify(body) }),

	put: (path: string, body: unknown) =>
		request(path, { method: 'PUT', body: JSON.stringify(body) }),

	delete: (path: string) => request(path, { method: 'DELETE' }),

	upload: (path: string, formData: FormData) => {
		const token = localStorage.getItem('access_token');
		const headers: Record<string, string> = {};
		if (token) headers['Authorization'] = `Bearer ${token}`;
		return fetch(`${API_BASE}${path}`, {
			method: 'POST',
			body: formData,
			headers
		});
	},

	login: async (username: string, password: string): Promise<{ ok: boolean; error?: string }> => {
		try {
			const res = await fetch(`${API_BASE}/api/auth/login`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ username, password })
			});

			if (!res.ok) {
				const data = await res.json().catch(() => ({}));
				return { ok: false, error: data.message || data.error || 'Invalid credentials' };
			}

			const data = await res.json();
			localStorage.setItem('access_token', data.access_token || data.token || '');
			if (data.refresh_token) localStorage.setItem('refresh_token', data.refresh_token);
			if (data.user) localStorage.setItem('user', JSON.stringify(data.user));

			return { ok: true };
		} catch {
			return { ok: false, error: 'Network error. Please try again.' };
		}
	},

	logout: () => {
		localStorage.clear();
		goto('/login');
	},

	isLoggedIn: () => !!localStorage.getItem('access_token'),

	getUser: (): { username: string; email: string; role: string } | null =>
		JSON.parse(localStorage.getItem('user') || 'null')
};
