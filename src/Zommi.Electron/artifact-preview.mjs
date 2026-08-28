import { readFile, stat } from 'node:fs/promises';
import { basename, isAbsolute, posix, resolve, win32 } from 'node:path';
import { fileURLToPath } from 'node:url';
import { artifactKindFromPath } from './artifacts.mjs';

const MAX_IMAGE_BYTES = 25 * 1024 * 1024;
const MAX_HTML_BYTES = 5 * 1024 * 1024;

export async function loadArtifactPreview(request, options = {}) {
  if (!request || typeof request !== 'object') throw new Error('Artifact preview request is invalid.');
  const sourcePath = String(request.path || '').trim();
  const kind = request.kind || artifactKindFromPath(sourcePath);
  if (!['image', 'html'].includes(kind) || artifactKindFromPath(sourcePath) !== kind) {
    throw new Error('Only generated image and HTML files can be previewed.');
  }
  const resolvedPath = resolveArtifactPath(request, options.runtimeState, options.platform);
  const metadata = await (options.statFile || stat)(resolvedPath);
  if (!metadata.isFile()) throw new Error('Artifact preview requires a regular file.');
  const maximum = kind === 'image' ? MAX_IMAGE_BYTES : MAX_HTML_BYTES;
  if (metadata.size > maximum) throw new Error(`Artifact preview exceeds ${Math.round(maximum / 1024 / 1024)} MB.`);
  const bytes = await (options.readFile || readFile)(resolvedPath);
  const name = artifactBasename(sourcePath);
  if (kind === 'html') return { kind, name, path: sourcePath, html: bytes.toString('utf8') };
  return {
    kind,
    name,
    path: sourcePath,
    dataUrl: `data:${imageMimeType(sourcePath)};base64,${bytes.toString('base64')}`,
  };
}

export function resolveArtifactPath(request, runtimeState = {}, platform = process.platform) {
  let sourcePath = String(request?.path || '').trim();
  if (!sourcePath || sourcePath.length > 4096) throw new Error('Artifact path is invalid.');
  if (/^file:/i.test(sourcePath)) sourcePath = fileURLToPath(sourcePath);
  if (/^[a-z]+:/i.test(sourcePath) && !/^[a-z]:[\\/]/i.test(sourcePath)) {
    throw new Error('Remote artifact URLs are not available as local previews.');
  }
  const requestedTargetId = String(request.runtimeTargetId || '');
  const target = requestedTargetId
    ? (runtimeState?.targets || []).find((candidate) => candidate.id === requestedTargetId)
    : runtimeState?.activeTarget || null;
  if (requestedTargetId && !target) throw new Error('Artifact runtime target is no longer available.');
  const host = target?.executionHost;
  if (host?.kind === 'remote') throw new Error('Remote runtime files cannot be previewed locally.');
  const basePath = String(request.cwd || target?.runtimeHome || '').trim();
  if (platform === 'win32' && host?.kind === 'wsl') {
    if (!/^[a-z0-9._-]+$/i.test(String(host.name || ''))) throw new Error('WSL artifact host is invalid.');
    const linuxPath = posix.isAbsolute(sourcePath) ? posix.normalize(sourcePath) : posix.resolve(basePath || '/', sourcePath);
    return `\\\\wsl.localhost\\${host.name}\\${linuxPath.slice(1).replaceAll('/', '\\')}`;
  }
  if (platform === 'win32') return win32.isAbsolute(sourcePath) ? win32.normalize(sourcePath) : win32.resolve(basePath || process.cwd(), sourcePath);
  return isAbsolute(sourcePath) ? resolve(sourcePath) : resolve(basePath || process.cwd(), sourcePath);
}

function artifactBasename(value) {
  const text = String(value || '').replaceAll('\\', '/');
  return basename(text);
}

function imageMimeType(value) {
  const lower = String(value || '').toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  return 'image/png';
}
