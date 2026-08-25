#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)
GUIDE="$REPO_ROOT/configs/releases/a2-r1/ONLINE_INSTALL_GUIDE.md"
RELEASE="$REPO_ROOT/configs/releases/a2-r1/release.json"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_absent() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }

test -f "$GUIDE" || fail "manual deployment guide is missing"
test -f "$RELEASE" || fail "release metadata is missing"
test ! -e "$REPO_ROOT/scripts/releases/a2-r1/install.sh" || fail "duplicate a2-r1 lifecycle installer must not exist"
test ! -d "$REPO_ROOT/configs/releases/a2-r1/manifests" || fail "raw build manifests must not be committed"

for section in $(seq 1 24); do
    grep -Eq "^## $section\." "$GUIDE" || fail "guide section $section is missing"
done

assert_contains "$GUIDE" 'docker pull "$CONTROL_REGISTRY"'
assert_contains "$GUIDE" '拉取时无需执行 `docker login`'
assert_contains "$GUIDE" 'docker load -i /path/to/control.tar'
assert_contains "$GUIDE" 'generate_stress_deployment.sh'
assert_contains "$GUIDE" 'install_stress_runtime.sh'
assert_contains "$GUIDE" 'create_npu_burn_container.sh'
assert_contains "$GUIDE" '--runtime runc'
assert_contains "$GUIDE" 'docker run -d'
assert_contains "$GUIDE" '--network none'
assert_contains "$GUIDE" '--network "$CONTROL_NETWORK"'
assert_contains "$GUIDE" '-addr=127.0.0.1:29592'
assert_contains "$GUIDE" 'stress doctor'
assert_contains "$GUIDE" '--bench stream'
assert_contains "$GUIDE" '--bench hpcg'
assert_contains "$GUIDE" '--bench hpl'
assert_contains "$GUIDE" '--bench npu_burn'
assert_contains "$GUIDE" 'CPU-only CATMonitor Stress'
assert_contains "$GUIDE" '/usr/local/bin/catmonitor-stress-cpu-client'
assert_contains "$GUIDE" 'FOLLOWUP_CPU_HOTPLUG_PREFLIGHT'
legacy_acceptance_root="/home""/catmonitor/"
assert_absent "$GUIDE" "$legacy_acceptance_root"
assert_contains "$GUIDE" '/api/stress/runs'
assert_contains "$GUIDE" '/cancel'
assert_absent "$GUIDE" 'scripts/releases/a2-r1/install.sh'
assert_absent "$GUIDE" '/opt/catmonitor/releases/a2-r1'

assert_contains "$GUIDE" '--restart "$RESTART_POLICY"'
assert_contains "$GUIDE" '--read-only --cap-drop ALL'
assert_contains "$GUIDE" '--cap-add SYS_NICE'
assert_contains "$GUIDE" '--pids-limit 4096 --shm-size 16g'
assert_contains "$GUIDE" '--tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m'
assert_contains "$GUIDE" '--pid host --privileged'
assert_contains "$GUIDE" '--security-opt label=disable --group-add 65532'
assert_contains "$GUIDE" '--volume /:/host:ro,rslave'
assert_contains "$GUIDE" '/usr/local/Ascend/driver:/usr/local/Ascend/driver:ro'
assert_contains "$GUIDE" '/usr/local/Ascend/nnae:/usr/local/Ascend/nnae:ro'
assert_contains "$GUIDE" '/usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro'
assert_contains "$GUIDE" '/usr/bin/hccn_tool:/usr/bin/hccn_tool:ro'
assert_contains "$GUIDE" '/usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi:ro'
assert_contains "$GUIDE" '/var/run/docker.sock:/var/run/docker.sock:rw'
assert_contains "$GUIDE" '--entrypoint /usr/local/bin/catmonitor'
assert_contains "$GUIDE" '--entrypoint /usr/local/bin/web'
assert_contains "$GUIDE" '--entrypoint /usr/local/bin/dfee'
assert_contains "$GUIDE" '--entrypoint /usr/local/bin/catmonitor-stress-cpu-entrypoint'
assert_contains "$GUIDE" '-exporter=enabled -exporter-port=9333'
assert_contains "$GUIDE" 'CATMONITOR_NPU_DEVICE_COUNT=2'
assert_contains "$GUIDE" '/dev/davinci2、/dev/davinci5'
assert_contains "$GUIDE" 'A2、CANN 8.3.RC2、torch_npu 2.8.0、matmul'
run_count=$(grep -c '^docker run -d' "$GUIDE")
test "$run_count" -eq 5 || fail "guide must contain five explicit docker run commands, found $run_count"

if command -v python3 >/dev/null 2>&1; then
    python3 - "$RELEASE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["schema_version"] == 1
assert data["release"] == "a2-r1"
assert data["status"] == "released"
assert data["release_source_commit"] == "2ad450c2ecf8fa10e2bff64b250cdfe3bf1c6996"
assert data["golden_functional_base_commit"] == "e8c6f0ae4b2d0d7ba3c6a9d705533ed3a887e213"
assert data["platform"] == {"os": "linux", "architecture": "arm64"}
assert data["images"]["control"]["id"] == "sha256:f238d75fe8902a7ea39ec6c1261a674cb6446815116355f94b4b945b21a60424"
assert data["images"]["cpu_runner"]["id"] == "sha256:61e5a5f273684be3cdf18031ad742cf38bbe3512136b64c6e5f705f4356bd2aa"
assert data["images"]["npu_burn"]["id"] == "sha256:d23553954429c9c16e7f4bb1407b48c4b5bfa8c70b2d57b681245bc46e566160"
assert data["images"]["control"]["registry_digest"] == "sha256:8d213f304e96c86f721050a153e42d1857e5214e464be3423633b56531d91cd2"
assert data["images"]["cpu_runner"]["registry_digest"] == "sha256:8cd0416bb4e39a22fbc9475f17c733427b2f738e61b034902f723833b2a77e1e"
assert data["images"]["npu_burn"]["registry_digest"] == "sha256:a837138704c64eaa72050ab7b0f0ba419c81c83ff6e713f37678dd9aae773da6"
assert data["images"]["cpu_runner"]["registry"] == "ghcr.io/spike677/catmonitor-stress-cpu-runner:a2-r1"
assert data["profile"]["validated_device_nodes"] == [2, 5]
assert data["profile"]["npu_burn_logical_ids"] == [0, 1]

def reject_local_paths(value):
    if isinstance(value, dict):
        for item in value.values():
            reject_local_paths(item)
    elif isinstance(value, list):
        for item in value:
            reject_local_paths(item)
    elif isinstance(value, str):
        assert "/opt/catmonitor/releases/" not in value
        assert "/var/tmp/" not in value

reject_local_paths(data)
PY
fi

printf 'PASS: a2-r1 manual deployment specification contract\n'
