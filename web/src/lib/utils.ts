export function formatBytes(bytes: number): string {
	if (bytes === 0) return '0 B';
	const k = 1024;
	const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
	const i = Math.floor(Math.log(bytes) / Math.log(k));
	return `${parseFloat((bytes / Math.pow(k, i)).toFixed(1))} ${sizes[i]}`;
}

export function formatDate(dateStr: string | null | undefined): string {
	if (!dateStr) return '—';
	const date = new Date(dateStr);
	if (isNaN(date.getTime())) return '—';

	const now = new Date();
	const diff = now.getTime() - date.getTime();
	const seconds = Math.floor(diff / 1000);
	const minutes = Math.floor(seconds / 60);
	const hours = Math.floor(minutes / 60);
	const days = Math.floor(hours / 24);

	if (seconds < 60) return 'just now';
	if (minutes < 60) return `${minutes} minute${minutes !== 1 ? 's' : ''} ago`;
	if (hours < 24) return `${hours} hour${hours !== 1 ? 's' : ''} ago`;
	if (days < 7) return `${days} day${days !== 1 ? 's' : ''} ago`;

	return date.toLocaleDateString('en-US', {
		year: 'numeric',
		month: 'short',
		day: 'numeric'
	});
}

export function formatDateAbsolute(dateStr: string | null | undefined): string {
	if (!dateStr) return '—';
	const date = new Date(dateStr);
	if (isNaN(date.getTime())) return '—';
	return date.toLocaleDateString('en-US', {
		year: 'numeric',
		month: 'short',
		day: 'numeric',
		hour: '2-digit',
		minute: '2-digit'
	});
}
