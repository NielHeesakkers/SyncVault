<script lang="ts">
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';
	import { api } from '$lib/api';

	onMount(() => {
		if (api.isLoggedIn()) {
			goto('/files');
		} else {
			goto('/login');
		}
	});
</script>
