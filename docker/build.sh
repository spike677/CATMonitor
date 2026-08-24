#!/bin/sh
set -e

MODE=
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$PROJECT_ROOT/docker/.build"
DOCKER_BIN=${CATMONITOR_DOCKER_BIN:-docker}
DOCKER_BUILD_NETWORK=${CATMONITOR_DOCKER_BUILD_NETWORK:-default}
DEFAULT_DEBIAN_MIRROR=http://mirrors.aliyun.com/debian
DEBIAN_MIRROR=

usage() {
    cat <<'EOF'
Usage: docker/build.sh [auto|npu|generic] [OPTIONS]

Options:
  --debian-mirror URL  Debian repository root ending in /debian
                       (default: http://mirrors.aliyun.com/debian)
  -h, --help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        auto|npu|generic)
            if [ -n "$MODE" ]; then
                echo "ERROR: build mode was specified more than once." >&2
                exit 1
            fi
            MODE=$1
            shift
            ;;
        --debian-mirror)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "ERROR: --debian-mirror requires a URL." >&2
                exit 1
            fi
            DEBIAN_MIRROR=$2
            shift 2
            ;;
        --debian-mirror=*)
            DEBIAN_MIRROR=${1#*=}
            if [ -z "$DEBIAN_MIRROR" ]; then
                echo "ERROR: --debian-mirror requires a URL." >&2
                exit 1
            fi
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done
MODE=${MODE:-auto}

case "$DOCKER_BUILD_NETWORK" in
    default|host|none) ;;
    *)
        echo "ERROR: CATMONITOR_DOCKER_BUILD_NETWORK must be default, host, or none." >&2
        exit 1
        ;;
esac
# Forward only variables explicitly configured by the administrator. Values are
# inherited from the environment and are not printed or persisted in this file.
PROXY_BUILD_ARGS=
GO_BUILD_ARGS=
GO_RUN_ENV_ARGS=
DEBIAN_BUILD_ARGS=
for proxy_name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    eval "proxy_value=\${$proxy_name-}"
    if [ -n "$proxy_value" ]; then
        PROXY_BUILD_ARGS="$PROXY_BUILD_ARGS --build-arg $proxy_name"
        GO_RUN_ENV_ARGS="$GO_RUN_ENV_ARGS -e $proxy_name"
    fi
done
for go_name in GOPROXY GOSUMDB GOPRIVATE GONOSUMDB; do
    eval "go_value=\${$go_name-}"
    if [ -n "$go_value" ]; then
        GO_BUILD_ARGS="$GO_BUILD_ARGS --build-arg $go_name"
        GO_RUN_ENV_ARGS="$GO_RUN_ENV_ARGS -e $go_name"
    fi
done

if [ -n "$PROXY_BUILD_ARGS" ]; then
    echo "Docker build proxy: configured"
fi
if [ -n "$GO_BUILD_ARGS" ]; then
    echo "Go module environment: configured"
fi
# Auto-detect before resolving mode-specific build options.
if [ "$MODE" = "auto" ]; then
    if [ -d /usr/local/Ascend/driver ]; then
        MODE=npu
    else
        MODE=generic
    fi
    echo "Auto-detected: $MODE"
fi

if [ "$MODE" = npu ]; then
    DEBIAN_MIRROR=${DEBIAN_MIRROR:-$DEFAULT_DEBIAN_MIRROR}
elif [ -n "$DEBIAN_MIRROR" ]; then
    echo "ERROR: --debian-mirror currently applies only to the NPU Debian control image." >&2
    exit 1
fi


if [ -n "$DEBIAN_MIRROR" ]; then
    case "$DEBIAN_MIRROR" in
        http://?*|https://?*) ;;
        *)
            echo "ERROR: --debian-mirror must use http:// or https://." >&2
            exit 1
            ;;
    esac
    mirror_location=${DEBIAN_MIRROR#*://}
    mirror_location=${mirror_location%/}
    case "$mirror_location" in
        ''|*@*|*\?*|*\#*|*[[:space:]]*)
            echo "ERROR: --debian-mirror must not contain credentials, query, fragment, or whitespace." >&2
            exit 1
            ;;
    esac
    case "$DEBIAN_MIRROR" in
        */debian|*/debian/) ;;
        *)
            echo "ERROR: --debian-mirror must be a Debian repository root ending in /debian." >&2
            exit 1
            ;;
    esac
    DEBIAN_MIRROR=${DEBIAN_MIRROR%/}
    export DEBIAN_MIRROR
    DEBIAN_BUILD_ARGS="--build-arg DEBIAN_MIRROR"
    echo "Debian package mirror: configured"
fi

cleanup_build_dir() {
    case "$BUILD_DIR" in
        "$PROJECT_ROOT"/docker/.build) rm -rf -- "$BUILD_DIR" ;;
        *)
            echo "ERROR: refusing to clean unexpected build directory: $BUILD_DIR" >&2
            exit 1
            ;;
    esac
}

case "$MODE" in
    npu)
        echo "=== Building NPU image (two-step: compile + package) ==="

        DRIVER_PATH=/usr/local/Ascend/driver
        if [ ! -d "$DRIVER_PATH" ]; then
            echo "ERROR: $DRIVER_PATH not found on host."
            echo "       Install Ascend driver before building."
            exit 1
        fi

        cleanup_build_dir
        mkdir -p "$BUILD_DIR"
        trap cleanup_build_dir EXIT HUP INT TERM

        echo "Step 1/2: Compiling binaries in golang container with driver mounted..."
        # Argument lists contain constant option/variable names only. Their
        # values are inherited by Docker and never expanded into this command.
        # shellcheck disable=SC2086
        "$DOCKER_BIN" run --rm --network "$DOCKER_BUILD_NETWORK" $GO_RUN_ENV_ARGS \
            -v "$DRIVER_PATH:/usr/local/Ascend/driver:ro" \
            -v "$PROJECT_ROOT:/app:ro" \
            -v "$BUILD_DIR:/out" \
            -w /app \
            -e CGO_ENABLED=1 \
            -e CGO_CFLAGS="-I/usr/local/Ascend/driver/include -w" \
            -e CGO_LDFLAGS="-L/usr/local/Ascend/driver/lib64/driver -ldcmi -Wl,--allow-shlib-undefined" \
            golang:1.23 \
            sh -c 'go build -tags dcmi -o /out/catmonitor ./cmd/catmonitor && \
                   CGO_ENABLED=0 go build -o /out/dfee ./features/dfee && \
                   CGO_ENABLED=0 go build -o /out/web ./features/web && \
                   CGO_ENABLED=0 go build -o /out/cpu-runner-client ./features/stress/cmd/cpu-runner-client && \
                   echo "Compile done."'

        echo "Step 2/2: Building runtime image (debian/glibc)..."
        # shellcheck disable=SC2086
        "$DOCKER_BIN" build --network "$DOCKER_BUILD_NETWORK" $PROXY_BUILD_ARGS $DEBIAN_BUILD_ARGS \
            -f docker/Dockerfile.npu \
            -t catmonitor-npu \
            "$PROJECT_ROOT"

        echo "Done. Image: catmonitor-npu"
        ;;

    generic)
        echo "=== Building generic image (multi-stage, pure Go) ==="
        # shellcheck disable=SC2086
        "$DOCKER_BIN" build --network "$DOCKER_BUILD_NETWORK" $PROXY_BUILD_ARGS $GO_BUILD_ARGS \
            -f docker/Dockerfile.generic \
            -t catmonitor-generic \
            "$PROJECT_ROOT"
        echo "Done. Image: catmonitor-generic"
        ;;

    *)
        echo "Usage: $0 [auto|npu|generic]"
        echo "  auto    - detect NPU driver automatically (default)"
        echo "  npu     - build NPU image (two-step: host-driver compile + runtime package)"
        echo "  generic - build generic image (multi-stage, no NPU support)"
        exit 1
        ;;
esac
