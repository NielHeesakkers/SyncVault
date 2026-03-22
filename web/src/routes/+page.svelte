<script lang="ts">
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';
	import { api } from '$lib/api';

	onMount(() => {
		if (api.isLoggedIn()) {
			goto('/files', { replaceState: true });
		} else {
			goto('/login', { replaceState: true });
		}
	});
</script>
