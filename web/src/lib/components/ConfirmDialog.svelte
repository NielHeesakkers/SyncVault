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
		confirmClass = 'bg-red-500 hover:bg-red-600 text-white',
		onconfirm,
		oncancel
	}: Props = $props();
</script>

<div
	class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
	role="dialog"
	aria-modal="true"
>
	<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
	<div class="absolute inset-0" onclick={oncancel}></div>
	<div class="relative z-10 w-full max-w-sm rounded-lg bg-white p-6 shadow-xl">
		<h2 class="text-lg font-semibold text-gray-900 mb-2">{title}</h2>
		<p class="text-gray-600 mb-6">{message}</p>
		<div class="flex justify-end gap-3">
			<button
				onclick={oncancel}
				class="rounded-md px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 hover:bg-gray-50 transition-colors"
			>
				Cancel
			</button>
			<button
				onclick={onconfirm}
				class="rounded-md px-4 py-2 text-sm font-medium transition-colors {confirmClass}"
			>
				{confirmLabel}
			</button>
		</div>
	</div>
</div>
