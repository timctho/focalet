import { Marked } from '../node_modules/marked/lib/marked.esm.js';

const markdown = new Marked({
  gfm: true,
  breaks: true,
  renderer: {
    html({ text }) {
      return escapeHtml(text);
    },
    link({ href, title, tokens }) {
      const label = this.parser.parseInline(tokens);
      const safeHref = safeMarkdownUrl(href);
      if (!safeHref) return label;
      const titleAttribute = title ? ` title="${escapeAttribute(title)}"` : '';
      return `<a href="${escapeAttribute(safeHref)}" target="_blank" rel="noopener noreferrer"${titleAttribute}>${label}</a>`;
    },
    image({ href, title, text }) {
      const safeHref = safeMarkdownUrl(href, { image: true });
      if (!safeHref) return `<span class="markdown-image-reference">${escapeHtml(text || 'Image')}</span>`;
      const titleAttribute = title ? ` title="${escapeAttribute(title)}"` : '';
      return `<img src="${escapeAttribute(safeHref)}" alt="${escapeAttribute(text || 'Markdown image')}" loading="lazy"${titleAttribute}>`;
    },
  },
});

export function renderMarkdown(value) {
  return markdown.parse(String(value || ''), { async: false });
}

export function safeMarkdownUrl(value, { image = false } = {}) {
  const url = String(value || '').trim();
  if (!url || /[\u0000-\u001f\u007f]/.test(url)) return null;
  const schemeProbe = url.replace(/[\s\u00a0]+/g, '');
  if (image && /^data:image\/(?:png|jpe?g|gif|webp|bmp|svg\+xml);base64,[a-z0-9+/=\s]+$/i.test(url)) return url;
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(schemeProbe)?.[1]?.toLowerCase();
  if (!scheme) return url;
  if (image) return null;
  return ['http', 'https', 'mailto'].includes(scheme) ? url : null;
}

function escapeHtml(value) {
  return String(value || '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function escapeAttribute(value) {
  return escapeHtml(value).replaceAll('`', '&#96;');
}
