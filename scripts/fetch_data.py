#!/usr/bin/env python3
import os
import sys
import ssl
from pathlib import Path, PurePosixPath
import urllib.request
import urllib.parse

def make_ssl_context():
    # On managed/corporate machines, trust the OS certificate store (which holds
    # the org root CA used for TLS inspection); fall back to certifi, then to the
    # stdlib default.
    try:
        import truststore
        return truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    except ImportError:
        pass
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()

def parse_config(cfg_path):
    s3_base = None
    key = None
    data_root = 'data'
    with open(cfg_path, 'r', encoding='utf8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('s3_base:'):
                s3_base = _value(line)
            elif line.startswith('key:'):
                key = _value(line)
            elif line.startswith('data_root:'):
                data_root = _value(line)
    return s3_base, key, data_root

def _value(line):
    # take everything after the first colon, drop any inline comment
    v = line.split(':', 1)[1]
    v = v.split('#', 1)[0]
    return v.strip()

def download(url, out_path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {url}\n  -> {out_path}")
    try:
        ctx = make_ssl_context()
        with urllib.request.urlopen(url, context=ctx) as resp, open(out_path, 'wb') as out:
            chunk_size = 1024*1024
            while True:
                chunk = resp.read(chunk_size)
                if not chunk:
                    break
                out.write(chunk)
    except Exception as e:
        print('Download failed:', e)
        return False
    return True

def reference_keys(cphd_key):
    # The pipeline also uses the sibling GEC GeoTIFF and METADATA JSON, which
    # live in the same capture folder and share the capture name prefix.
    p = PurePosixPath(cphd_key)
    if not p.name.endswith('_CPHD.cphd'):
        return []
    base = p.name[:-len('_CPHD.cphd')]
    return [str(p.with_name(base + '_GEC.tif')),
            str(p.with_name(base + '_METADATA.json'))]

def main():
    repo_root = Path(__file__).resolve().parents[1]
    cfg_path = repo_root / 'config.yaml'
    if not cfg_path.exists():
        print('config.yaml not found at', cfg_path)
        sys.exit(1)
    s3_base, key, data_root = parse_config(cfg_path)
    if not s3_base or not key:
        print('s3_base or key not found in config.yaml')
        sys.exit(1)

    local_root = repo_root / data_root
    base_url = s3_base.rstrip('/') + '/'
    keys = [key] + reference_keys(key)

    failed = False
    for k in keys:
        url = urllib.parse.urljoin(base_url, k.lstrip('/'))
        local_path = local_root / Path(k)
        if local_path.exists():
            print('File already exists locally at', local_path)
            continue
        if download(url, local_path):
            print('Download complete:', local_path)
        else:
            failed = True

    if failed:
        print('One or more files failed to download.')
        sys.exit(2)

if __name__ == '__main__':
    main()
