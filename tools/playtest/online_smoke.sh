#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import pathlib, re, subprocess, time
logs = pathlib.Path('artifacts')
logs.mkdir(exist_ok=True)
with (logs/'qa-online-host.log').open('w') as out:
    host = subprocess.Popen(['tools/godot.sh', '--headless', 'res://tools/playtest/online_smoke_host.tscn', '--', '--port=0'], stdout=out, stderr=subprocess.STDOUT)
    try:
        port = None
        for _ in range(100):
            match = re.search(r'SMOKE_PORT=(\d+)', (logs/'qa-online-host.log').read_text())
            if match:
                port = match[1]
                break
            time.sleep(.1)
        assert port, 'Host did not publish port within 10 seconds'
        with (logs/'qa-online-client.log').open('w') as client_log:
            client = subprocess.run(['tools/godot.sh', '--headless', 'res://tools/playtest/online_smoke_client.tscn', '--', '--port='+port], stdout=client_log, stderr=subprocess.STDOUT, timeout=25)
        assert client.returncode == 0, 'Client failed'
        assert host.wait(timeout=25) == 0, 'Host failed'
        a = (logs/'qa-online-host.log').read_text()
        b = (logs/'qa-online-client.log').read_text()
        print('HOST\n'+a+'CLIENT\n'+b)
        assert 'SMOKE_SEATS=2' in a
        assert re.search(r'SMOKE_SEED=(\d+)', a)[1] == re.search(r'SMOKE_SEED=(\d+)', b)[1]
        print('ONLINE_SMOKE_PASS')
    finally:
        if host.poll() is None:
            host.kill()
        host.wait(timeout=5)
PY
