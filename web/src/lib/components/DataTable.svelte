<script lang="ts">
	interface Column {
		key: string;
		label: string;
		sortable?: boolean;
	}

	interface Props {
		columns: Column[];
		rows?: import('svelte').Snippet;
		emptyMessage?: string;
		isEmpty?: boolean;
	}

	let { columns, rows, emptyMessage = 'No items found.', isEmpty = false }: Props = $props();

	let sortKey = $state('');
	let sortDir = $state<'asc' | 'desc'>('asc');

	function toggleSort(key: string) {
		if (sortKey === key) {
			sortDir = sortDir === 'asc' ? 'desc' : 'asc';
		} else {
			sortKey = key;
			sortDir = 'asc';
		}
	}
</script>

<div class="overflow-x-auto">
	<table class="min-w-full divide-y divide-gray-200">
		<thead class="bg-gray-50">
			<tr>
				{#each columns as col}
					<th
						class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider {col.sortable ? 'cursor-pointer hover:bg-gray-100 select-none' : ''}"
						onclick={() => col.sortable && toggleSort(col.key)}
					>
						<span class="flex items-center gap-1">
							{col.label}
							{#if col.sortable && sortKey === col.key}
								<span class="text-blue-500">{sortDir === 'asc' ? '↑' : '↓'}</span>
							{/if}
						</span>
					</th>
				{/each}
			</tr>
		</thead>
		<tbody class="bg-white divide-y divide-gray-200">
			{#if isEmpty}
				<tr>
					<td colspan={columns.length} class="px-4 py-12 text-center text-gray-400 text-sm">
						{emptyMessage}
					</td>
				</tr>
			{:else if rows}
				{@render rows()}
			{/if}
		</tbody>
	</table>
</div>
