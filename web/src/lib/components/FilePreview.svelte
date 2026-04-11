<script lang="ts">
	import { X, Download, FileText } from 'lucide-svelte';
	import { api } from '$lib/api';
	import { formatBytes } from '$lib/utils';

	interface FileItem {
		id: string;
		name: string;
		size: number;
		is_dir?: boolean;
		content_hash?: string;
		mime_type?: string;
		type?: 'file' | 'folder';
		updated_at?: string;
	}

	type PreviewType = 'image' | 'pdf' | 'video' | 'audio' | 'code' | 'other';

	interface Props {
		file: FileItem | null;
		onclose: () => void;
		apiBaseUrl?: string;
	}

	let { file, onclose, apiBaseUrl = '' }: Props = $props();

	let blobUrl = $state<string | null>(null);
	let codeContent = $state<string | null>(null);
	let loading = $state(false);
	let error = $state<string | null>(null);

	const IMAGE_EXT = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'svg', 'bmp', 'ico', 'tiff', 'heic'];
	const PDF_EXT = ['pdf'];
	const VIDEO_EXT = ['mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'];
	const AUDIO_EXT = ['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'aif', 'aiff'];
	const CODE_EXT = [
		'js', 'ts', 'py', 'go', 'swift', 'json', 'md', 'txt', 'css', 'html',
		'yaml', 'yml', 'xml', 'csv', 'log', 'sh', 'sql', 'rs', 'rb', 'php',
		'java', 'c', 'cpp', 'h', 'toml', 'env', 'gitignore', 'dockerfile',
		'makefile', 'mxf'
	];

	const MAX_CODE_SIZE = 500 * 1024; // 500KB

	function getExtension(name: string): string {
		const parts = name.split('.');
		if (parts.length < 2) return '';
		// Handle dotfiles like .gitignore, .env
		const ext = parts.pop()?.toLowerCase() || '';
		return ext;
	}

	function getBaseName(name: string): string {
		// For files like "Dockerfile" or "Makefile" with no extension
		return name.toLowerCase();
	}

	function getPreviewType(f: FileItem): PreviewType {
		const ext = getExtension(f.name);
		const base = getBaseName(f.name);

		if (IMAGE_EXT.includes(ext)) return 'image';
		if (PDF_EXT.includes(ext)) return 'pdf';
		if (VIDEO_EXT.includes(ext)) return 'video';
		if (AUDIO_EXT.includes(ext)) return 'audio';
		if (CODE_EXT.includes(ext) || ['dockerfile', 'makefile'].includes(base)) return 'code';
		return 'other';
	}

	function getLanguage(name: string): string {
		const ext = getExtension(name);
		const base = getBaseName(name);
		const map: Record<string, string> = {
			js: 'javascript', ts: 'typescript', py: 'python', go: 'go',
			swift: 'swift', json: 'json', md: 'markdown', txt: 'text',
			css: 'css', html: 'html', yaml: 'yaml', yml: 'yaml',
			xml: 'xml', csv: 'csv', log: 'log', sh: 'shell',
			sql: 'sql', rs: 'rust', rb: 'ruby', php: 'php',
			java: 'java', c: 'c', cpp: 'cpp', h: 'c',
			toml: 'toml', env: 'env', gitignore: 'gitignore',
			dockerfile: 'dockerfile', makefile: 'makefile', mxf: 'mxf'
		};
		if (map[ext]) return map[ext];
		if (['dockerfile', 'makefile'].includes(base)) return base;
		return 'text';
	}

	// Regex-based syntax highlighting
	function highlightCode(code: string, lang: string): string {
		// Escape HTML first
		let html = code
			.replace(/&/g, '&amp;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;');

		// Comment patterns
		const singleLineComment = /(\/\/.*$|#.*$)/gm;
		const multiLineComment = /(\/\*[\s\S]*?\*\/)/g;
		const htmlComment = /(&lt;!--[\s\S]*?--&gt;)/g;

		// String patterns
		const doubleString = /("(?:[^"\\]|\\.)*")/g;
		const singleString = /('(?:[^'\\]|\\.)*')/g;
		const backtickString = /(`(?:[^`\\]|\\.)*`)/g;

		// Number pattern
		const numbers = /\b(\d+\.?\d*(?:e[+-]?\d+)?)\b/g;

		// Keyword sets by language family
		const jsKeywords = /\b(const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|this|class|extends|import|export|default|from|async|await|try|catch|finally|throw|typeof|instanceof|in|of|yield|null|undefined|true|false|void|delete)\b/g;
		const pyKeywords = /\b(def|class|return|if|elif|else|for|while|import|from|as|try|except|finally|raise|with|yield|lambda|pass|break|continue|and|or|not|is|in|True|False|None|self|async|await|global|nonlocal)\b/g;
		const goKeywords = /\b(func|return|if|else|for|range|switch|case|break|continue|package|import|type|struct|interface|map|chan|go|defer|select|var|const|true|false|nil|make|append|len|cap|new|delete|error|string|int|float64|bool|byte|rune)\b/g;
		const sqlKeywords = /\b(SELECT|FROM|WHERE|INSERT|INTO|UPDATE|SET|DELETE|CREATE|TABLE|ALTER|DROP|INDEX|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AND|OR|NOT|IN|LIKE|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|AS|DISTINCT|UNION|NULL|PRIMARY|KEY|FOREIGN|REFERENCES|CASCADE|VALUES|DEFAULT|EXISTS|BETWEEN|COUNT|SUM|AVG|MIN|MAX)\b/gi;
		const rustKeywords = /\b(fn|let|mut|const|if|else|for|while|loop|match|return|use|mod|pub|struct|enum|impl|trait|type|where|self|Self|super|crate|as|in|ref|move|async|await|true|false|None|Some|Ok|Err|Box|Vec|String|Option|Result)\b/g;
		const javaKeywords = /\b(public|private|protected|static|final|class|interface|extends|implements|return|if|else|for|while|do|switch|case|break|continue|new|this|super|try|catch|finally|throw|throws|import|package|void|int|long|double|float|boolean|char|byte|short|null|true|false|abstract|synchronized|volatile|transient)\b/g;
		const htmlKeywords = /\b(html|head|body|div|span|p|a|img|ul|ol|li|table|tr|td|th|form|input|button|select|option|textarea|h[1-6]|header|footer|nav|section|article|aside|main|script|style|link|meta|title)\b/g;
		const cssKeywords = /\b(display|position|width|height|margin|padding|border|color|background|font|text|flex|grid|align|justify|overflow|opacity|transition|transform|animation|z-index|top|left|right|bottom|none|auto|inherit|initial|relative|absolute|fixed|sticky)\b/g;
		const shellKeywords = /\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|return|exit|echo|export|source|local|readonly|shift|set|unset|test|true|false|cd|ls|cp|mv|rm|mkdir|chmod|chown|grep|sed|awk|cat|head|tail|find|xargs|pipe|sudo)\b/g;
		const swiftKeywords = /\b(func|var|let|class|struct|enum|protocol|extension|import|return|if|else|guard|switch|case|for|while|repeat|break|continue|do|try|catch|throw|throws|rethrows|as|is|in|self|Self|super|init|deinit|true|false|nil|public|private|internal|fileprivate|open|static|override|mutating|async|await|some|any)\b/g;

		// Apply highlighting with spans
		// Order matters: comments first (to avoid highlighting inside comments),
		// then strings, then keywords, then numbers

		// We use a placeholder approach to avoid double-highlighting
		const placeholders: string[] = [];
		function placeholder(match: string, cls: string): string {
			const idx = placeholders.length;
			placeholders.push(`<span class="hl-${cls}">${match}</span>`);
			return `\x00${idx}\x00`;
		}

		// Multi-line comments
		html = html.replace(multiLineComment, (m) => placeholder(m, 'comment'));
		html = html.replace(htmlComment, (m) => placeholder(m, 'comment'));

		// Single-line comments (language-dependent)
		if (!['css', 'html', 'xml', 'json'].includes(lang)) {
			html = html.replace(singleLineComment, (m) => placeholder(m, 'comment'));
		}

		// Strings
		html = html.replace(doubleString, (m) => placeholder(m, 'string'));
		html = html.replace(singleString, (m) => placeholder(m, 'string'));
		html = html.replace(backtickString, (m) => placeholder(m, 'string'));

		// Keywords based on language
		let keywordPattern: RegExp | null = null;
		switch (lang) {
			case 'javascript': case 'typescript': keywordPattern = jsKeywords; break;
			case 'python': keywordPattern = pyKeywords; break;
			case 'go': keywordPattern = goKeywords; break;
			case 'sql': keywordPattern = sqlKeywords; break;
			case 'rust': keywordPattern = rustKeywords; break;
			case 'java': case 'c': case 'cpp': keywordPattern = javaKeywords; break;
			case 'html': case 'xml': keywordPattern = htmlKeywords; break;
			case 'css': keywordPattern = cssKeywords; break;
			case 'shell': keywordPattern = shellKeywords; break;
			case 'swift': keywordPattern = swiftKeywords; break;
			case 'ruby': keywordPattern = /\b(def|class|module|end|if|elsif|else|unless|for|while|until|do|begin|rescue|ensure|raise|return|yield|require|include|extend|attr_accessor|attr_reader|attr_writer|self|super|nil|true|false|and|or|not|in|then|puts|print)\b/g; break;
			case 'php': keywordPattern = /\b(function|class|return|if|else|elseif|for|foreach|while|do|switch|case|break|continue|new|echo|print|public|private|protected|static|final|abstract|interface|extends|implements|use|namespace|require|include|try|catch|finally|throw|null|true|false|array|isset|unset|empty|die|exit|var|const)\b/g; break;
			case 'toml': case 'yaml': keywordPattern = /\b(true|false|null|yes|no|on|off)\b/gi; break;
			case 'dockerfile': keywordPattern = /\b(FROM|RUN|CMD|ENTRYPOINT|COPY|ADD|ENV|EXPOSE|VOLUME|WORKDIR|USER|ARG|LABEL|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL|MAINTAINER|AS)\b/g; break;
			case 'makefile': keywordPattern = /\b(ifeq|ifneq|ifdef|ifndef|else|endif|define|endef|include|override|export|unexport|vpath|PHONY|SUFFIXES|DEFAULT|PRECIOUS|INTERMEDIATE|SECONDARY|SECONDEXPANSION|DELETE_ON_ERROR|IGNORE|LOW_RESOLUTION_TIME|SILENT|EXPORT_ALL_VARIABLES|NOTPARALLEL|ONESHELL|POSIX)\b/g; break;
		}

		if (keywordPattern) {
			html = html.replace(keywordPattern, (m) => placeholder(m, 'keyword'));
		}

		// Numbers (but not inside placeholders)
		html = html.replace(numbers, (m) => placeholder(m, 'number'));

		// Restore placeholders
		html = html.replace(/\x00(\d+)\x00/g, (_, idx) => placeholders[parseInt(idx)]);

		return html;
	}

	function addLineNumbers(html: string): string {
		const lines = html.split('\n');
		const digits = String(lines.length).length;
		return lines
			.map((line, i) => {
				const num = String(i + 1).padStart(digits, ' ');
				return `<span class="line-number">${num}</span>${line}`;
			})
			.join('\n');
	}

	$effect(() => {
		if (!file) {
			cleanup();
			return;
		}

		const ptype = getPreviewType(file);

		if (ptype === 'other') {
			loading = false;
			return;
		}

		loading = true;
		error = null;
		codeContent = null;

		if (ptype === 'code') {
			loadCodeContent(file);
		} else {
			loadBlobContent(file);
		}
	});

	async function loadCodeContent(f: FileItem) {
		if (f.size > MAX_CODE_SIZE) {
			error = `File is too large to preview (${formatBytes(f.size)}). Maximum is ${formatBytes(MAX_CODE_SIZE)}.`;
			loading = false;
			return;
		}
		try {
			const res = await api.get(`${apiBaseUrl}/api/files/${f.id}/download`);
			if (res.ok) {
				const text = await res.text();
				codeContent = text;
			} else {
				error = 'Failed to load file content.';
			}
		} catch {
			error = 'Network error loading file.';
		} finally {
			loading = false;
		}
	}

	async function loadBlobContent(f: FileItem) {
		try {
			const res = await api.get(`${apiBaseUrl}/api/files/${f.id}/preview`);
			if (res.ok) {
				const blob = await res.blob();
				if (blobUrl) URL.revokeObjectURL(blobUrl);
				blobUrl = URL.createObjectURL(blob);
			} else {
				error = 'Failed to load preview.';
			}
		} catch {
			error = 'Network error loading preview.';
		} finally {
			loading = false;
		}
	}

	function cleanup() {
		if (blobUrl) {
			URL.revokeObjectURL(blobUrl);
			blobUrl = null;
		}
		codeContent = null;
		error = null;
		loading = false;
	}

	function handleDownload() {
		if (!file) return;
		const token = localStorage.getItem('access_token');
		const url = `${apiBaseUrl}/api/files/${file.id}/download`;
		const a = document.createElement('a');
		a.href = url;
		a.download = file.name;
		// For authenticated downloads, fetch as blob
		api.get(url).then(async (res) => {
			if (res.ok) {
				const blob = await res.blob();
				const burl = URL.createObjectURL(blob);
				a.href = burl;
				a.click();
				URL.revokeObjectURL(burl);
			}
		});
	}

	function handleBackdropClick() {
		onclose();
	}

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') {
			onclose();
		}
	}

	let highlightedCode = $derived.by(() => {
		if (!codeContent || !file) return '';
		const lang = getLanguage(file.name);
		const highlighted = highlightCode(codeContent, lang);
		return addLineNumbers(highlighted);
	});

	let previewType = $derived(file ? getPreviewType(file) : 'other');
	let fileExtension = $derived(file ? getExtension(file.name) : '');
</script>

<svelte:window onkeydown={handleKeydown} />

{#if file}
	<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
	<div class="preview-overlay" onclick={handleBackdropClick}>
		<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
		<div class="preview-modal" onclick={(e) => e.stopPropagation()}>
			<!-- Header -->
			<div class="preview-header">
				<div class="preview-header-left">
					<FileText size={16} style="color: var(--text-tertiary); flex-shrink: 0;" />
					<span class="preview-filename">{file.name}</span>
				</div>
				<div class="preview-header-right">
					<button class="preview-download-btn" onclick={handleDownload}>
						<Download size={13} />
						Download
					</button>
					<button class="preview-close-btn" onclick={onclose}>
						<X size={16} />
					</button>
				</div>
			</div>

			<!-- Content -->
			<div class="preview-content">
				{#if loading}
					<div class="preview-loading">
						<div class="preview-spinner"></div>
					</div>
				{:else if error}
					<div class="preview-error">
						<p>{error}</p>
						<button class="preview-error-download" onclick={handleDownload}>
							<Download size={14} />
							Download File Instead
						</button>
					</div>
				{:else if previewType === 'image' && blobUrl}
					<div class="preview-center">
						<img src={blobUrl} alt={file.name} class="preview-image" />
					</div>
				{:else if previewType === 'pdf' && blobUrl}
					<iframe src={blobUrl} title={file.name} class="preview-pdf"></iframe>
				{:else if previewType === 'video' && blobUrl}
					<div class="preview-center">
						<!-- svelte-ignore a11y_media_has_caption -->
						<video src={blobUrl} controls class="preview-video">
							Your browser does not support the video element.
						</video>
					</div>
				{:else if previewType === 'audio' && blobUrl}
					<div class="preview-audio-container">
						<div class="preview-audio-icon">
							<svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
								<path d="M9 18V5l12-2v13" /><circle cx="6" cy="18" r="3" /><circle cx="18" cy="16" r="3" />
							</svg>
						</div>
						<p class="preview-audio-name">{file.name}</p>
						<p class="preview-audio-size">{formatBytes(file.size)}</p>
						<!-- svelte-ignore a11y_media_has_caption -->
						<audio src={blobUrl} controls class="preview-audio">
							Your browser does not support the audio element.
						</audio>
					</div>
				{:else if previewType === 'code' && codeContent !== null}
					<div class="preview-code-wrapper">
						<div class="preview-code-header">
							<span class="preview-code-lang">{getLanguage(file.name)}</span>
							<span class="preview-code-size">{formatBytes(file.size)}</span>
						</div>
						<div class="preview-code-scroll">
							<pre class="preview-code"><code>{@html highlightedCode}</code></pre>
						</div>
					</div>
				{:else}
					<!-- File info card for unsupported types -->
					<div class="preview-info">
						<div class="preview-info-icon">
							<FileText size={48} style="color: var(--text-tertiary); opacity: 0.6;" />
						</div>
						<h3 class="preview-info-name">{file.name}</h3>
						<div class="preview-info-details">
							<p>Size: {formatBytes(file.size)}</p>
							{#if file.mime_type}
								<p>Type: {file.mime_type}</p>
							{/if}
							{#if fileExtension}
								<p>Extension: .{fileExtension}</p>
							{/if}
						</div>
						<button class="preview-info-download" onclick={handleDownload}>
							<Download size={14} />
							Download File
						</button>
					</div>
				{/if}
			</div>
		</div>
	</div>
{/if}

<style>
	.preview-overlay {
		position: fixed;
		inset: 0;
		z-index: 50;
		display: flex;
		align-items: center;
		justify-content: center;
		background: rgba(0, 0, 0, 0.7);
		backdrop-filter: blur(4px);
	}

	.preview-modal {
		position: relative;
		width: 100%;
		max-width: 56rem;
		max-height: 85vh;
		margin: 1rem;
		display: flex;
		flex-direction: column;
		border-radius: 1rem;
		border: 1px solid var(--border);
		background: var(--bg-elevated);
		box-shadow: 0 16px 64px rgba(0, 0, 0, 0.6);
		overflow: hidden;
	}

	.preview-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 0.75rem 1.25rem;
		border-bottom: 1px solid var(--border);
		flex-shrink: 0;
	}

	.preview-header-left {
		display: flex;
		align-items: center;
		gap: 0.625rem;
		min-width: 0;
		flex: 1;
	}

	.preview-filename {
		font-size: 0.875rem;
		font-weight: 500;
		color: var(--text-primary);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.preview-header-right {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		flex-shrink: 0;
		margin-left: 0.75rem;
	}

	.preview-download-btn {
		display: flex;
		align-items: center;
		gap: 0.375rem;
		font-size: 0.75rem;
		font-weight: 500;
		color: var(--text-secondary);
		background: var(--bg-base);
		border: 1px solid var(--border);
		border-radius: 0.5rem;
		padding: 0.375rem 0.75rem;
		cursor: pointer;
		transition: all 0.15s;
	}

	.preview-download-btn:hover {
		color: var(--text-primary);
		background: var(--bg-elevated);
	}

	.preview-close-btn {
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 0.375rem;
		border-radius: 0.5rem;
		border: none;
		background: transparent;
		color: var(--text-tertiary);
		cursor: pointer;
		transition: all 0.15s;
	}

	.preview-close-btn:hover {
		color: var(--text-primary);
		background: var(--bg-base);
	}

	.preview-content {
		flex: 1;
		overflow: auto;
		padding: 1.25rem;
	}

	/* Loading */
	.preview-loading {
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 4rem 0;
	}

	.preview-spinner {
		width: 1.5rem;
		height: 1.5rem;
		border: 2px solid #3b82f6;
		border-top-color: transparent;
		border-radius: 50%;
		animation: spin 0.6s linear infinite;
	}

	@keyframes spin {
		to { transform: rotate(360deg); }
	}

	/* Error */
	.preview-error {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		padding: 3rem 0;
		gap: 1rem;
	}

	.preview-error p {
		font-size: 0.875rem;
		color: var(--text-tertiary);
	}

	.preview-error-download {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		font-size: 0.875rem;
		font-weight: 500;
		color: white;
		background: #3b82f6;
		border: none;
		border-radius: 0.5rem;
		padding: 0.5rem 1rem;
		cursor: pointer;
		transition: background 0.15s;
	}

	.preview-error-download:hover {
		background: #2563eb;
	}

	/* Center container for images and video */
	.preview-center {
		display: flex;
		align-items: center;
		justify-content: center;
	}

	/* Image */
	.preview-image {
		max-width: 100%;
		max-height: 65vh;
		border-radius: 0.5rem;
		object-fit: contain;
	}

	/* PDF */
	.preview-pdf {
		width: 100%;
		height: 65vh;
		border-radius: 0.5rem;
		border: 1px solid var(--border);
	}

	/* Video */
	.preview-video {
		max-width: 100%;
		max-height: 65vh;
		border-radius: 0.5rem;
	}

	/* Audio */
	.preview-audio-container {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		padding: 2rem 0;
		gap: 0.5rem;
	}

	.preview-audio-icon {
		color: var(--text-tertiary);
		opacity: 0.5;
		margin-bottom: 0.5rem;
	}

	.preview-audio-name {
		font-size: 0.9375rem;
		font-weight: 600;
		color: var(--text-primary);
	}

	.preview-audio-size {
		font-size: 0.8125rem;
		color: var(--text-tertiary);
		margin-bottom: 1rem;
	}

	.preview-audio {
		width: 100%;
		max-width: 28rem;
	}

	/* Code */
	.preview-code-wrapper {
		border-radius: 0.625rem;
		overflow: hidden;
		background: #1e1e2e;
		border: 1px solid rgba(255, 255, 255, 0.08);
	}

	.preview-code-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 0.5rem 1rem;
		background: rgba(255, 255, 255, 0.04);
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}

	.preview-code-lang {
		font-size: 0.6875rem;
		font-weight: 500;
		color: rgba(255, 255, 255, 0.45);
		text-transform: uppercase;
		letter-spacing: 0.05em;
	}

	.preview-code-size {
		font-size: 0.6875rem;
		color: rgba(255, 255, 255, 0.3);
	}

	.preview-code-scroll {
		overflow: auto;
		max-height: 60vh;
	}

	.preview-code {
		margin: 0;
		padding: 1rem;
		font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', 'Cascadia Code', Menlo, Monaco, 'Courier New', monospace;
		font-size: 0.8125rem;
		line-height: 1.6;
		color: #cdd6f4;
		tab-size: 4;
		white-space: pre;
		background: transparent;
	}

	.preview-code code {
		font-family: inherit;
	}

	/* Line numbers */
	.preview-code :global(.line-number) {
		display: inline-block;
		width: 3.5em;
		margin-right: 1.25em;
		text-align: right;
		color: rgba(255, 255, 255, 0.15);
		user-select: none;
		pointer-events: none;
	}

	/* Syntax highlighting colors */
	.preview-code :global(.hl-keyword) {
		color: #89b4fa;
	}

	.preview-code :global(.hl-string) {
		color: #a6e3a1;
	}

	.preview-code :global(.hl-comment) {
		color: #6c7086;
		font-style: italic;
	}

	.preview-code :global(.hl-number) {
		color: #fab387;
	}

	/* File info card */
	.preview-info {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		padding: 3rem 0;
	}

	.preview-info-icon {
		margin-bottom: 1rem;
	}

	.preview-info-name {
		font-size: 1rem;
		font-weight: 600;
		color: var(--text-primary);
		margin: 0;
		word-break: break-all;
		text-align: center;
	}

	.preview-info-details {
		margin-top: 0.75rem;
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
		text-align: center;
	}

	.preview-info-details p {
		font-size: 0.875rem;
		color: var(--text-tertiary);
		margin: 0;
	}

	.preview-info-download {
		margin-top: 1.25rem;
		display: flex;
		align-items: center;
		gap: 0.5rem;
		font-size: 0.875rem;
		font-weight: 500;
		color: white;
		background: #3b82f6;
		border: none;
		border-radius: 0.5rem;
		padding: 0.5rem 1rem;
		cursor: pointer;
		transition: background 0.15s;
	}

	.preview-info-download:hover {
		background: #2563eb;
	}
</style>
