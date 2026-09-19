"""Test-only: prepare isolated CI worlds and short-lived TLS credentials."""
import json
import os
from pathlib import Path
import subprocess

root = Path(os.environ["GITHUB_WORKSPACE"])
client = root / ".ci-voxim"
base = Path(os.environ["RUNNER_TEMP"]) / "voxim-tests"
base.mkdir()

# 只修改 CI 临时检出的实验清单；新世界使用当前 kernel，不冒充历史世界版本。
manifest = client / "Docs/R6/runtime/s4_worldgen_manifest.json"
data = json.loads(manifest.read_text())
data.pop("content_version", None)
manifest.write_text(json.dumps(data))

certs = base / "certs"
certs.mkdir(mode=0o700)
def openssl(*args):
    subprocess.run(["openssl", *args], cwd=certs, check=True, capture_output=True)

openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "2",
        "-subj", "/CN=Voxim-CI-CA", "-keyout", "ca.key", "-out", "ca.pem")
openssl("req", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=localhost",
        "-keyout", "server.key", "-out", "server.csr")
(certs / "server.ext").write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n")
openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
        "-CAcreateserial", "-days", "2", "-sha256", "-extfile", "server.ext", "-out", "server.pem")
openssl("verify", "-CAfile", "ca.pem", "-verify_hostname", "localhost", "server.pem")

values = {
    "E1_FIXTURE": client / "Docs/M1/runtime/S1/world-fixture",
    "IS_FIXTURE": client / "Docs/M1/runtime/S1/world-fixture",
    "E1_PROFILE": client / "Docs/M0/fixtures/suite.json",
    "IS_PROFILE": client / "Docs/M0/fixtures/suite.json",
    "E1_MANIFEST": manifest,
    "IS_CACHE": base,
    "VOXIM_TEST_CERTS": certs,
}
with open(os.environ["GITHUB_ENV"], "a") as env:
    for name, value in values.items():
        env.write(f"{name}={value}\n")
