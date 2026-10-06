import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:markdown/markdown.dart' as markdown;
import 'package:path/path.dart' as paths;

/// A per-document, loopback-only origin for native browser previews.
/// Relative styles, images and scripts work without granting a page app APIs.
final class DocumentServer {
  DocumentServer._(
    this._server,
    this._token,
    this._content,
    this._root,
    this._name,
    this._fragment,
  );

  final HttpServer _server;
  final String _token;
  final String _content;
  final String? _root;
  final String _name;
  final String _fragment;

  Uri get uri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    pathSegments: [_token, _name],
    fragment: _fragment.isEmpty ? null : _fragment,
  );

  static Future<DocumentServer> start({
    required String content,
    Uri? fileUri,
    bool isMarkdown = false,
  }) async {
    String? root;
    var name = 'document.html';
    if (fileUri != null) {
      final file = File.fromUri(fileUri.replace(fragment: '', query: ''));
      root = await file.parent.resolveSymbolicLinks();
      name = paths.basename(file.path);
    }
    final random = Random.secure();
    final token = base64UrlEncode(
      List.generate(24, (_) => random.nextInt(256)),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final document = DocumentServer._(
      server,
      token,
      isMarkdown ? markdownDocument(content) : content,
      root,
      name,
      fileUri?.fragment ?? '',
    );
    server.listen(document._respond);
    return document;
  }

  bool allowsNavigation(String value) {
    final target = Uri.tryParse(value);
    return target != null &&
        target.scheme == 'http' &&
        target.origin == uri.origin &&
        target.pathSegments.isNotEmpty &&
        target.pathSegments.first == _token;
  }

  Future<void> _respond(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set(
        'Content-Security-Policy',
        "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline'; connect-src 'self'; "
            "object-src 'none'; frame-src 'none'; base-uri 'self'; form-action 'none'",
      );
    try {
      final parts = request.uri.pathSegments;
      if (!const {'GET', 'HEAD'}.contains(request.method)) {
        response.statusCode = HttpStatus.methodNotAllowed;
      } else if (request.headers.value('host') != '127.0.0.1:${_server.port}' ||
          parts.length < 2 ||
          parts.first != _token ||
          parts
              .skip(1)
              .any(
                (part) =>
                    part.isEmpty ||
                    part.startsWith('.') ||
                    part.contains('/') ||
                    part.contains(r'\'),
              )) {
        response.statusCode = HttpStatus.notFound;
      } else if (parts.length == 2 && parts.last == _name) {
        response.headers.contentType = ContentType.html;
        if (request.method == 'GET') response.write(_content);
      } else if (_root == null) {
        response.statusCode = HttpStatus.notFound;
      } else {
        final file = File(paths.joinAll([_root, ...parts.skip(1)]));
        final resolved = await file.resolveSymbolicLinks();
        final mime = _mimeTypes[paths.extension(resolved).toLowerCase()];
        if (!paths.isWithin(_root, resolved) ||
            mime == null ||
            await File(resolved).length() > 25 * 1024 * 1024) {
          response.statusCode = HttpStatus.notFound;
        } else {
          response.headers.set('Content-Type', mime);
          if (request.method == 'GET') {
            if (const {
              '.md',
              '.markdown',
            }.contains(paths.extension(resolved))) {
              response.write(
                markdownDocument(await File(resolved).readAsString()),
              );
            } else {
              await response.addStream(File(resolved).openRead());
            }
          }
        }
      }
    } on FileSystemException {
      response.statusCode = HttpStatus.notFound;
    } on Object {
      response.statusCode = HttpStatus.badRequest;
    } finally {
      await response.close();
    }
  }

  Future<void> close() => _server.close(force: true);
}

const _mimeTypes = {
  '.md': 'text/html; charset=utf-8',
  '.markdown': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
};

String markdownDocument(String source) {
  final body = markdown.markdownToHtml(
    source,
    extensionSet: markdown.ExtensionSet.gitHubWeb,
  );
  return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{color-scheme:light dark;--paper:#fff;--ink:#223340;--muted:#e8eff4;--accent:#387da8}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);
font:16px/1.65 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1080px;margin:auto;padding:32px clamp(20px,5vw,64px) 72px}
h1,h2,h3{line-height:1.25;margin:1.3em 0 .6em}h1,h2{border-bottom:1px solid var(--muted);padding-bottom:.3em}
a{color:var(--accent)}img,svg{max-width:100%;height:auto}pre{overflow:auto;padding:18px;
background:var(--muted);border-radius:10px;position:relative}code{font-family:Consolas,Menlo,monospace;
font-size:.9em}p code,li code{background:var(--muted);padding:.15em .3em;border-radius:4px}
table{display:block;overflow:auto;border-collapse:collapse;margin:20px 0;width:max-content;max-width:100%}
th,td{border:1px solid var(--muted);padding:9px 14px;text-align:left}th{background:var(--muted)}
blockquote{margin-left:0;border-left:4px solid var(--accent);padding:4px 20px;background:var(--muted)}
li+li{margin-top:.3em}hr{border:0;border-top:1px solid var(--muted);margin:28px 0}
pre button{position:absolute;right:8px;top:8px;border:1px solid var(--accent);border-radius:5px;
background:var(--paper);color:var(--ink);padding:4px 8px;cursor:pointer}
@media(prefers-color-scheme:dark){:root{--paper:#18232c;--ink:#e4edf3;--muted:#293945;--accent:#accee6}}
</style></head><body><main>$body</main><script>
const used=new Set();document.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(h=>{
const base=h.textContent.trim().toLowerCase().replace(/[^\\p{L}\\p{N} _-]/gu,'').replace(/ /g,'-');
let id=base,n=0;while(used.has(id))id=base+'-'+(++n);used.add(id);h.id=id;});
document.querySelectorAll('pre').forEach(pre=>{const code=pre.querySelector('code');if(!code)return;
const button=document.createElement('button');button.textContent='Copy';button.onclick=async()=>{
try{await navigator.clipboard.writeText(code.textContent);button.textContent='Copied';
setTimeout(()=>button.textContent='Copy',1200);}catch{button.textContent='Select to copy';}};pre.append(button);});
if(location.hash){try{document.getElementById(decodeURIComponent(location.hash.slice(1)))?.scrollIntoView();}catch{}}
</script></body></html>''';
}
