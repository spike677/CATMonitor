#!/usr/bin/env bash
# Online-first A2 release installer. It pulls the three already-validated
# images, prepares reviewed Stress assets, and starts the reviewed six-container
# topology with Docker directly. It never builds images or starts a workload.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)

ACTION=up
OFFLINE_BUNDLE=
ACK_ROOT_DOCKER_SOCKET=false
REPLACE_CONFIG=false
CONFIG_PATH=/etc/catmonitor/catmonitor.yaml
GENERATED_ROOT=/etc/catmonitor/stress-deployment
PLUGIN_ROOT=/opt/catmonitor/stress
STATE_ROOT=/var/lib/catmonitor
STRESS_STATE=$STATE_ROOT/stress
NPU_OUTPUT_DIR=$STRESS_STATE/npu-burn-output
SOCKET_ROOT=/run/catmonitor-stress

GOLDEN_SOURCE=e8c6f0ae4b2d0d7ba3c6a9d705533ed3a887e213
CONTROL_IMAGE=ghcr.io/spike677/catmonitor-npu:a2-r1
CPU_IMAGE=ghcr.io/spike677/catmonitor-stress-cpu:a2-r1
NPU_IMAGE=ghcr.io/spike677/catmonitor-npuburn:a2-r1
CONTROL_ID=sha256:f238d75fe8902a7ea39ec6c1261a674cb6446815116355f94b4b945b21a60424
CPU_ID=sha256:61e5a5f273684be3cdf18031ad742cf38bbe3512136b64c6e5f705f4356bd2aa
NPU_ID=sha256:d23553954429c9c16e7f4bb1407b48c4b5bfa8c70b2d57b681245bc46e566160

usage() {
    cat <<'EOF'
Usage:
  scripts/releases/a2-r1/install.sh [OPTIONS]

Options:
  --action ACTION          plan, up, status, doctor or down (default: up)
  --offline-bundle PATH    Golden Offline Acceptance Bundle used only when a
                           registry pull fails
  --replace-config         Replace a pre-existing unmanaged CATMonitor YAML
  --acknowledge-root-docker-socket
                           Required by up; acknowledges the transitional NPU
                           Docker socket boundary
  -h, --help               Show this help

The online registry is authoritative by default. The script never builds
Control, CPU Runner or NPU Burn images and never starts a stress workload.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --action) require_value "$@"; ACTION=$2; shift 2 ;;
        --offline-bundle) require_value "$@"; OFFLINE_BUNDLE=$2; shift 2 ;;
        --replace-config) REPLACE_CONFIG=true; shift ;;
        --acknowledge-root-docker-socket) ACK_ROOT_DOCKER_SOCKET=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

case "$ACTION" in plan|up|status|doctor|down) ;; *) die "unsupported action: $ACTION" ;; esac
if [ -n "$OFFLINE_BUNDLE" ]; then
    case "$OFFLINE_BUNDLE" in /*) ;; *) die "--offline-bundle must be absolute" ;; esac
    OFFLINE_BUNDLE=$(readlink -m -- "$OFFLINE_BUNDLE")
fi

export DOCKER_HOST=unix:///var/run/docker.sock
command -v docker >/dev/null 2>&1 || die 'Docker CLI is unavailable'
docker info >/dev/null 2>&1 || die 'default Docker daemon is unavailable'
git -C "$REPO_ROOT" cat-file -e "$GOLDEN_SOURCE^{commit}" || die 'Golden source commit is unavailable'
git -C "$REPO_ROOT" merge-base --is-ancestor "$GOLDEN_SOURCE" HEAD || \
    die "current source does not contain Golden commit $GOLDEN_SOURCE"

print_plan() {
    cat <<EOF
CATMonitor A2 online release plan
  release: a2-r1
  Golden image source: $GOLDEN_SOURCE
  current release tooling: $(git -C "$REPO_ROOT" rev-parse HEAD)
  control: $CONTROL_IMAGE
    $CONTROL_ID
  CPU runner: $CPU_IMAGE
    $CPU_ID
  NPU Burn: $NPU_IMAGE
    $NPU_ID
  registry policy: online first
  offline fallback: ${OFFLINE_BUNDLE:-disabled}
  config: $CONFIG_PATH
  plugin: $PLUGIN_ROOT
  state: $STRESS_STATE
  workload execution: none
EOF
}

containers=(
    catmonitor
    catmonitor-web
    catmonitor-dfee
    catmonitor-cpu-runner
    catmonitor-npuburn
    catmonitor-stress-web
)

show_status() {
    local name
    printf '%-30s %-12s %s\n' NAME STATUS IMAGE
    for name in "${containers[@]}"; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            docker container inspect "$name" \
                --format '{{printf "%-30s %-12s %s" .Name .State.Status .Config.Image}}' |
                sed 's#^/##'
        else
            printf '%-30s %-12s %s\n' "$name" missing -
        fi
    done
}

run_doctor() {
    docker container inspect catmonitor >/dev/null 2>&1 ||
        die 'catmonitor container is unavailable'
    [ "$(docker container inspect catmonitor --format '{{.State.Running}}')" = true ] ||
        die 'catmonitor container is not running'
    docker exec catmonitor /usr/local/bin/catmonitor stress doctor \
        -c /etc/catmonitor/catmonitor.yaml -o table
}

case "$ACTION" in
    plan)
        print_plan
        exit 0
        ;;
    status)
        show_status
        exit 0
        ;;
    doctor)
        run_doctor
        exit 0
        ;;
    down)
        existing=()
        for name in "${containers[@]}"; do
            docker container inspect "$name" >/dev/null 2>&1 && existing+=("$name")
        done
        if [ "${#existing[@]}" -gt 0 ]; then
            docker stop "${existing[@]}" >/dev/null
        fi
        show_status
        exit 0
        ;;
esac

[ "$(id -u)" -eq 0 ] || die 'up must run as root'
[ "$ACK_ROOT_DOCKER_SOCKET" = true ] || \
    die 'up requires --acknowledge-root-docker-socket'
command -v curl >/dev/null 2>&1 || die 'curl is unavailable'

existing_count=0
for name in "${containers[@]}"; do
    docker container inspect "$name" >/dev/null 2>&1 && existing_count=$((existing_count + 1))
done
case "$existing_count" in
    0) INSTALL_MODE=fresh ;;
    6) INSTALL_MODE=existing ;;
    *) die "partial/conflicting CATMonitor deployment found ($existing_count/6 containers); review it manually" ;;
esac

verify_id() {
    local image=$1 expected=$2 actual platform
    actual=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)
    [ "$actual" = "$expected" ] || \
        die "$image has unexpected image ID: ${actual:-unavailable}; expected $expected"
    platform=$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')
    [ "$platform" = linux/arm64 ] || \
        die "$image has unexpected platform: $platform; expected linux/arm64"
}

load_offline() {
    local archive_name=$1 image=$2 expected=$3 archive line
    [ -n "$OFFLINE_BUNDLE" ] || return 1
    archive="$OFFLINE_BUNDLE/images/$archive_name"
    [ -f "$archive" ] || die "offline image archive is unavailable: $archive"
    [ -f "$OFFLINE_BUNDLE/SHA256SUMS" ] || die 'offline SHA256SUMS is unavailable'
    line=$(grep -F "  images/$archive_name" "$OFFLINE_BUNDLE/SHA256SUMS" || true)
    [ -n "$line" ] || die "offline checksum is unavailable for $archive_name"
    (cd "$OFFLINE_BUNDLE" && printf '%s\n' "$line" | sha256sum -c -)
    docker load -i "$archive" >/dev/null
    docker image inspect "$expected" >/dev/null 2>&1 || \
        die "offline archive did not load expected image ID: $expected"
    docker tag "$expected" "$image"
}

ensure_release_image() {
    local image=$1 expected=$2 archive=$3 current
    current=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)
    if [ "$current" = "$expected" ]; then
        verify_id "$image" "$expected"
        return 0
    fi
    if ! docker pull "$image"; then
        printf 'Registry pull failed for %s; trying explicit offline fallback.\n' "$image" >&2
        load_offline "$archive" "$image" "$expected" || \
            die "cannot obtain release image: $image"
    fi
    verify_id "$image" "$expected"
}

ensure_release_image "$CONTROL_IMAGE" "$CONTROL_ID" catmonitor-control-a2-r1.tar
ensure_release_image "$CPU_IMAGE" "$CPU_ID" catmonitor-cpu-runner-a2-r1.tar
ensure_release_image "$NPU_IMAGE" "$NPU_ID" catmonitor-npuburn-a2-r1.tar

CPU_MANIFEST=$REPO_ROOT/configs/releases/a2-r1/manifests/cpu-runner-image-manifest.json
NPU_MANIFEST=$REPO_ROOT/configs/releases/a2-r1/manifests/npu-burn-image-manifest.json
for file in "$CPU_MANIFEST" "$NPU_MANIFEST"; do [ -f "$file" ] || die "release manifest is unavailable: $file"; done

install -d -m 0750 /etc/catmonitor "$GENERATED_ROOT"
install -d -m 0755 "$PLUGIN_ROOT"
install -d -m 0750 \
    "$STATE_ROOT/snapshot" "$STATE_ROOT/data" "$STRESS_STATE" \
    "$STATE_ROOT/straggler" "$NPU_OUTPUT_DIR" \
    "$STRESS_STATE/work/hpl" "$STRESS_STATE/work/hpcg"
install -d -m 0770 -o root -g 65532 "$SOCKET_ROOT"

bash "$REPO_ROOT/scripts/stress/generate_stress_deployment.sh" \
    --output-dir "$GENERATED_ROOT" \
    --plugin-root "$PLUGIN_ROOT" \
    --report-path "$STRESS_STATE/stress-latest.json" \
    --cpu-backend unix \
    --cpu-runner-image "$CPU_IMAGE" \
    --cpu-runner-manifest "$CPU_MANIFEST" \
    --stream-threads 0 \
    --hpl-processes 8 --hpl-threads 16 \
    --hpcg-processes 128 --hpcg-threads 1 \
    --hpcg-nx 32 --hpcg-ny 32 --hpcg-nz 32 --hpcg-runtime 60 \
    --npu-manifest "$NPU_MANIFEST" \
    --npu-runtime /usr/bin/docker \
    --npu-container catmonitor-npuburn \
    --npu-image "$NPU_IMAGE" \
    --npu-output-dir "$NPU_OUTPUT_DIR" \
    --npu-device 1 \
    --npu-chip-generation A2 \
    --npu-cann 8.3.RC2 \
    --npu-torch-npu 2.8.0 \
    --npu-soc Ascend910B4 \
    --npu-run-case matmul \
    --npu-internal-timeout 300 \
    --enable-web --force

bash "$REPO_ROOT/scripts/stress/install_stress_runtime.sh" \
    --adapter "$GENERATED_ROOT/benchmark_check.sh" \
    --cpu-runner-adapter "$GENERATED_ROOT/cpu-runner-benchmark_check.sh" \
    --deployment-manifest "$GENERATED_ROOT/stress-deployment-manifest.json" \
    --plugin-root "$PLUGIN_ROOT" \
    --state-root "$STRESS_STATE" \
    --force

if [ -e "$CONFIG_PATH" ] && ! grep -Fq '# Managed by CATMonitor release a2-r1' "$CONFIG_PATH"; then
    [ "$REPLACE_CONFIG" = true ] || \
        die "$CONFIG_PATH already exists and is not managed by a2-r1; use --replace-config after review"
    cp -a -- "$CONFIG_PATH" "$CONFIG_PATH.before-a2-r1.$(date -u +%Y%m%dT%H%M%SZ)"
fi

BASE_CONFIG=$REPO_ROOT/docker/catmonitor.yaml
STRESS_CONFIG=$GENERATED_ROOT/catmonitor-stress.yaml
CONFIG_TEMP=$(mktemp /etc/catmonitor/.catmonitor.yaml.XXXXXXXX)
cleanup() { rm -f -- "$CONFIG_TEMP"; }
trap cleanup EXIT HUP INT TERM
{
    printf '# Managed by CATMonitor release a2-r1\n'
    awk -v fragment="$STRESS_CONFIG" '
    function emit_fragment( line) {
        while ((getline line < fragment) > 0) print line
        close(fragment)
    }
    /^stress:[[:space:]]*$/ {
        if (!inserted) { emit_fragment(); inserted=1 }
        skipping=1
        next
    }
    skipping && /^[^[:space:]#][^:]*:[[:space:]]*/ { skipping=0 }
    !skipping { print }
    END { if (!inserted) emit_fragment() }
    ' "$BASE_CONFIG"
} >"$CONFIG_TEMP"
[ "$(grep -c '^stress:' "$CONFIG_TEMP")" -eq 1 ] || die 'merged config has an invalid stress block count'
install -m 0640 "$CONFIG_TEMP" "$CONFIG_PATH"

rm -f -- "$CONFIG_TEMP"
trap - EXIT HUP INT TERM

created_containers=()
rollback_on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "${#created_containers[@]}" -gt 0 ]; then
        printf 'Install failed; removing containers created by this attempt: %s\n' \
            "${created_containers[*]}" >&2
        docker rm -f "${created_containers[@]}" >/dev/null 2>&1 || true
    fi
}
trap rollback_on_exit EXIT
trap 'exit 130' HUP INT TERM

verify_container_image() {
    local name=$1 expected=$2 actual
    actual=$(docker container inspect "$name" --format '{{.Image}}' 2>/dev/null || true)
    [ "$actual" = "$expected" ] || \
        die "$name has unexpected image ID: ${actual:-unavailable}; expected $expected"
}

if [ "$INSTALL_MODE" = existing ]; then
    verify_container_image catmonitor "$CONTROL_ID"
    verify_container_image catmonitor-web "$CONTROL_ID"
    verify_container_image catmonitor-dfee "$CONTROL_ID"
    verify_container_image catmonitor-stress-web "$CONTROL_ID"
    verify_container_image catmonitor-cpu-runner "$CPU_ID"
    verify_container_image catmonitor-npuburn "$NPU_ID"
    [ "$(docker container inspect catmonitor-npuburn \
        --format '{{index .Config.Labels "io.catmonitor.npu-burn.fixed-container"}}')" = true ] || \
        die 'existing catmonitor-npuburn is not a fixed NPU Burn container'
else
    bash "$REPO_ROOT/scripts/stress/create_npu_burn_container.sh" \
        --image "$NPU_IMAGE" \
        --name catmonitor-npuburn \
        --output-dir "$NPU_OUTPUT_DIR" \
        --docker-bin /usr/bin/docker \
        --runtime runc \
        --restart-policy unless-stopped
    created_containers+=(catmonitor-npuburn)

    docker run -d \
        --name catmonitor-cpu-runner \
        --restart unless-stopped \
        --read-only \
        --network none \
        --cap-drop ALL \
        --cap-add CHOWN \
        --cap-add DAC_OVERRIDE \
        --cap-add FOWNER \
        --cap-add SETGID \
        --cap-add SETPCAP \
        --cap-add SETUID \
        --cap-add SYS_NICE \
        --security-opt no-new-privileges:true \
        --pids-limit 4096 \
        --shm-size 16g \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
        --health-cmd 'test -S /run/catmonitor-stress/cpu-runner.sock' \
        --health-interval 5s \
        --health-timeout 2s \
        --health-retries 12 \
        -v "$PLUGIN_ROOT/cpu-runner-benchmark_check.sh:/etc/catmonitor-stress/benchmark_check.sh:ro" \
        -v "$STRESS_STATE:/var/lib/catmonitor/stress" \
        -v "$SOCKET_ROOT:/run/catmonitor-stress" \
        "$CPU_IMAGE" >/dev/null
    created_containers+=(catmonitor-cpu-runner)

    ASCEND_LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:/usr/local/Ascend/nnae/latest/lib64
    for path in \
        /usr/local/Ascend/driver \
        /usr/local/Ascend/nnae \
        /usr/local/Ascend/ascend-toolkit \
        /usr/bin/hccn_tool \
        /usr/local/sbin/npu-smi; do
        [ -e "$path" ] || die "required A2 host asset is unavailable: $path"
    done

    docker run -d \
        --name catmonitor \
        --restart unless-stopped \
        --privileged \
        --network host \
        --pid host \
        --group-add 65532 \
        -v /:/host:ro \
        -v /etc/os-release:/etc/os-release:ro \
        -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
        -v /usr/local/Ascend/nnae:/usr/local/Ascend/nnae:ro \
        -v /usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro \
        -v /usr/bin/hccn_tool:/usr/bin/hccn_tool:ro \
        -v /usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi:ro \
        -v "$CONFIG_PATH:/etc/catmonitor/catmonitor.yaml:ro" \
        -v "$STATE_ROOT/snapshot:/var/lib/catmonitor/snapshot" \
        -v "$STATE_ROOT/data:/var/lib/catmonitor/data" \
        -v "$STATE_ROOT/straggler:/var/lib/catmonitor/straggler" \
        -v "$PLUGIN_ROOT:/opt/catmonitor/stress:ro" \
        -v "$STRESS_STATE:/var/lib/catmonitor/stress" \
        -v "$SOCKET_ROOT:/run/catmonitor-stress" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e "LD_LIBRARY_PATH=$ASCEND_LD_LIBRARY_PATH" \
        --entrypoint /usr/local/bin/catmonitor \
        "$CONTROL_IMAGE" daemon --config /etc/catmonitor/catmonitor.yaml >/dev/null
    created_containers+=(catmonitor)

    docker run -d \
        --name catmonitor-web \
        --restart unless-stopped \
        --network host \
        --group-add 65532 \
        -v "$CONFIG_PATH:/etc/catmonitor/catmonitor.yaml:ro" \
        -v "$STATE_ROOT/snapshot:/var/lib/catmonitor/snapshot:ro" \
        -v "$PLUGIN_ROOT:/opt/catmonitor/stress:ro" \
        -v "$STRESS_STATE:/var/lib/catmonitor/stress" \
        -v "$SOCKET_ROOT:/run/catmonitor-stress" \
        --entrypoint /usr/local/bin/web \
        "$CONTROL_IMAGE" \
        -addr=:19322 \
        -snapshot-dir=/var/lib/catmonitor/snapshot \
        -config=/etc/catmonitor/catmonitor.yaml >/dev/null
    created_containers+=(catmonitor-web)

    docker run -d \
        --name catmonitor-dfee \
        --restart unless-stopped \
        --network host \
        -v "$STATE_ROOT/snapshot:/var/lib/catmonitor/snapshot:ro" \
        --entrypoint /usr/local/bin/dfee \
        "$CONTROL_IMAGE" \
        -addr=:19323 \
        -snapshot-dir=/var/lib/catmonitor/snapshot \
        -exporter=enabled \
        -exporter-port=9333 \
        -csv=disabled \
        -csv-dir=/var/lib/catmonitor/csv \
        -csv-interval=10s >/dev/null
    created_containers+=(catmonitor-dfee)

    docker run -d \
        --name catmonitor-stress-web \
        --restart unless-stopped \
        --network host \
        --group-add 65532 \
        -v "$CONFIG_PATH:/etc/catmonitor/catmonitor.yaml:ro" \
        -v "$STATE_ROOT/snapshot:/var/lib/catmonitor/snapshot:ro" \
        -v "$PLUGIN_ROOT:/opt/catmonitor/stress:ro" \
        -v "$STRESS_STATE:/var/lib/catmonitor/stress" \
        -v "$SOCKET_ROOT:/run/catmonitor-stress" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$NPU_OUTPUT_DIR:$NPU_OUTPUT_DIR" \
        --entrypoint /usr/local/bin/web \
        "$CONTROL_IMAGE" \
        -addr=127.0.0.1:29592 \
        -snapshot-dir=/var/lib/catmonitor/snapshot \
        -config=/etc/catmonitor/catmonitor.yaml >/dev/null
    created_containers+=(catmonitor-stress-web)
fi

start_order=(
    catmonitor-cpu-runner
    catmonitor-npuburn
    catmonitor
    catmonitor-web
    catmonitor-dfee
    catmonitor-stress-web
)
docker start "${start_order[@]}" >/dev/null

for _ in $(seq 1 60); do
    health=$(docker container inspect catmonitor-cpu-runner \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')
    [ "$health" = healthy ] && break
    [ "$health" != unhealthy ] || die 'CPU runner became unhealthy'
    sleep 1
done
[ "$(docker container inspect catmonitor-cpu-runner \
    --format '{{.State.Health.Status}}')" = healthy ] || \
    die 'CPU runner did not become healthy'

wait_for_url() {
    local url=$1 label=$2
    for _ in $(seq 1 60); do
        curl -fsS --max-time 2 "$url" >/dev/null 2>&1 && return 0
        sleep 1
    done
    die "$label did not become ready: $url"
}

wait_for_snapshot() {
    for _ in $(seq 1 60); do
        if find "$STATE_ROOT/snapshot" -maxdepth 1 -type f -size +0c -print -quit |
            grep -q .; then
            return 0
        fi
        sleep 1
    done
    die 'CATMonitor snapshot did not become ready'
}

wait_for_url http://127.0.0.1:19320/metrics 'daemon metrics'
wait_for_snapshot
wait_for_url http://127.0.0.1:19322/ 'Web'
wait_for_url http://127.0.0.1:19323/ 'DFeE'
wait_for_url http://127.0.0.1:9333/metrics 'DFeE exporter'
wait_for_url http://127.0.0.1:29592/stress/ 'operational Stress Web'
wait_for_url http://127.0.0.1:29592/api/stress/config 'Stress Web API'
run_doctor

trap - EXIT HUP INT TERM
printf 'CATMonitor A2 a2-r1 six-container deployment is ready.\n'
show_status