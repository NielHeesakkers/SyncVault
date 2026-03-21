<script lang="ts">
	import { toasts } from '$lib/stores';
	import { CheckCircle, AlertCircle, Info, X } from 'lucide-svelte';

	function dismiss(id: number) {
		toasts.update((all) => all.filter((t) => t.id !== id));
	}
</script>

<div class="fixed bottom-4 right-4 z-50 flex flex-col gap-2 pointer-events-none">
	{#each $toasts as toast (toast.id)}
		<div
			class="flex items-center gap-3 rounded-lg px-4 py-3 shadow-lg text-sm font-medium pointer-events-auto max-w-sm
			{toast.type === 'success' ? 'bg-green-50 text-green-800 border border-green-200' : ''}
			{toast.type === 'error' ? 'bg-red-50 text-red-800 border border-red-200' : ''}
			{toast.type === 'info' ? 'bg-blue-50 text-blue-800 border border-blue-200' : ''}"
		>
			{#if toast.type === 'success'}
				<CheckCircle size={16} class="text-green-500 flex-shrink-0" />
			{:else if toast.type === 'error'}
				<AlertCircle size={16} class="text-red-500 flex-shrink-0" />
			{:else}
				<Info size={16} class="text-blue-500 flex-shrink-0" />
			{/if}
			<span class="flex-1">{toast.message}</span>
			<button onclick={() => dismiss(toast.id)} class="text-current opacity-60 hover:opacity-100">
				<X size={14} />
			</button>
		</div>
	{/each}
</div>
