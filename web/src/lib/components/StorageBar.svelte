<script lang="ts">
	import { formatBytes } from '$lib/utils';

	interface Props {
		used: number;
		total: number;
		label?: string;
	}

	let { used, total, label }: Props = $props();

	const percent = $derived(total > 0 ? Math.min(100, Math.round((used / total) * 100)) : 0);
	const barColor = $derived(
		percent >= 90 ? 'bg-red-500' : percent >= 75 ? 'bg-yellow-500' : 'bg-blue-500'
	);
</script>

<div class="w-full">
	{#if label}
		<div class="flex justify-between text-sm text-gray-600 mb-1">
			<span>{label}</span>
			<span>{percent}%</span>
		</div>
	{/if}
	<div class="w-full bg-gray-200 rounded-full h-2.5">
		<div class="h-2.5 rounded-full transition-all {barColor}" style="width: {percent}%"></div>
	</div>
	<div class="flex justify-between text-xs text-gray-500 mt-1">
		<span>{formatBytes(used)} used</span>
		<span>{formatBytes(total)} total</span>
	</div>
</div>
