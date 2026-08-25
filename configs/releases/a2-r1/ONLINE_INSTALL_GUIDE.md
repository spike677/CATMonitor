# CATMonitor A2 a2-r1 手工部署指南

本指南是 a2-r1 的主部署路径。用户可清楚看到源码、镜像、配置、挂载、设备和每个容器的启动方式。在线与离线仅在获取镜像时不同；之后完全一致。scripts/catmonitor-install 仅为可选自动化入口。本流程不依赖 Docker Compose，也不构建镜像或 benchmark。

## 1. Host prerequisites

要求 Linux/ARM64、默认 Docker daemon、Ascend 910B4 驱动、Git/bash/awk/curl/sha256sum/nsenter，以及足够的 Docker data-root 空间。

~~~bash
set -euo pipefail
unset DOCKER_HOST
test -S /var/run/docker.sock
test -x /usr/bin/docker
test "$(uname -m)" = aarch64
docker version >/dev/null
docker info --format 'root={{.DockerRootDir}}'

for path in /dev/davinci2 /dev/davinci5 /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc /usr/local/Ascend/driver /usr/local/dcmi; do
  test -e "$path"
done
command -v npu-smi >/dev/null
~~~

device-node ID 为 2、5；NPU Burn logical ID 为 0、1。两套编号不能互换。

## 2. Clone source

~~~bash
install -d -m 0755 /opt/catmonitor
git -c http.version=HTTP/1.1 clone https://github.com/spike677/CATMonitor.git /opt/catmonitor/CATMonitor
cd /opt/catmonitor/CATMonitor
git fetch --all --tags --prune
git checkout a2-r1
~~~

`a2-r1` 是正式发行标签；`release/a2-r1` 分支仅保留发行准备历史，不作为用户安装入口。

## 3. Verify source revision

~~~bash
REPO_ROOT=/opt/catmonitor/CATMonitor
RELEASE_METADATA=$REPO_ROOT/configs/releases/a2-r1/release.json
GOLDEN_BASE=e8c6f0ae4b2d0d7ba3c6a9d705533ed3a887e213

cd "$REPO_ROOT"
test -z "$(git status --short)"
git merge-base --is-ancestor "$GOLDEN_BASE" HEAD
test -f "$RELEASE_METADATA"
git rev-parse HEAD
~~~

`release.json` 中的 `release_source_commit` 固定记录 Phase E 已验收的源码冻结提交；当前 tag 额外包含本次发行 metadata 收尾。

## 4. Pull three images

在线：

三张 a2-r1 GHCR Package 均为 Public，拉取时无需执行 `docker login`，也不需要 GitHub PAT。

~~~bash
CONTROL_REGISTRY=ghcr.io/spike677/catmonitor-npu:a2-r1
CPU_REGISTRY=ghcr.io/spike677/catmonitor-stress-cpu-runner:a2-r1
NPU_REGISTRY=ghcr.io/spike677/catmonitor-npuburn:a2-r1

docker pull "$CONTROL_REGISTRY"
docker pull "$CPU_REGISTRY"
docker pull "$NPU_REGISTRY"
docker tag "$CONTROL_REGISTRY" catmonitor/control:a2-r1
docker tag "$CPU_REGISTRY" catmonitor/cpu-runner:a2-r1
docker tag "$NPU_REGISTRY" catmonitor/npuburn:a2-r1
~~~

离线 fallback：

~~~bash
docker load -i /path/to/control.tar
docker load -i /path/to/cpu-runner.tar
docker load -i /path/to/npuburn.tar
docker tag <loaded-control-reference> catmonitor/control:a2-r1
docker tag <loaded-cpu-reference> catmonitor/cpu-runner:a2-r1
docker tag <loaded-npu-reference> catmonitor/npuburn:a2-r1
~~~

## 5. Verify image IDs/platform

~~~bash
CONTROL_IMAGE=catmonitor/control:a2-r1
CPU_IMAGE=catmonitor/cpu-runner:a2-r1
NPU_IMAGE=catmonitor/npuburn:a2-r1
CONTROL_ID=sha256:f238d75fe8902a7ea39ec6c1261a674cb6446815116355f94b4b945b21a60424
CPU_ID=sha256:61e5a5f273684be3cdf18031ad742cf38bbe3512136b64c6e5f705f4356bd2aa
NPU_ID=sha256:d23553954429c9c16e7f4bb1407b48c4b5bfa8c70b2d57b681245bc46e566160

verify_image() {
  test "$(docker image inspect --format '{{.Id}}' "$1")" = "$2"
  test "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$1")" = linux/arm64
}
verify_image "$CONTROL_IMAGE" "$CONTROL_ID"
verify_image "$CPU_IMAGE" "$CPU_ID"
verify_image "$NPU_IMAGE" "$NPU_ID"
~~~


### a2-r1 support scope and image combinations

a2-r1 的发行声明只覆盖 linux/arm64、Ascend910B4、A2、CANN 8.3.RC2、torch_npu 2.8.0、matmul，以及实机验证过的稀疏节点 /dev/davinci2、/dev/davinci5。它不声明 A3/A5 或任意 CANN 版本已经通过验收。

三种使用边界：

| 模式 | 必需镜像 | 能力边界 |
|---|---|---|
| Full A2 | Control + CPU Runner + NPU Burn | CLI/Web/report 编排和四项压测；本指南后续主路径 |
| CPU-only CATMonitor Stress | Control + CPU Runner | STREAM/HPL/HPCG 的 CLI/Web/report 编排；不需要下载约 18 GiB 的 NPU Burn 镜像 |
| Raw CPU benchmark image only | CPU Runner | 只提供 CPU benchmark runtime、MPI、OpenBLAS 与受限 runner；不包含 CATMonitor CLI/Web/report 编排 |

/usr/local/bin/catmonitor-stress-cpu-client 位于 Control image，仅是连接 CPU Runner Unix socket 的受限 client，不是 CPU benchmark runtime。真正的 STREAM/HPL/HPCG 可执行文件位于 catmonitor/cpu-runner:a2-r1。

CPU-only 节点必须设置 npu_burn.enabled: false，并省略 NPU fixed container、NPU image 和 NPU Docker socket。现有可选自动化入口为：

~~~bash
sudo catmonitor-install --profile cpu-stress --action plan
sudo catmonitor-install --profile cpu-stress
~~~

该 profile 已有独立测试；它不会为 CPU-only 节点拉取 NPU Burn 镜像。本指南下方第 10、21 节以及 NPU 专属 mount 只适用于 Full A2。

CPU preflight 当前会检查 benchmark 资产、正整数 rank/thread 配置和 MPI ABI，但不会在 workload 前读取 /sys/devices/system/cpu/online 或 nproc 来验证在线 CPU 容量。CPU hotplug/offline 容量检查属于 FOLLOWUP_CPU_HOTPLUG_PREFLIGHT，不在 a2-r1 中扩实现。

## 6. Prepare directories

生产变量：

~~~bash
INSTANCE=catmonitor
CONFIG_PATH=/etc/catmonitor/catmonitor.yaml
GENERATED_ROOT=/etc/catmonitor/stress-deployment
HOST_PLUGIN_ROOT=/opt/catmonitor/stress
HOST_SNAPSHOT_ROOT=/var/lib/catmonitor/snapshot
HOST_DATA_ROOT=/var/lib/catmonitor/data
HOST_STRAGGLER_ROOT=/var/lib/catmonitor/straggler
HOST_STRESS_STATE=/var/lib/catmonitor/stress
HOST_SOCKET_ROOT=/run/catmonitor-stress
HOST_NPU_OUTPUT=$HOST_STRESS_STATE/npu-burn-output
CONTROL_NETWORK=host
SIDE_NETWORK=host
RESTART_POLICY=unless-stopped
~~~

Phase D 的隔离验收变量：

~~~bash
ACCEPT_ROOT=/var/tmp/catmonitor-a2-r1-acceptance
INSTANCE=catmonitor-a2r1-accept
CONFIG_PATH=$ACCEPT_ROOT/etc/catmonitor.yaml
GENERATED_ROOT=$ACCEPT_ROOT/generated
HOST_PLUGIN_ROOT=$ACCEPT_ROOT/plugin
HOST_SNAPSHOT_ROOT=$ACCEPT_ROOT/state/snapshot
HOST_DATA_ROOT=$ACCEPT_ROOT/state/data
HOST_STRAGGLER_ROOT=$ACCEPT_ROOT/state/straggler
HOST_STRESS_STATE=$ACCEPT_ROOT/state/stress
HOST_SOCKET_ROOT=$ACCEPT_ROOT/run
HOST_NPU_OUTPUT=$ACCEPT_ROOT/npu-burn-output
CONTROL_NETWORK=none
SIDE_NETWORK=container:$INSTANCE
RESTART_POLICY=no
~~~

公共变量和目录：

~~~bash
CONTROL_NAME=$INSTANCE
WEB_NAME=$INSTANCE-web
DFEE_NAME=$INSTANCE-dfee
CPU_NAME=$INSTANCE-cpu-runner
NPU_NAME=$INSTANCE-npuburn
STRESS_WEB_NAME=$INSTANCE-stress-web

CONTAINER_CONFIG=/etc/catmonitor/catmonitor.yaml
CONTAINER_PLUGIN_ROOT=/opt/catmonitor/stress
CONTAINER_SNAPSHOT_ROOT=/var/lib/catmonitor/snapshot
CONTAINER_DATA_ROOT=/var/lib/catmonitor/data
CONTAINER_STRAGGLER_ROOT=/var/lib/catmonitor/straggler
CONTAINER_STRESS_STATE=/var/lib/catmonitor/stress
CONTAINER_SOCKET_ROOT=/run/catmonitor-stress

install -d -m 0750 "$(dirname "$CONFIG_PATH")" "$GENERATED_ROOT" "$HOST_PLUGIN_ROOT" "$HOST_SNAPSHOT_ROOT" "$HOST_DATA_ROOT" "$HOST_STRAGGLER_ROOT" "$HOST_STRESS_STATE" "$HOST_NPU_OUTPUT"
install -d -m 0770 -o root -g 65532 "$HOST_SOCKET_ROOT"
chown -R 65532:65532 "$HOST_STRESS_STATE"
~~~

## 7. Generate stress deployment

release.json 是稳定的镜像身份元数据；原始 build evidence 不进入 Git。generator 只记录输入路径与 SHA-256。

~~~bash
bash "$REPO_ROOT/scripts/stress/generate_stress_deployment.sh" \
  --output-dir "$GENERATED_ROOT" \
  --cpu-backend unix \
  --cpu-runner-image "$CPU_IMAGE" \
  --cpu-runner-manifest "$RELEASE_METADATA" \
  --plugin-root "$CONTAINER_PLUGIN_ROOT" \
  --stream-threads 0 \
  --hpl-processes 8 --hpl-threads 16 \
  --hpcg-processes 128 --hpcg-threads 1 \
  --hpcg-nx 32 --hpcg-ny 32 --hpcg-nz 32 --hpcg-runtime 60 \
  --npu-manifest "$RELEASE_METADATA" \
  --npu-runtime /usr/bin/docker \
  --npu-container "$NPU_NAME" \
  --npu-image "$NPU_IMAGE" \
  --npu-output-dir "$HOST_NPU_OUTPUT" \
  --npu-device 1 \
  --npu-chip-generation A2 \
  --npu-cann 8.3.RC2 \
  --npu-torch-npu 2.8.0 \
  --npu-soc Ascend910B4 \
  --npu-run-case matmul \
  --npu-internal-timeout 300 \
  --report-path "$CONTAINER_STRESS_STATE/stress-latest.json" \
  --enable-web --force

bash -n "$GENERATED_ROOT/benchmark_check.sh"
bash -n "$GENERATED_ROOT/cpu-runner-benchmark_check.sh"
~~~

## 8. Install stress runtime

CPU benchmark、MPI、OpenBLAS 和 numactl 均来自 CPU Runner 镜像。

~~~bash
bash "$REPO_ROOT/scripts/stress/install_stress_runtime.sh" \
  --plugin-root "$HOST_PLUGIN_ROOT" \
  --state-root "$HOST_STRESS_STATE" \
  --adapter "$GENERATED_ROOT/benchmark_check.sh" \
  --cpu-runner-adapter "$GENERATED_ROOT/cpu-runner-benchmark_check.sh" \
  --deployment-manifest "$GENERATED_ROOT/stress-deployment-manifest.json" \
  --force

chown -R 65532:65532 "$HOST_STRESS_STATE"
CONFIG_TMP=$(mktemp "$(dirname "$CONFIG_PATH")/.catmonitor.yaml.XXXXXXXX")
awk '
  /^stress:/ { skip=1; next }
  skip && /^[A-Za-z_][A-Za-z0-9_]*:/ { skip=0 }
  !skip { print }
' "$REPO_ROOT/docker/catmonitor.yaml" >"$CONFIG_TMP"
printf '\n' >>"$CONFIG_TMP"
cat "$GENERATED_ROOT/catmonitor-stress.yaml" >>"$CONFIG_TMP"
install -m 0640 "$CONFIG_TMP" "$CONFIG_PATH"
rm -f "$CONFIG_TMP"
~~~

## 9. Start CPU Runner

它没有网络和 Docker socket，只有固定 adapter、state 与 Unix socket。

~~~bash
docker run -d \
  --name "$CPU_NAME" --restart "$RESTART_POLICY" --network none \
  --read-only --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add SETGID --cap-add SETPCAP --cap-add SETUID --cap-add SYS_NICE \
  --security-opt no-new-privileges:true \
  --pids-limit 4096 --shm-size 16g \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --volume "$HOST_PLUGIN_ROOT/cpu-runner-benchmark_check.sh:/etc/catmonitor-stress/benchmark_check.sh:ro" \
  --volume "$HOST_STRESS_STATE:$CONTAINER_STRESS_STATE:rw" \
  --volume "$HOST_SOCKET_ROOT:$CONTAINER_SOCKET_ROOT:rw" \
  --entrypoint /usr/local/bin/catmonitor-stress-cpu-entrypoint \
  "$CPU_IMAGE" \
  /usr/local/bin/catmonitor-stress-cpu-runner \
  -socket "$CONTAINER_SOCKET_ROOT/cpu-runner.sock" \
  -adapter /etc/catmonitor-stress/benchmark_check.sh

for attempt in $(seq 1 30); do test -S "$HOST_SOCKET_ROOT/cpu-runner.sock" && break; sleep 1; done
test -S "$HOST_SOCKET_ROOT/cpu-runner.sock"
~~~

## 10. Create/start NPU Burn fixed container

~~~bash
bash "$REPO_ROOT/scripts/stress/create_npu_burn_container.sh" \
  --image "$NPU_IMAGE" --name "$NPU_NAME" \
  --output-dir "$HOST_NPU_OUTPUT" \
  --docker-bin /usr/bin/docker --runtime runc \
  --restart-policy "$RESTART_POLICY"
~~~

脚本集中维护 identity-mapped davinci2/5、三个控制设备、driver/DCMI/npu-smi 只读挂载、CATMONITOR_NPU_DEVICE_COUNT=2、容器内 lspci topology 和默认结果目录；不挂载宿主机 CANN/torch_npu。

## 11. Start catmonitor daemon

~~~bash
docker run -d \
  --name "$CONTROL_NAME" --restart "$RESTART_POLICY" \
  --network "$CONTROL_NETWORK" --pid host --privileged \
  --security-opt label=disable --group-add 65532 \
  --env LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:/usr/local/Ascend/nnae/latest/lib64 \
  --volume /:/host:ro,rslave \
  --volume /etc/os-release:/etc/os-release:ro \
  --volume /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  --volume /usr/local/Ascend/nnae:/usr/local/Ascend/nnae:ro \
  --volume /usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro \
  --volume /usr/bin/hccn_tool:/usr/bin/hccn_tool:ro \
  --volume /usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi:ro \
  --volume "$CONFIG_PATH:$CONTAINER_CONFIG:ro" \
  --volume "$HOST_SNAPSHOT_ROOT:$CONTAINER_SNAPSHOT_ROOT:rw" \
  --volume "$HOST_DATA_ROOT:$CONTAINER_DATA_ROOT:rw" \
  --volume "$HOST_STRAGGLER_ROOT:$CONTAINER_STRAGGLER_ROOT:rw" \
  --volume "$HOST_PLUGIN_ROOT:$CONTAINER_PLUGIN_ROOT:ro" \
  --volume "$HOST_STRESS_STATE:$CONTAINER_STRESS_STATE:rw" \
  --volume "$HOST_SOCKET_ROOT:$CONTAINER_SOCKET_ROOT:rw" \
  --volume "$HOST_NPU_OUTPUT:$HOST_NPU_OUTPUT:rw" \
  --volume /var/run/docker.sock:/var/run/docker.sock:rw \
  --entrypoint /usr/local/bin/catmonitor \
  "$CONTROL_IMAGE" daemon --config "$CONTAINER_CONFIG"
~~~

Docker socket 是 root-equivalent 权限，只用于受信任 Control 调用固定 NPU Burn。

## 12. Start normal Web

19322 保留 develop 的对外监听；因此 Stress 页面只读，不能 Run/Cancel。

~~~bash
docker run -d \
  --name "$WEB_NAME" --restart "$RESTART_POLICY" --network "$SIDE_NETWORK" \
  --group-add 65532 \
  --volume "$CONFIG_PATH:$CONTAINER_CONFIG:ro" \
  --volume "$HOST_SNAPSHOT_ROOT:$CONTAINER_SNAPSHOT_ROOT:ro" \
  --volume "$HOST_PLUGIN_ROOT:$CONTAINER_PLUGIN_ROOT:ro" \
  --volume "$HOST_STRESS_STATE:$CONTAINER_STRESS_STATE:rw" \
  --volume "$HOST_SOCKET_ROOT:$CONTAINER_SOCKET_ROOT:rw" \
  --entrypoint /usr/local/bin/web \
  "$CONTROL_IMAGE" -addr=:19322 \
  -snapshot-dir="$CONTAINER_SNAPSHOT_ROOT" -config="$CONTAINER_CONFIG"
~~~

## 13. Start DFeE

~~~bash
docker run -d \
  --name "$DFEE_NAME" --restart "$RESTART_POLICY" --network "$SIDE_NETWORK" \
  --volume "$HOST_SNAPSHOT_ROOT:$CONTAINER_SNAPSHOT_ROOT:ro" \
  --entrypoint /usr/local/bin/dfee \
  "$CONTROL_IMAGE" \
  -addr=:19323 -snapshot-dir="$CONTAINER_SNAPSHOT_ROOT" \
  -exporter=enabled -exporter-port=9333 \
  -csv=disabled -csv-dir=/var/lib/catmonitor/csv -csv-interval=10s
~~~

## 14. Start operational Stress Web

29592 仅回环监听，具备 Run/Cancel；Docker socket、CPU socket 和 state 均为必要能力。

~~~bash
docker run -d \
  --name "$STRESS_WEB_NAME" --restart "$RESTART_POLICY" --network "$SIDE_NETWORK" \
  --group-add 65532 \
  --volume "$CONFIG_PATH:$CONTAINER_CONFIG:ro" \
  --volume "$HOST_SNAPSHOT_ROOT:$CONTAINER_SNAPSHOT_ROOT:ro" \
  --volume "$HOST_PLUGIN_ROOT:$CONTAINER_PLUGIN_ROOT:ro" \
  --volume "$HOST_STRESS_STATE:$CONTAINER_STRESS_STATE:rw" \
  --volume "$HOST_SOCKET_ROOT:$CONTAINER_SOCKET_ROOT:rw" \
  --volume "$HOST_NPU_OUTPUT:$HOST_NPU_OUTPUT:rw" \
  --volume /var/run/docker.sock:/var/run/docker.sock:rw \
  --entrypoint /usr/local/bin/web \
  "$CONTROL_IMAGE" -addr=127.0.0.1:29592 \
  -snapshot-dir="$CONTAINER_SNAPSHOT_ROOT" -config="$CONTAINER_CONFIG"
~~~

## 15. Verify six containers

~~~bash
for name in "$CONTROL_NAME" "$WEB_NAME" "$DFEE_NAME" "$CPU_NAME" "$NPU_NAME" "$STRESS_WEB_NAME"; do
  test "$(docker inspect --format '{{.State.Running}}' "$name")" = true
done
test "$(docker inspect --format '{{.Image}}' "$CONTROL_NAME")" = "$CONTROL_ID"
test "$(docker inspect --format '{{.Image}}' "$CPU_NAME")" = "$CPU_ID"
test "$(docker inspect --format '{{.Image}}' "$NPU_NAME")" = "$NPU_ID"
docker ps --filter "name=$INSTANCE" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
~~~

## 16. Verify metrics/snapshot/Web

隔离验收时 Web/DFeE 与 daemon 共享 network namespace，用 nsenter 探测，不占正式端口。

~~~bash
http_get() {
  if [ "$CONTROL_NETWORK" = host ]; then
    curl -fsS "$1"
  else
    control_pid=$(docker inspect --format '{{.State.Pid}}' "$CONTROL_NAME")
    nsenter -t "$control_pid" -n curl -fsS "$1"
  fi
}
for attempt in $(seq 1 60); do http_get http://127.0.0.1:19320/metrics >/dev/null 2>&1 && break; sleep 1; done
http_get http://127.0.0.1:19320/metrics >/dev/null
find "$HOST_SNAPSHOT_ROOT" -type f -size +0c -print -quit | grep -q .
http_get http://127.0.0.1:19322/ >/dev/null
http_get http://127.0.0.1:19323/ >/dev/null
http_get http://127.0.0.1:9333/metrics >/dev/null
http_get http://127.0.0.1:29592/stress/ >/dev/null
http_get http://127.0.0.1:29592/api/stress/config
~~~

Windows 隧道：

~~~powershell
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L 127.0.0.1:29592:127.0.0.1:29592 root@<节点IP>
~~~

## 17. stress doctor 4/4

~~~bash
docker exec "$CONTROL_NAME" /usr/local/bin/catmonitor stress doctor -c "$CONTAINER_CONFIG" -o table
~~~

stream、hpl、hpcg、npu_burn 必须全部 Available=true，doctor 总状态 PASS。

## 18. STREAM

~~~bash
docker exec "$CONTROL_NAME" /usr/local/bin/catmonitor stress --bench stream -c "$CONTAINER_CONFIG" -o table
~~~

## 19. HPCG

确认节点空闲后执行：

~~~bash
docker exec "$CONTROL_NAME" /usr/local/bin/catmonitor stress --bench hpcg -c "$CONTAINER_CONFIG" -o table
~~~

运行成功或到达配置时间限制且此前无错误均可通过。

## 20. HPL

确认节点空闲后执行：

~~~bash
docker exec "$CONTROL_NAME" /usr/local/bin/catmonitor stress --bench hpl -c "$CONTAINER_CONFIG" -o table
~~~

## 21. NPU Burn

先释放 logical ID 1 对应设备：

~~~bash
docker exec "$CONTROL_NAME" /usr/local/bin/catmonitor stress --bench npu_burn -c "$CONTAINER_CONFIG" -o table
~~~

只有完整 CSV 全部 PASS、err_count=0 且设备汇总无 FAIL 才通过；外层超时不算通过。

## 22. Web Run

~~~bash
web_post() {
  if [ "$CONTROL_NETWORK" = host ]; then
    curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-CATMonitor-Action: stress' --data "$2" "$1"
  else
    control_pid=$(docker inspect --format '{{.State.Pid}}' "$CONTROL_NAME")
    nsenter -t "$control_pid" -n curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-CATMonitor-Action: stress' --data "$2" "$1"
  fi
}
RUN_JSON=$(web_post http://127.0.0.1:29592/api/stress/runs '{"benchmarks":["stream"],"timeout_seconds":5}')
JOB_ID=$(printf '%s' "$RUN_JSON" | sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p')
test -n "$JOB_ID"
for attempt in $(seq 1 60); do
  JOB_JSON=$(http_get "http://127.0.0.1:29592/api/stress/runs/$JOB_ID")
  printf '%s' "$JOB_JSON" | grep -q '"status":"running"' || break
  sleep 1
done
printf '%s' "$JOB_JSON" | grep -Eq '"status":"(healthy|time_limit_reached)"'
printf '%s' "$JOB_JSON" | grep -q '"initiator":"web"'
~~~

## 23. Web Cancel

只取消 STREAM，不为 Cancel 测试启动 HPL/HPCG/NPU：

~~~bash
CANCEL_RUN=$(web_post http://127.0.0.1:29592/api/stress/runs '{"benchmarks":["stream"],"timeout_seconds":30}')
CANCEL_JOB=$(printf '%s' "$CANCEL_RUN" | sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p')
test -n "$CANCEL_JOB"
web_post "http://127.0.0.1:29592/api/stress/runs/$CANCEL_JOB/cancel" '{}' | grep -q '"ok":true'
~~~

若 STREAM 在 cancel 请求前已结束，可重新执行本段。

## 24. stop/start/remove

~~~bash
docker stop "$STRESS_WEB_NAME" "$WEB_NAME" "$DFEE_NAME" "$CONTROL_NAME" "$CPU_NAME" "$NPU_NAME"

docker start "$NPU_NAME"
docker start "$CPU_NAME"
docker start "$CONTROL_NAME"
docker start "$WEB_NAME"
docker start "$DFEE_NAME"
docker start "$STRESS_WEB_NAME"
~~~

显式删除容器但保留镜像、配置、报告和历史：

~~~bash
docker stop "$STRESS_WEB_NAME" "$WEB_NAME" "$DFEE_NAME" "$CONTROL_NAME" "$CPU_NAME" "$NPU_NAME" 2>/dev/null || true
docker rm "$STRESS_WEB_NAME" "$WEB_NAME" "$DFEE_NAME" "$CONTROL_NAME" "$CPU_NAME" "$NPU_NAME"
~~~

只有管理员确认后才删除 state/data 或镜像。排障、审计与 release acceptance 以本指南的展开命令为准。
