#!/usr/bin/env python3
"""install-wizard.py —— 浏览器版安装向导（本机小服务，给 Windows/macOS 的"安装包式"体验）

为什么有这么个东西：命令行向导对不熟终端的人不友好（尤其 Windows）。
这里用 python3 起一个只绑 127.0.0.1 的小页面，把 install.sh 的选择项做成点选，
点"开始安装"就相当于跑 `install.sh --yes <选择>`，日志实时回显。

设计取舍：
  · 检测逻辑只有一份 —— 页面数据来自 `install.sh --json`，安装也交给 install.sh，
    这个文件只做"页面 + 转发"，不复制任何安装逻辑；
  · 只依赖标准库（python3 到处都有），不需要 node；
  · 只绑 127.0.0.1，所有接口要带一次性 token（URL 里那个），避免同一台机器上别的页面乱调。
"""
import argparse, json, os, random, re, string, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.join(HERE, 'install.sh')
HTML = os.path.join(HERE, 'install-wizard.html')

state = {
    'log': '', 'running': False, 'done': False, 'exitCode': None, 'argv': [],
    'startedAt': 0, 'finishedAt': 0,
}
build_cmd = []


def detect(extra_args):
    """跑 install.sh --json 拿体检结果（只读）。"""
    try:
        out = subprocess.run(['bash', INSTALLER, '--json'] + extra_args,
                             capture_output=True, text=True, timeout=60)
        return json.loads(out.stdout or '{}')
    except Exception as exc:  # noqa: BLE001 —— 探测失败不该让向导起不来
        return {'ok': False, 'error': f'{type(exc).__name__}: {exc}'}


def run_install(argv):
    global state
    state.update({'log': '', 'running': True, 'done': False, 'exitCode': None,
                  'argv': argv, 'startedAt': time.time(), 'finishedAt': 0})
    def worker():
        try:
            proc = subprocess.Popen(['bash', INSTALLER] + argv, cwd=HERE,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, bufsize=1)
            for line in proc.stdout:
                state['log'] += line
            state['exitCode'] = proc.wait()
        except Exception as exc:  # noqa: BLE001
            state['log'] += f'\n[向导] 启动安装进程失败：{exc}\n'
            state['exitCode'] = -1
        finally:
            state['running'] = False
            state['done'] = True
            state['finishedAt'] = time.time()
    threading.Thread(target=worker, daemon=True).start()



def open_browser(url):
    """在 WSL 里 python 自己打不开浏览器，得借 Windows 的 cmd.exe / wslview。"""
    wsl = False
    try:
        wsl = 'microsoft' in open('/proc/version', encoding='utf-8', errors='ignore').read().lower()
    except Exception:  # noqa: BLE001
        pass
    if wsl:
        for cmd in (['cmd.exe', '/c', 'start', '', url], ['wslview', url], ['explorer.exe', url]):
            try:
                subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return
            except Exception:  # noqa: BLE001
                continue
    try:
        import webbrowser
        webbrowser.open(url)
    except Exception:  # noqa: BLE001
        pass

class Handler(BaseHTTPRequestHandler):
    server_version = 'qqbot-install-wizard'
    token = ''
    extra = []

    def log_message(self, fmt, *args):  # 安静点，别把日志刷满
        pass

    def _send(self, code, body, ctype='application/json; charset=utf-8'):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('content-type', ctype)
        self.send_header('content-length', str(len(body)))
        self.send_header('cache-control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def _auth(self, query):
        tok = str(query.get('t', [''])[0]) or self.headers.get('x-wizard-token', '')
        return tok == self.token

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == '/':
            try:
                page = open(HTML, encoding='utf-8').read()
            except FileNotFoundError:
                return self._send(500, '缺少 install-wizard.html', 'text/plain; charset=utf-8')
            page = page.replace('__TOKEN__', self.token)
            return self._send(200, page, 'text/html; charset=utf-8')
        if not self._auth(q):
            return self._send(403, json.dumps({'ok': False, 'error': 'token 不对'}))
        if url.path == '/api/state':
            data = detect(self.extra)
            data['installer'] = INSTALLER
            data['extraArgs'] = self.extra
            data['running'] = state['running']
            return self._send(200, json.dumps(data, ensure_ascii=False))
        if url.path == '/api/log':
            off = int(str(q.get('offset', ['0'])[0]) or 0)
            text = state['log'][off:]
            return self._send(200, json.dumps({
                'text': text, 'offset': off + len(text), 'running': state['running'],
                'done': state['done'], 'exitCode': state['exitCode'], 'argv': state['argv'],
            }, ensure_ascii=False))
        return self._send(404, json.dumps({'ok': False, 'error': 'no such path'}))

    def do_POST(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if not self._auth(q):
            return self._send(403, json.dumps({'ok': False, 'error': 'token 不对'}))
        if url.path != '/api/install':
            return self._send(404, json.dumps({'ok': False, 'error': 'no such path'}))
        if state['running']:
            return self._send(409, json.dumps({'ok': False, 'error': '已经在装了'}, ensure_ascii=False))
        length = int(self.headers.get('content-length') or 0)
        try:
            body = json.loads(self.rfile.read(length) or b'{}')
        except Exception:  # noqa: BLE001
            body = {}
        argv = ['--yes']
        mode = str(body.get('mode') or 'napcat')
        if mode not in ('napcat', 'reuse', 'none'):
            mode = 'napcat'
        argv += ['--mode', mode]
        ports = str(body.get('ports') or '').strip()
        if re.fullmatch(r'\d{1,5},\d{1,5}', ports):
            argv += ['--ports', ports]
        for key, flag in (('dataRoot', '--data-root'), ('workspace', '--workspace'),
                          ('tz', '--tz'), ('proxy', '--proxy')):
            val = str(body.get(key) or '').strip()
            if val:
                argv += [flag, val]
        if body.get('dev'):
            argv.append('--dev')
        if body.get('noProxy'):
            argv.append('--no-proxy')
        argv += list(self.extra)
        run_install(argv)
        return self._send(200, json.dumps({'ok': True, 'argv': argv}, ensure_ascii=False))


def main():
    global INSTALLER
    ap = argparse.ArgumentParser()
    ap.add_argument('--bind', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=8790)
    ap.add_argument('--installer', default=INSTALLER)
    ap.add_argument('--desktop', action='store_true')
    ap.add_argument('--legacy-compat', action='store_true')
    ap.add_argument('--no-open', action='store_true')
    args = ap.parse_args()

    INSTALLER = os.path.abspath(args.installer)
    extra = []
    if args.desktop:
        extra.append('--desktop')
    if args.legacy_compat:
        extra.append('--legacy-compat')
    Handler.extra = extra
    Handler.token = ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(16))

    port = args.port
    httpd = None
    for _ in range(20):
        try:
            httpd = ThreadingHTTPServer((args.bind, port), Handler)
            break
        except OSError:
            port += 1
    if httpd is None:
        print('[向导] 起不来：端口都被占了，换个范围用 --port 试试', file=sys.stderr, flush=True)
        return 2

    url = f'http://127.0.0.1:{port}/?t={Handler.token}'
    print()
    print('=' * 60)
    print(' 浏览器版安装向导已经起好，在浏览器里打开这个地址：')
    print(f'   {url}')
    print()
    print(' （页面里点选你的选择 → 开始安装 → 日志实时显示）')
    print(' 装完这个窗口可以关掉：Ctrl+C')
    print('=' * 60, flush=True)
    if not args.no_open:
        threading.Timer(0.6, lambda: open_browser(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\n[向导] 已停止')
    return 0


if __name__ == '__main__':
    sys.exit(main())
