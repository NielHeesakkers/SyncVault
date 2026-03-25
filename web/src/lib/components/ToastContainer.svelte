<script lang="ts">
	import { toasts } from '$lib/stores';
	import { CheckCircle2, XCircle, AlertTriangle, Info, X } from 'lucide-svelte';

	function dismiss(id: number) {
		toasts.update((all) => all.filter((t) => t.id !== id));
	}
</script>

<div class="fixed top-4 right-4 z-[100] flex flex-col gap-2 pointer-events-none">
	{#each $toasts as toast (toast.id)}
		<div
			class="toast-enter flex items-center gap-3 px-4 py-3 rounded-full shadow-2xl text-sm font-medium pointer-events-auto border"
			style="
				background: #1a1a1d;
				border-color: rgba(255,255,255,0.10);
				max-width: 360px;
				{toast.type === 'success' ? 'border-color: rgba(34, 197, 94, 0.30);' : ''}
				{toast.type === 'error' ? 'border-color: rgba(239, 68, 68, 0.30);' : ''}
				{toast.type === 'warning' ? 'border-color: rgba(245, 158, 11, 0.30);' : ''}
			"
		>
			{#if toast.type === 'success'}
				<CheckCircle2 size={16} class="text-green-400 flex-shrink-0" />
			{:else if toast.type === 'error'}
				<XCircle size={16} class="text-red-400 flex-shrink-0" />
			{:else if toast.type === 'warning'}
				<AlertTriangle size={16} class="text-yellow-400 flex-shrink-0" />
			{:else}
				<Info size={16} class="text-blue-400 flex-shrink-0" />
			{/if}
			<span class="flex-1 text-white/80">{toast.message}</span>
			<button onclick={() => dismiss(toast.id)} class="text-white/30 hover:text-white/60 transition-colors flex-shrink-0 ml-1">
				<X size={13} />
			</button>
		</div>
	{/each}
</div>
