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
	class="fixed inset-0 z-50 flex items-center justify-center"
	style="background: rgba(0,0,0,0.70); backdrop-filter: blur(4px);"
	role="dialog"
	aria-modal="true"
	aria-label={title}
>
	<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
	<div class="absolute inset-0" onclick={onclose}></div>
	<div class="relative z-10 w-full max-w-md rounded-xl shadow-2xl border" style="background: #1a1a1d; border-color: rgba(255,255,255,0.10);">
		<div class="flex items-center justify-between border-b px-6 py-4" style="border-color: rgba(255,255,255,0.06);">
			<h2 class="text-base font-semibold text-white">{title}</h2>
			<button onclick={onclose} class="text-white/30 hover:text-white/70 transition-colors rounded-md p-1 hover:bg-white/5">
				<X size={18} />
			</button>
		</div>
		<div class="px-6 py-5">
			{#if children}
				{@render children()}
			{/if}
		</div>
		{#if footer}
			<div class="flex justify-end gap-2.5 border-t px-6 py-4" style="border-color: rgba(255,255,255,0.06);">
				{@render footer()}
			</div>
		{/if}
	</div>
</div>
