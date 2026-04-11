<script lang="ts">
	import { ChevronRight } from 'lucide-svelte';

	interface Crumb {
		id: string | null;
		name: string;
	}

	interface Props {
		items: Crumb[];
		onclick: (item: Crumb) => void;
	}

	let { items, onclick }: Props = $props();
</script>

<nav aria-label="Breadcrumb" class="flex items-center gap-1 text-sm">
	{#each items as item, i}
		{#if i > 0}
			<ChevronRight size={12} style="color: var(--text-tertiary); flex-shrink: 0;" />
		{/if}
		{#if i === items.length - 1}
			<span class="text-[var(--text-secondary)] font-medium truncate max-w-xs">{item.name}</span>
		{:else}
			<button
				onclick={() => onclick(item)}
				class="text-blue-400 hover:text-blue-300 truncate max-w-xs transition-colors"
			>
				{item.name}
			</button>
		{/if}
	{/each}
</nav>
