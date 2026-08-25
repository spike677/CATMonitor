#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
INSTALLER=$REPO_ROOT/scripts/releases/a2-r1/install.sh
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_fails() {
    if "$@" >"$TEST_ROOT/unexpected.out" 2>"$TEST_ROOT/unexpected.err"; then
        fail "command unexpectedly succeeded: $*"
    fi
}

bash -n "$INSTALLER"

FAKE_DOCKER=$TEST_ROOT/docker
DOCKER_LOG=$TEST_ROOT/docker.log
cat >"$FAKE_DOCKER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CATMONITOR_TEST_DOCKER_LOG:?}"
[ "${1-}" = info ] && exit 0
exit 0
EOF
chmod 0755 "$FAKE_DOCKER"

PATH="$TEST_ROOT:$PATH" CATMONITOR_TEST_DOCKER_LOG="$DOCKER_LOG" \
    bash "$INSTALLER" --action plan >"$TEST_ROOT/plan.out"
assert_contains "$TEST_ROOT/plan.out" 'release: a2-r1'
assert_contains "$TEST_ROOT/plan.out" 'Golden image source: e8c6f0ae4b2d0d7ba3c6a9d705533ed3a887e213'
assert_contains "$TEST_ROOT/plan.out" 'ghcr.io/spike677/catmonitor-npu:a2-r1'
assert_contains "$TEST_ROOT/plan.out" 'ghcr.io/spike677/catmonitor-stress-cpu:a2-r1'
assert_contains "$TEST_ROOT/plan.out" 'ghcr.io/spike677/catmonitor-npuburn:a2-r1'
assert_contains "$TEST_ROOT/plan.out" 'registry policy: online first'
assert_contains "$TEST_ROOT/plan.out" 'workload execution: none'
if grep -Eq 'pull|load|run|compose' "$DOCKER_LOG"; then
    fail 'release plan must not pull images or start containers'
fi

assert_fails env PATH="$TEST_ROOT:$PATH" CATMONITOR_TEST_DOCKER_LOG="$DOCKER_LOG" \
    bash "$INSTALLER" --action up
assert_contains "$TEST_ROOT/unexpected.err" 'requires --acknowledge-root-docker-socket'

assert_fails env PATH="$TEST_ROOT:$PATH" CATMONITOR_TEST_DOCKER_LOG="$DOCKER_LOG" \
    bash "$INSTALLER" --action invalid
assert_contains "$TEST_ROOT/unexpected.err" 'unsupported action'

CPU_MANIFEST=$REPO_ROOT/configs/releases/a2-r1/manifests/cpu-runner-image-manifest.json
NPU_MANIFEST=$REPO_ROOT/configs/releases/a2-r1/manifests/npu-burn-image-manifest.json
[ "$(sha256sum "$CPU_MANIFEST" | awk '{print $1}')" = 2cedcfa48b71f3130a59746901a1202940188762dd009af5a1badc33d8679d89 ] || \
    fail 'CPU release manifest differs from the Golden manifest'
[ "$(sha256sum "$NPU_MANIFEST" | awk '{print $1}')" = f7df003c02ee1b1122aacf98214f933fdaa76879ac7ece1474ef0abc7230bd98 ] || \
    fail 'NPU release manifest differs from the Golden manifest'

for expected in \
    '--name catmonitor-cpu-runner' \
    '--name catmonitor ' \
    '--name catmonitor-web' \
    '--name catmonitor-dfee' \
    '--name catmonitor-stress-web' \
    '--runtime runc' \
    '--network none' \
    '--privileged' \
    '-addr=:19322' \
    '-addr=:19323' \
    '-addr=127.0.0.1:29592' \
    '/var/run/docker.sock:/var/run/docker.sock' \
    'wait_for_url http://127.0.0.1:19320/metrics' \
    'wait_for_snapshot' \
    'run_doctor'; do
    assert_contains "$INSTALLER" "$expected"
done

[ "$(grep -c '^[[:space:]]*docker run -d' "$INSTALLER")" -eq 5 ] || \
    fail 'A2 installer must define the five direct docker-run services; NPU uses the fixed-container helper'

if grep -Eq 'docker[[:space:]]+compose|scripts/catmonitor-install|build_cpu_benchmarks|build_cpu_runner_image|build_npu_burn_image|stress[[:space:]]+(run[[:space:]]+)?--bench' "$INSTALLER"; then
    fail 'online release installer must not require Compose, delegate lifecycle, build images or start workloads'
fi

printf 'PASS: A2 online release plan, direct six-container topology, Golden identities and no-build/no-workload contract\n'
