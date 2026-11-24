"""Shared helpers of the phase-5 server checks: test accounts (created through the
DOOM_ADMIN broker, dropped again at the end), an owner connection, a referee run in-process or as
a subprocess."""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLIENT = HERE.parent / "client"
sys.path.insert(0, str(CLIENT))
import oradb  # noqa: E402
import accounts  # noqa: E402
import api_client  # noqa: E402

PY = sys.executable
TEST_PASSWORD = "Doom-Test-Pw-2026"


def owner():
    conn = oradb.connect()
    cur = conn.cursor()
    return conn, cur


def make_accounts(names, kind="player"):
    conn, cur = owner()
    for n in names:
        accounts.add_account(cur, n, TEST_PASSWORD, kind)
    conn.close()
    return {n: TEST_PASSWORD for n in names}


def drop_accounts(names):
    conn, cur = owner()
    out = {}
    for n in names:
        for attempt in range(20):
            try:
                out[n] = accounts.drop_account(cur, n)
                break
            except Exception as exc:  # noqa: BLE001 - ORA-01940: a session still closing
                if attempt == 19:
                    out[n] = f"FAILED {str(exc).splitlines()[0]}"
                time.sleep(0.5)
    conn.close()
    return out


def player(name):
    return api_client.ApiPlayer(name, TEST_PASSWORD)


def match_cleanup():
    """Leave no match behind: the match tables empty, as the phase 3/4 harnesses expect."""
    conn, cur = owner()
    for t in ("g_mp_inputs", "g_mp_join_requests", "g_mp_players", "g_mp_match", "g_mp_waiting", "g_mp_holders",
              "g_mp_referee", "g_mp_rotation"):
        cur.execute(f"DELETE FROM {t}")
    conn.commit()
    conn.close()


class RefereeProcess:
    """client/referee.py as a subprocess (environment = its configuration); lines collected."""

    def __init__(self, env=None, args=()):
        e = dict(os.environ, PYTHONUNBUFFERED="1")
        e.update({k: str(v) for k, v in (env or {}).items()})
        self.p = subprocess.Popen([PY, str(CLIENT / "referee.py"), *args], env=e, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True)
        self.lines = []
        self.t = threading.Thread(target=self._pump, daemon=True)
        self.t.start()

    def _pump(self):
        for line in self.p.stdout:
            self.lines.append(line.rstrip())

    def wait_for(self, text, timeout=120):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if any(text in l for l in self.lines):
                return True
            if self.p.poll() is not None:
                time.sleep(0.2)
                return any(text in l for l in self.lines)
            time.sleep(0.1)
        return False

    def stop(self, sig=None, timeout=15):
        import signal
        if self.p.poll() is None:
            self.p.send_signal(sig or signal.SIGINT)
        try:
            self.p.wait(timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
            return False
        self.t.join(2)
        return True
