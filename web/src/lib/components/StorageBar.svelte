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
		percent >= 90 ? '#ef4444' : percent >= 75 ? '#f59e0b' : '#3b82f6'
	);
</script>

<div class="w-full">
	{#if label}
		<div class="flex justify-between text-xs mb-1" style="color: rgba(255,255,255,0.50);">
			<span>{label}</span>
			<span>{percent}%</span>
		</div>
	{/if}
	<div class="w-full rounded-full h-1.5" style="background: rgba(255,255,255,0.08);">
		<div class="h-1.5 rounded-full transition-all" style="width: {percent}%; background: {barColor};"></div>
	</div>
	<div class="flex justify-between text-[10px] mt-1" style="color: rgba(255,255,255,0.30);">
		<span>{formatBytes(used)} used</span>
		<span>{formatBytes(total)} total</span>
	</div>
</div>
