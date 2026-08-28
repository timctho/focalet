const IMAGE_EXTENSIONS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg']);
const HTML_EXTENSIONS = new Set(['.html', '.htm']);

export function artifactKindFromPath(value) {
  const clean = String(value || '').split(/[?#]/, 1)[0].toLowerCase();
  const extension = /(?:\.[a-z0-9]+)$/.exec(clean)?.[0] || '';
  if (IMAGE_EXTENSIONS.has(extension)) return 'image';
  if (HTML_EXTENSIONS.has(extension)) return 'html';
  return null;
}

export function artifactsFromThreadItem(item, options = {}) {
  if (!item || typeof item !== 'object') return [];
  const artifacts = [];
  const add = (artifact) => addArtifact(artifacts, artifact, options);
  for (const artifact of (Array.isArray(item.artifacts) ? item.artifacts : [])) add(artifact);

  if (item.type === 'imageGeneration' && !item.failure) {
    const path = pathText(item.savedPath);
    const dataUrl = normalizeImageDataUrl(item.result, mimeTypeForPath(path));
    if (dataUrl || path) add({
      id: `${item.id || 'image-generation'}:image`,
      kind: 'image',
      title: 'Generated image',
      dataUrl,
      path,
    });
  }

  if (item.type === 'fileChange' && !/failed|declined|cancelled/i.test(String(item.status || ''))) {
    for (const change of item.changes || []) {
      if (/delete|remove/i.test(String(change?.kind || ''))) continue;
      const path = pathText(change?.path);
      const kind = artifactKindFromPath(path);
      if (kind) add({
        id: `${item.id || 'file-change'}:${path}`,
        kind,
        title: kind === 'html' ? 'HTML preview' : 'Generated image',
        path,
      });
    }
  }

  if (item.type === 'dynamicToolCall') {
    collectContentArtifacts(item.contentItems, add, `${item.id || 'dynamic-tool'}:content`);
  }

  if (item.type === 'mcpToolCall') {
    collectContentArtifacts(item.result?.content, add, `${item.id || 'mcp-tool'}:content`);
    collectStructuredArtifacts(item.result?.structuredContent, add, `${item.id || 'mcp-tool'}:structured`);
  }

  if (item.type === 'agentMessage') {
    for (const artifact of artifactsFromText(item.text, options)) add(artifact);
  }

  return artifacts;
}

export function artifactsFromContent(content, options = {}) {
  const artifacts = [];
  collectContentArtifacts(content, (artifact) => addArtifact(artifacts, artifact, options), 'content');
  return artifacts;
}

export function artifactsFromText(value, options = {}) {
  const text = String(value || '');
  const artifacts = [];
  const addPath = (path, title = '') => {
    const dataUrl = normalizeImageDataUrl(path);
    const kind = dataUrl ? 'image' : artifactKindFromPath(path);
    if (!kind || (/^https?:/i.test(path) && !dataUrl)) return;
    addArtifact(artifacts, {
      id: `message:${path}`,
      kind,
      title: title || (kind === 'html' ? 'HTML preview' : 'Generated image'),
      ...(dataUrl ? { dataUrl } : { path }),
    }, options);
  };
  const markdown = /(!?)\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+["'][^"']*["'])?\s*\)/g;
  for (const match of text.matchAll(markdown)) addPath(match[3] || match[4], match[2]);
  const barePath = /(?:^|[\s("'`])((?:file:\/\/\/[^\s"'<>]+|[a-z]:[\\/][^\s"'<>]+|\/[^\s"'<>]+)\.(?:png|jpe?g|gif|webp|bmp|svg|html?))(?=$|[\s),.;])/gi;
  for (const match of text.matchAll(barePath)) addPath(match[1]);
  return artifacts;
}

export function sandboxHtmlDocument(value) {
  const source = String(value || '').replace(/^\s*<!doctype[^>]*>\s*/i, '');
  const policy = "default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none'";
  const metadata = `<meta http-equiv="Content-Security-Policy" content="${policy}"><meta name="referrer" content="no-referrer">`;
  return `<!doctype html><html><head>${metadata}</head><body>${source}</body></html>`;
}

function collectContentArtifacts(content, add, prefix) {
  for (const [index, block] of (Array.isArray(content) ? content : []).entries()) {
    if (!block || typeof block !== 'object') continue;
    if (block.content && typeof block.content === 'object') {
      collectContentArtifacts([block.content], add, `${prefix}:${index}:nested`);
    }
    const type = String(block.type || '').toLowerCase();
    const imageValue = block.imageUrl || block.image_url;
    if ((type === 'inputimage' || type === 'input_image') && imageValue) {
      const dataUrl = normalizeImageDataUrl(imageValue);
      if (dataUrl) add({ id: `${prefix}:${index}`, kind: 'image', title: 'Generated image', dataUrl });
      else if (artifactKindFromPath(imageValue) === 'image') add({ id: `${prefix}:${index}`, kind: 'image', title: 'Generated image', path: imageValue });
      continue;
    }
    if (type === 'image' && block.data) {
      const dataUrl = normalizeImageDataUrl(block.data, block.mimeType || block.mime_type);
      if (dataUrl) add({ id: `${prefix}:${index}`, kind: 'image', title: 'Generated image', dataUrl });
      continue;
    }
    if (type === 'resource_link') {
      const kind = artifactKindFromPath(block.uri);
      if (kind) add({ id: `${prefix}:${index}`, kind, title: block.title || block.name, path: block.uri });
      continue;
    }
    if (type === 'resource' && block.resource) {
      const resource = block.resource;
      const mime = String(resource.mimeType || resource.mime_type || '').toLowerCase();
      if (mime === 'text/html' && typeof resource.text === 'string') {
        add({ id: `${prefix}:${index}`, kind: 'html', title: 'HTML preview', html: resource.text, path: resource.uri });
      } else if (mime.startsWith('image/') && resource.blob) {
        add({ id: `${prefix}:${index}`, kind: 'image', title: 'Generated image', dataUrl: normalizeImageDataUrl(resource.blob, mime), path: resource.uri });
      }
    }
  }
}

function collectStructuredArtifacts(value, add, prefix, depth = 0) {
  if (!value || typeof value !== 'object' || depth > 3) return;
  if (Array.isArray(value)) {
    value.slice(0, 50).forEach((entry, index) => collectStructuredArtifacts(entry, add, `${prefix}:${index}`, depth + 1));
    return;
  }
  const imageValue = value.image_url || value.imageUrl;
  if (imageValue) {
    const dataUrl = normalizeImageDataUrl(imageValue);
    if (dataUrl) add({ id: `${prefix}:image`, kind: 'image', title: 'Generated image', dataUrl });
  }
  const hint = pathText(value.output_hint || value.outputHint || value.path || value.uri);
  const kind = artifactKindFromPath(hint);
  if (kind) add({ id: `${prefix}:path`, kind, title: kind === 'html' ? 'HTML preview' : 'Generated image', path: hint });
  for (const [key, entry] of Object.entries(value).slice(0, 50)) {
    if (['image_url', 'imageUrl', 'output_hint', 'outputHint', 'path', 'uri'].includes(key)) continue;
    collectStructuredArtifacts(entry, add, `${prefix}:${key}`, depth + 1);
  }
}

function addArtifact(artifacts, artifact, options) {
  if (!artifact?.kind || (!artifact.dataUrl && !artifact.path && !artifact.html)) return;
  const normalized = {
    ...artifact,
    title: String(artifact.title || (artifact.kind === 'html' ? 'HTML preview' : 'Generated image')).slice(0, 160),
    ...(options.cwd && !artifact.cwd ? { cwd: String(options.cwd) } : {}),
  };
  const identity = normalized.path || normalized.dataUrl || normalized.id;
  if (artifacts.some((existing) => (existing.path || existing.dataUrl || existing.id) === identity)) return;
  artifacts.push(normalized);
}

function normalizeImageDataUrl(value, fallbackMime = 'image/png') {
  const text = String(value || '').trim();
  if (text.length > 36 * 1024 * 1024) return null;
  if (/^data:image\/[a-z0-9.+-]+(?:;[a-z0-9=.+-]+)*;base64,[a-z0-9+/=\s]+$/i.test(text)) return text;
  const base64 = text.replace(/\s+/g, '');
  if (!base64 || base64.length % 4 !== 0 || !/^[a-z0-9+/]+={0,2}$/i.test(base64)) return null;
  return `data:${String(fallbackMime || 'image/png').toLowerCase()};base64,${base64}`;
}

function mimeTypeForPath(value) {
  const lower = String(value || '').toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  return 'image/png';
}

function pathText(value) {
  return typeof value === 'string' ? value.trim() : '';
}
