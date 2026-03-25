<script lang="ts">
	interface Props {
		title?: string;
		message: string;
		confirmLabel?: string;
		confirmClass?: string;
		onconfirm: () => void;
		oncancel: () => void;
	}

	let {
		title = 'Confirm',
		message,
		confirmLabel = 'Confirm',
		confirmClass = '',
		onconfirm,
		oncancel
	}: Props = $props();
</script>

<div
	class="fixed inset-0 z-50 flex items-center justify-center"
	style="background: rgba(0,0,0,0.70); backdrop-filter: blur(4px);"
	role="dialog"
	aria-modal="true"
>
	<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
	<div class="absolute inset-0" onclick={oncancel}></div>
	<div class="relative z-10 w-full max-w-sm rounded-xl shadow-2xl border p-6" style="background: #1a1a1d; border-color: rgba(255,255,255,0.10);">
		<h2 class="text-base font-semibold text-white mb-2">{title}</h2>
		<p class="text-sm mb-6" style="color: rgba(255,255,255,0.55);">{message}</p>
		<div class="flex justify-end gap-2.5">
			<button
				onclick={oncancel}
				class="px-4 py-2 text-sm font-medium text-white/60 border rounded-lg hover:bg-white/5 transition-all duration-150"
				style="border-color: rgba(255,255,255,0.10);"
			>
				Cancel
			</button>
			<button
				onclick={onconfirm}
				class="px-4 py-2 text-sm font-medium rounded-lg transition-all duration-150 {confirmClass || 'bg-red-600/10 text-red-400 hover:bg-red-600/20 border border-red-500/20'}"
			>
				{confirmLabel}
			</button>
		</div>
	</div>
</div>
