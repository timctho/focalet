import assert from 'node:assert/strict';
import test from 'node:test';
import { renderMarkdown, safeMarkdownUrl } from '../renderer/markdown.mjs';

test('assistant Markdown renders common block and inline structures', () => {
  const html = renderMarkdown('# Result\n\n- **Ready**\n- `safe`\n\n```js\nconst value = 1;\n```\n\n| A | B |\n| - | - |\n| 1 | 2 |');
  assert.match(html, /<h1>Result<\/h1>/);
  assert.match(html, /<ul>[\s\S]*<strong>Ready<\/strong>[\s\S]*<code>safe<\/code>/);
  assert.match(html, /<pre><code class="language-js">/);
  assert.match(html, /<table>[\s\S]*<th>A<\/th>[\s\S]*<td>1<\/td>/);
});

test('assistant Markdown escapes raw HTML and rejects executable URLs', () => {
  const html = renderMarkdown('<script>window.bad = true</script>\n\n[unsafe](javascript:alert(1)) [safe](https://example.test)');
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;script&gt;window\.bad = true&lt;\/script&gt;/);
  assert.doesNotMatch(html, /href="javascript:/i);
  assert.match(html, /href="https:\/\/example\.test"/);
  assert.equal(safeMarkdownUrl('data:text/html;base64,PHNjcmlwdD4='), null);
  assert.equal(safeMarkdownUrl('data:image/png;base64,aGVsbG8=', { image: true }), 'data:image/png;base64,aGVsbG8=');
});
