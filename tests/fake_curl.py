#!/usr/bin/python3
import json, os, sys
from pathlib import Path
from urllib.parse import urlparse
args = [a for a in sys.argv[1:] if not a.startswith('-') and not a.isdigit()]
url = next((a for a in reversed(args) if '://' in a), '')
if 'github.com/robots.txt' in url:
    raise SystemExit(0)
parsed = urlparse(url)
box = parsed.hostname.split('.', 1)[0] if parsed.hostname else ''
port = str(parsed.port or (443 if parsed.scheme == 'https' else 80))
state_file = Path(os.environ['SILO_FAKE_STATE']) / 'state.json'
state = json.loads(state_file.read_text())
content = state.get('sandboxes', {}).get(box, {}).get('port_content', {}).get(port)
if content is None:
    raise SystemExit(7)
sys.stdout.write(content)
