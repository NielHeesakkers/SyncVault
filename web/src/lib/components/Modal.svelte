<script lang="ts">
	import { X } from 'lucide-svelte';

	interface Props {
		title: string;
		onclose: () => void;
		children?: import('svelte').Snippet;
		footer?: import('svelte').Snippet;
	}

	let { title, onclose, children, footer }: Props = $props();
</script>

<div
	class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
	role="dialog"
	aria-modal="true"
	aria-label={title}
>
	<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
	<div class="absolute inset-0" onclick={onclose}></div>
	<div class="relative z-10 w-full max-w-md rounded-lg bg-white shadow-xl">
		<div class="flex items-center justify-between border-b border-gray-200 px-6 py-4">
			<h2 class="text-lg font-semibold text-gray-900">{title}</h2>
			<button onclick={onclose} class="text-gray-400 hover:text-gray-600 transition-colors">
				<X size={20} />
			</button>
		</div>
		<div class="px-6 py-4">
			{#if children}
				{@render children()}
			{/if}
		</div>
		{#if footer}
			<div class="flex justify-end gap-3 border-t border-gray-200 px-6 py-4">
				{@render footer()}
			</div>
		{/if}
	</div>
</div>
