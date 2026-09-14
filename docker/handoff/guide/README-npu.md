# CATMonitor：Ascend NPU 节点

> Claude 独立验收冻结副本：`manual-c1821ca-r2-handoff`（2026-09-14）。
> 来源：`docker/README-npu.md` 的 r1；本文件是独立验收冻结副本，不覆盖原文件。
> 公开副本只调整交接路径与参考链接；实际命令与 r2 一致。
> 先读 [交接说明](../README.md)，特别是测试目录覆盖、资源门禁和每个 SSH 会话环境。
> 本轮只做 Manual 的 Monitoring / CPU / NPU 三场景，不运行 Full、Compose、clone/pull 或 build。

适用于 Ascend NPU Linux 节点。支持 Ascend Monitoring、可选 CPU Stress 和可选
NPU Burn。当前 Stress 镜像只声明已完成 A2/Ascend910B4、CANN 8.3、`runc` 的功能验收；
其他 SoC/CANN 组合必须单独验收，不能由 A2 结果外推。

Docker Compose 是推荐入口；本页同时给出完整的 `docker run` 入口。两种入口使用
相同镜像、generator 配置、挂载、权限和 3/4/4/5 容器模型。

> 本轮手操源码基线为 `c1821ca4fa2eec53eb2605dc263561c6076421d0`（源码版本 `0.3.6`）。
> 继续使用已取得的 `arm64-v0.3.5-stress` pre-release 镜像；本次指南/启动参数修订
> 没有重建镜像，不能把手操源码提交当成这些镜像的构建提交。

## 1. 前置条件

### 手操顺序与记录约定

本页手工路径分三个独立场景：Monitoring-only（3 容器）→ CPU-only（4 容器）→
NPU-only（4 容器）。每次只执行当前步骤；页面和输出由操作者检查完毕，再清理并进入
下一场景。Full 保留为参考，本轮手操不执行。已有源码和镜像的用户跳过 clone/pull。

| 步骤 | 目的与完整命令所在章节 | 预期结果 | 失败处理 | 记录目录 |
|---|---|---|---|---|
| 01 | 第 1 节：核对服务器、daemon、名称、端口 | 目标正确，无冲突 | 停在本步，核对占用者 | `01-preflight` |
| 02 | 第 2 节：记录已有源码、镜像身份 | 三镜像 ARM64 | 核对发行身份，不替换镜像 | `02-images` |
| 03 | 第 3.2 节：启动 Monitoring | 3 容器运行 | `docker logs catmonitor` | `03-monitoring` |
| 04 | 第 3.3 节：ready、snapshot、页面与 CLI | 有效 JSON、页面有数据 | 最多等待 120 秒，超时查看日志 | `04-monitoring-check` |
| 05 | 第 9 节：确认页面后清理 Monitoring | 本场景容器/卷清零 | 保留数据并核对引用者 | `05-cleanup` |
| 06 | 第 4、5.1、5.3 节：生成 CPU 配置与启动 | 4 容器，无 NPU workload | 查看 generator/容器输出 | `06-cpu` |
| 07 | 第 5.4 节：doctor、STREAM、Web 结果 | CPU 3/3、STREAM 成功 | 保存 status 和日志 | `07-cpu-run` |
| 08 | 第 5.4 节：双终端 HPL Cancel | 新任务取消，MPI 退出 | 不继续清理，保留进程证据 | `08-cpu-cancel` |
| 09 | 第 9 节：确认后清理 CPU | 本场景容器/卷清零 | 核对引用者 | `09-cleanup` |
| 10 | 第 6.1–6.4 节：资源检查、生成、映射、启动 | 4 容器，init 为 PID 1 | 设备忙则停，不杀业务 | `10-npu` |
| 11 | 第 6.5 节：doctor、Burn、CSV、Cancel | 功能与进程回收分别核对 | 同一容器保留现场，不重启掩盖 | `11-npu-run` |
| 12 | 第 9 节：确认后归档、清理 NPU | 结果已保存，容器/卷清零 | 保留结果再诊断 | `12-cleanup` |

执行位置：目标 Linux 服务器的 Bash 终端 A；取消操作使用同一服务器终端 B；Web
检查使用操作者浏览器。首次操作只启动一次记录 shell，全程保持这个 shell，确保后续
变量仍然有效；每步以 `STEP` 标记分界，额外的 JSON/CSV 可存入表中的子目录：

```bash
export MANUAL_EVIDENCE="${MANUAL_EVIDENCE:-$PWD/manual-evidence-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$MANUAL_EVIDENCE"
# MANUAL_EVIDENCE 只初始化一次；终端 B 使用终端 A 打印的同一绝对路径。
script -q -a "$MANUAL_EVIDENCE/terminal-A.txt"
# 以下在记录 shell 内执行；后续每步修改 STEP，整个手操结束才 Ctrl-D。
STEP=01-preflight
mkdir -p "$MANUAL_EVIDENCE/$STEP"
printf '\nCURRENT_STEP=%s\n' "$STEP"
```

不要在交互式登录 shell 设置 `set -e` 或运行 `exit 1` 门禁；检查失败后停在本步，
保存输出。下面括号包围的检查在子 shell 中退出，不会断开 SSH。

- Linux/arm64；
- Docker Engine；
- 使用 Compose 路径时安装 Docker Compose v2；只使用手工路径时不要求 Compose；
- 使用 NPU 手工路径时安装 Bash 与 Python 3，用于读取 generator 的
  `stress-profile.json`，不解析 Compose YAML；
- Ascend 驱动可用，至少存在一个 `/dev/davinciN`；
- `npu-smi info` 正常；
- NPU workload 镜像中的 CANN/torch_npu 与节点驱动兼容。

```bash
uname -m
npu-smi info
ls -1 /dev/davinci[0-9]*
docker version
docker compose version 2>/dev/null || true
python3 --version
```

```bash
printf 'DOCKER_HOST=%s\n' "${DOCKER_HOST:-unix:///var/run/docker.sock}"
docker info --format 'root={{.DockerRootDir}} init={{.InitBinary}}'
df -h / /home
docker ps -a --format '{{.ID}} {{.Names}} {{.Image}} {{.Status}}'
(
  for name in catmonitor catmonitor-web catmonitor-dfee catmonitor-stress-cpu catmonitor-stress-npu; do
    if docker container inspect "$name" >/dev/null 2>&1; then
      echo "STOP: container name is already in use: $name" >&2
      exit 1
    fi
  done
  if ss -lnt | awk '{print $4}' | grep -Eq ':(19320|19322|19323|9333)$'; then
    echo 'STOP: monitoring ports are occupied; identify owner before proceeding' >&2
    exit 1
  fi
  echo 'NAME_AND_PORT_CHECK=PASS'
)
```

NPU 的 `--init` 要求 Docker daemon 主机安装可执行的 docker-init。`docker run --help`
出现此参数不代表依赖已经安装；使用第 6.1 节的无负载探针验证。独立测试 daemon 的
socket、网络命名空间和转发仅属于本机演示环境附录，不是普通产品部署前提。

generator 会动态发现实际存在的 `/dev/davinciN`。设备号不要求从 0 连续，不能用
最大设备号推导设备数量。

## 2. 镜像与源码

```bash
git clone https://github.com/Computing-Availability-Tools/CATMonitor.git
cd CATMonitor
git checkout --detach c1821ca4fa2eec53eb2605dc263561c6076421d0

export CATMONITOR_RELEASE='arm64-v0.3.5-stress'
export CATMONITOR_REGISTRY='ghcr.io/spike677'
export CATMONITOR_IMAGE="${CATMONITOR_REGISTRY}/catmonitor-npu:${CATMONITOR_RELEASE}"
export CATMONITOR_CPU_STRESS_IMAGE="${CATMONITOR_REGISTRY}/catmonitor-stress-cpu:${CATMONITOR_RELEASE}"
export CATMONITOR_NPU_STRESS_IMAGE="${CATMONITOR_REGISTRY}/catmonitor-stress-npu:${CATMONITOR_RELEASE}"
```

已有源码和镜像时只执行身份核对；记录 Image ID、digest 与镜像内标签，不把指南的
更新日期或源码 HEAD 当成旧镜像的构建来源：

```bash
git rev-parse HEAD
git status --short
docker image inspect "$CATMONITOR_IMAGE" "$CATMONITOR_CPU_STRESS_IMAGE" \
  "$CATMONITOR_NPU_STRESS_IMAGE" \
  --format 'tags={{json .RepoTags}} id={{.Id}} platform={{.Os}}/{{.Architecture}} digest={{json .RepoDigests}} labels={{json .Config.Labels}}'
```

按实际能力拉取，未启用 NPU Burn 时无需下载较大的 NPU workload 镜像：

```bash
docker pull "$CATMONITOR_IMAGE"
# CPU Stress 可选
docker pull "$CATMONITOR_CPU_STRESS_IMAGE"
# NPU Stress 可选
docker pull "$CATMONITOR_NPU_STRESS_IMAGE"
```

需要从源码构建 Ascend Control、CPU/NPU workload，选择 CANN builder/runtime base，
配置 Debian mirror，或制作 RC 镜像时，请使用
[镜像构建与发布开发者指南](../../DEVELOPER_GUIDE.md)。发布镜像必须来自同一 Stress
release source，不得复用 a2-r1 的镜像身份。

## 3. Monitoring-only

不启用 Stress 时只运行 `catmonitor`、`catmonitor-web`、`catmonitor-dfee`。不挂
Docker Socket，不启动 workload 容器，也不要求真实 `control.sock`。

### 3.1 Compose

```bash
export CATMONITOR_CONFIG="$PWD/docker/catmonitor.yaml"

CATMONITOR_IMAGE="$CATMONITOR_IMAGE" \
CATMONITOR_CONFIG="$CATMONITOR_CONFIG" \
  docker compose -p catmonitor \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.config.yml \
  -f docker/docker-compose.npu.yml \
  up -d
```

### 3.2 Manual `docker run`

这是完整兼容入口。保留 Web 的历史 `-config` flag，但不挂 Stress 配置或
control volume。

```bash
docker volume create cm-snapshot
docker volume create cm-data
docker volume create cm-straggler
docker volume create cm-csv

docker run -d --name catmonitor --restart unless-stopped \
  --privileged --network host --pid host \
  -v /:/host:ro \
  -v /etc/os-release:/etc/os-release:ro \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/Ascend/nnae:/usr/local/Ascend/nnae:ro \
  -v /usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro \
  -v /usr/bin/hccn_tool:/usr/bin/hccn_tool:ro \
  -v /usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi:ro \
  -e LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:/usr/local/Ascend/nnae/latest/lib64 \
  -v cm-snapshot:/var/lib/catmonitor/snapshot \
  -v cm-data:/var/lib/catmonitor/data \
  -v cm-straggler:/var/lib/catmonitor/straggler \
  "$CATMONITOR_IMAGE"
```

**此处先停：daemon 创建返回后，立即执行 [第 3.3 节](#33-verify) 的时间采样块，
在采样结束后才继续下面的 Web/DFeE。** 不要数分钟后检查一次就称为首次生成耗时。

```bash
docker run -d --name catmonitor-web --restart unless-stopped --network host \
  --entrypoint /usr/local/bin/web \
  -v cm-snapshot:/var/lib/catmonitor/snapshot:ro \
  "$CATMONITOR_IMAGE" \
  -addr=:19322 \
  -snapshot-dir=/var/lib/catmonitor/snapshot \
  -config=/etc/catmonitor/catmonitor.yaml

docker run -d --name catmonitor-dfee --restart unless-stopped --network host \
  --entrypoint /usr/local/bin/dfee \
  -v cm-snapshot:/var/lib/catmonitor/snapshot:ro \
  -v cm-csv:/var/lib/catmonitor/csv \
  "$CATMONITOR_IMAGE" \
  -addr=:19323 \
  -snapshot-dir=/var/lib/catmonitor/snapshot \
  -exporter=enabled \
  -exporter-port=9333 \
  -csv=disabled \
  -csv-dir=/var/lib/catmonitor/csv \
  -csv-interval=10s
```

```bash
test "$(docker ps --filter name='^/catmonitor$' --filter status=running -q | wc -l)" -eq 1
test "$(docker ps --filter name='^/catmonitor-web$' --filter status=running -q | wc -l)" -eq 1
test "$(docker ps --filter name='^/catmonitor-dfee$' --filter status=running -q | wc -l)" -eq 1
curl -fsS http://127.0.0.1:19322/ >/dev/null
curl -fsS http://127.0.0.1:19323/ >/dev/null
curl -fsS http://127.0.0.1:9333/metrics >/dev/null
```

### 3.3 Verify

Web 中 Stress 显示未启用；旧 Monitoring YAML 可以完全没有顶层 `stress:` 段。

目的：区分“服务可响应”和“第一份有效 snapshot”。在服务器终端 A 执行；默认最多
等待 120 秒，这是手操检查上限，不是启动时间保证。CPU/NPU 场景重建 daemon 后也执行
本段。需宿主机的 Python 3 与 `timeout`，不要求 Control 镜像内安装 Python。

<!-- manual-snapshot-wait:start -->
```bash
(
  daemon_started=$(docker inspect catmonitor --format '{{.State.StartedAt}}') || exit 1
  sampling_started=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
  limit=${SNAPSHOT_WAIT_SECONDS:-120}
  interval=${SNAPSHOT_POLL_SECONDS:-2}
  deadline=$((SECONDS + limit))
  first_ready=''
  first_snapshot=''
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl --connect-timeout 2 --max-time 3 -fsS \
        http://127.0.0.1:19320/-/ready >/dev/null; then
      if [ -z "$first_ready" ]; then
        first_ready=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
      fi
    fi
    if [ -n "$first_ready" ]; then
      if data=$(timeout 5 docker exec catmonitor sh -c \
          'test -s /var/lib/catmonitor/snapshot/snapshot_npu.json && cat /var/lib/catmonitor/snapshot/snapshot_npu.json') &&
          printf '%s' "$data" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        first_snapshot=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
        break
      fi
    fi
    sleep "$interval"
  done
  printf 'DAEMON_STARTED_AT=%s\nSAMPLING_STARTED_AT=%s\nFIRST_READY_OBSERVED_AT=%s\nFIRST_VALID_SNAPSHOT_OBSERVED_AT=%s\n' \
    "$daemon_started" "$sampling_started" "$first_ready" "$first_snapshot"
  if [ -z "$first_snapshot" ]; then
    echo 'SNAPSHOT_WAIT=FAIL: no valid snapshot observed within deadline' >&2
    timeout 5 docker logs --tail 80 catmonitor
    exit 1
  fi
  python3 - "$daemon_started" "$sampling_started" "$first_ready" "$first_snapshot" <<'PY'
from datetime import datetime
import sys
def parse(s):
    # Docker/date can have nanoseconds; Python datetime uses microseconds.
    s = s.rstrip("Z")
    if "." in s:
        left, right = s.split(".", 1)
        s = left + "." + (right + "000000")[:6]
    else:
        s += ".000000"
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f")
d, p, r, s = map(parse, sys.argv[1:])
print("DAEMON_TO_SNAPSHOT_OBSERVED_SECONDS=%.3f" % (s-d).total_seconds())
print("READY_TO_SNAPSHOT_OBSERVED_SECONDS=%.3f" % (s-r).total_seconds())
print("POLL_TO_SUCCESS_SECONDS=%.3f" % (s-p).total_seconds())
print("SAMPLING_START_DELAY_SECONDS=%.3f" % (p-d).total_seconds())
PY
  echo 'SNAPSHOT_WAIT=PASS'
)
```
<!-- manual-snapshot-wait:end -->

以上时间是首次**观察到**的时间，受轮询间隔及命令耗时影响，不是内部精确生成时刻。
采样若开始过晚，必须保留 SAMPLING_START_DELAY_SECONDS 并披露测量限制。

超时停在步骤 04，不继续运行压测。正常后执行并检查输出：

```bash
docker exec catmonitor catmonitor collect -o table
docker exec catmonitor catmonitor health -o table
curl -fsS http://127.0.0.1:19320/metrics
curl -fsS http://127.0.0.1:19322/api/stress/config
```

操作者打开 `http://<node-address>:19322/`、`http://<node-address>:19323/` 和
`http://<node-address>:19322/stress/`。预期健康页面有数据，Stress 的 `enabled=false`、
`available=false`。确认看完后才进入清理。

### 3.4 只启动部分 Monitoring 服务

```bash
# daemon + DFeE（跳过 Web）
CATMONITOR_IMAGE="$CATMONITOR_IMAGE" \
CATMONITOR_CONFIG="$CATMONITOR_CONFIG" \
  docker compose -p catmonitor \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.config.yml \
  -f docker/docker-compose.npu.yml \
  up -d catmonitor dfee

# 只启动 daemon
CATMONITOR_IMAGE="$CATMONITOR_IMAGE" \
CATMONITOR_CONFIG="$CATMONITOR_CONFIG" \
  docker compose -p catmonitor \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.config.yml \
  -f docker/docker-compose.npu.yml \
  up -d catmonitor
```

### 3.5 自定义 Monitoring 配置

Monitoring 公共配置路径保持不变：

| 文件 | 容器内路径 | 所有者 |
|---|---|---|
| 主配置 | `/etc/catmonitor/catmonitor.yaml` | daemon |
| 指标目录 | `/etc/catmonitor/metrics.yaml` | daemon |

Compose 通过 `CATMONITOR_CONFIG` 挂载主配置。手工启动时如需替换两份配置，把下面
两个只读 bind mount 加到 `catmonitor` 容器；Web/DFeE 只消费 snapshot，不重复读取
daemon 配置。

```bash
-v /path/to/my-catmonitor.yaml:/etc/catmonitor/catmonitor.yaml:ro \
-v /path/to/my-metrics.yaml:/etc/catmonitor/metrics.yaml:ro
```

旧 Monitoring YAML 不含 `stress:` 时仍可启动，且不会创建 Stress Manager、
`control.sock` 或 Docker executor。旧 Stress V1 YAML 不兼容 V2。

### 3.6 独立运行 DFeE

daemon 已在宿主机写入 `/var/lib/catmonitor/snapshot` 时：

```bash
sudo install -d -m 0750 /var/lib/catmonitor/csv

docker run -d --name catmonitor-dfee --network host \
  --entrypoint /usr/local/bin/dfee \
  -v /var/lib/catmonitor/snapshot:/var/lib/catmonitor/snapshot:ro \
  -v /var/lib/catmonitor/csv:/var/lib/catmonitor/csv \
  "$CATMONITOR_IMAGE" \
  -addr=:19323 \
  -snapshot-dir=/var/lib/catmonitor/snapshot \
  -exporter=enabled -exporter-port=9333 \
  -csv=disabled -csv-dir=/var/lib/catmonitor/csv
```

daemon 位于另一个容器时改为共享 `cm-snapshot` named volume。DFeE 不需要 Ascend
设备、driver/toolkit 或 Docker Socket，它消费 daemon 已生成的 snapshot。

### 3.7 Monitoring 端口与数据

| 端口 | 组件 | 用途 |
|---:|---|---|
| `19320` | daemon | `/metrics`、`/-/healthy`、`/-/ready` |
| `19321` | faultsub | 启用后提供故障订阅 REST API |
| `19322` | Web | Monitoring；启用 V2 Stress 后同时提供 Run/Cancel/History |
| `19323` | DFeE | 能效页面与 API |
| `9333` | DFeE exporter | Prometheus metrics |

| 卷/宿主目录 | 容器内路径 | 用途 |
|---|---|---|
| `cm-snapshot` | `/var/lib/catmonitor/snapshot` | daemon 写，Web/DFeE 只读 |
| `cm-data` | `/var/lib/catmonitor/data` | daemon 原始 JSONL；按 retention 管理 |
| `cm-straggler`（可选） | `/var/lib/catmonitor/straggler` | straggler 专用输出 |
| `cm-csv` | `/var/lib/catmonitor/csv` | DFeE CSV |

要启用 faultsub，在 daemon 的 `catmonitor.yaml` 中设置：

```yaml
faultsub:
  enabled: true
  rest_addr: ":19321"
  webhook_timeout: 5s
  webhook_retry: 1
  event_buffer: 1024
  defaults:
    debounce_ms: 0
    min_severity: warning
```

可选的 straggler 专用输出仍使用原路径：

```yaml
straggler_output:
  enabled: true
  data_dir: /var/lib/catmonitor/straggler
  retention: 360h
  flush_interval: 60s
```

验证当前故障与最近事件：

```bash
curl -fsS http://127.0.0.1:19321/-/ready
curl -fsS http://127.0.0.1:19321/faultsub/snapshot
curl -fsS http://127.0.0.1:19321/faultsub/events
```

### 3.8 DFeE Exporter、Prometheus 与 Grafana

```bash
curl -fsS http://127.0.0.1:9333/metrics | head
```

Prometheus 增加：

```yaml
scrape_configs:
  - job_name: CATMonitor
    scrape_interval: 2s
    static_configs:
      - targets: ["<dfee_exporter_ip>:9333"]
```

在 `http://<prometheus-address>:9090/targets` 确认 target 为 `UP`，再在 Grafana 导入
`features/dfee/grafana-dashboard.json`。完整 DFeE 参数与独立二进制用法见
[DFeE 使用文档](../../../features/dfee/USAGE.md)。

## 4. Stress 运行目录

generator 只生成节点配置和只读 metadata，不启动或删除容器。启用 Stress 时，必须
用本场景的完整命令重新创建 daemon/Web 所需的配置与挂载；只向 Monitoring-only
部署增加 workload 容器不会启用 Controller。先结束并清理上一场景，再继续。

```bash
export CATMONITOR_GENERATED_DIR="${CATMONITOR_GENERATED_DIR:-/etc/catmonitor/generated-stress}"
export CATMONITOR_STRESS_STATE_DIR="${CATMONITOR_STRESS_STATE_DIR:-/var/lib/catmonitor/stress}"
export CATMONITOR_NPU_OUTPUT_DIR="${CATMONITOR_NPU_OUTPUT_DIR:-/var/lib/catmonitor/stress/npu-burn-output}"
export CATMONITOR_DOCKER_SOCKET="${CATMONITOR_DOCKER_SOCKET:-/var/run/docker.sock}"

sudo install -d -m 0750 \
  "$CATMONITOR_GENERATED_DIR" \
  "$CATMONITOR_STRESS_STATE_DIR" \
  "$CATMONITOR_NPU_OUTPUT_DIR"
```

## 5. CPU Stress

### 5.1 Generate

手操步骤 06 为 CPU 场景选择新目录，避免继承之前的 history：

```bash
export CATMONITOR_GENERATED_DIR="$MANUAL_EVIDENCE/cpu-generated"
export CATMONITOR_STRESS_STATE_DIR="$MANUAL_EVIDENCE/cpu-state-live"
install -d -m 0750 "$CATMONITOR_GENERATED_DIR" "$CATMONITOR_STRESS_STATE_DIR"
```

终端 A 先读取当前 CPU 镜像的 HPL.dat（只读临时容器，不执行 benchmark），核对
其中 P、Q。不要把另一机器的 CPU 数或 MPI ranks 当成通用默认值。

```bash
nproc
cat /sys/devices/system/cpu/online
docker run --rm --network none --entrypoint /bin/cat \
  "$CATMONITOR_CPU_STRESS_IMAGE" /opt/catmonitor/stress/runtime/hpl/HPL.dat
read -r -p '输入上面 HPL.dat 的 P × Q（MPI ranks）: ' CATMONITOR_HPL_PROCESSES
export CATMONITOR_HPL_PROCESSES
export CATMONITOR_ONLINE_CPUS="$(nproc)"
(
  case "$CATMONITOR_HPL_PROCESSES" in ''|*[!0-9]*) echo 'STOP: ranks must be a positive integer'; exit 1;; esac
  test "$CATMONITOR_HPL_PROCESSES" -gt 0 &&
  test "$CATMONITOR_HPL_PROCESSES" -le "$CATMONITOR_ONLINE_CPUS"
)
# 上述检查成功后继续；整数除法向下取整，不要求 CPU 数能被 ranks 整除。
export CATMONITOR_HPL_THREADS="$((CATMONITOR_ONLINE_CPUS / CATMONITOR_HPL_PROCESSES))"
export CATMONITOR_HPCG_PROCESSES="$CATMONITOR_ONLINE_CPUS"
printf 'HPL=%sx%s HPCG=%sx1\n' "$CATMONITOR_HPL_PROCESSES" "$CATMONITOR_HPL_THREADS" "$CATMONITOR_HPCG_PROCESSES"
```

这是容量上限内的示例规模，不能代替内存/NUMA 评估；本轮只完整运行 STREAM，
HPL 用于启动/取消，HPCG 只做 doctor。CPU 工作容器与 generator 使用同一组值。

```bash
sudo bash scripts/stress/generate_stress_deployment.sh \
  --output-dir "$CATMONITOR_GENERATED_DIR" \
  --control-image "$CATMONITOR_IMAGE" \
  --cpu-image "$CATMONITOR_CPU_STRESS_IMAGE" \
  --stream-threads 0 \
  --hpl-processes "$CATMONITOR_HPL_PROCESSES" \
  --hpl-threads "$CATMONITOR_HPL_THREADS" \
  --hpcg-processes "$CATMONITOR_HPCG_PROCESSES" \
  --hpcg-threads 1 \
  --enable-web \
  --force
```

### 5.2 Compose

先执行第 4 节目录准备和第 5.1 节 CPU-only generator，然后：

```bash
CATMONITOR_IMAGE="$CATMONITOR_IMAGE" \
CATMONITOR_STRESS_STATE_DIR="$CATMONITOR_STRESS_STATE_DIR" \
  docker compose -p catmonitor \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.npu.yml \
  -f docker/docker-compose.stress.yml \
  -f "$CATMONITOR_GENERATED_DIR/docker-compose.stress.generated.yml" \
  --profile stress-cpu up -d
```

### 5.3 Manual `docker run`

先执行第 4 节目录准备和第 5.1 节 CPU-only generator。下面命令完整创建 CPU workload、daemon、Web 与
DFeE 共 4 个容器；只有 daemon 挂 Docker Socket。

```bash
docker volume create cm-snapshot
docker volume create cm-data
docker volume create cm-straggler
docker volume create cm-control
docker volume create cm-csv
docker volume create cm-stress-cpu-state

docker run -d --name catmonitor-stress-cpu --restart unless-stopped \
  --read-only --network none \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add SETGID --cap-add SETPCAP --cap-add SETUID --cap-add SYS_NICE \
  --security-opt no-new-privileges:true \
  --pids-limit 4096 --shm-size=16g \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  -e STREAM_THREADS=0 \
  -e HPL_MPI_PROCESSES="$CATMONITOR_HPL_PROCESSES" \
  -e HPL_THREADS_PER_PROCESS="$CATMONITOR_HPL_THREADS" \
  -e HPCG_MPI_PROCESSES="$CATMONITOR_HPCG_PROCESSES" \
  -e HPCG_THREADS_PER_PROCESS=1 \
  -e HPCG_NX=32 -e HPCG_NY=32 -e HPCG_NZ=32 \
  -e HPCG_RUNTIME_SECONDS=60 \
  -v cm-stress-cpu-state:/var/lib/catmonitor/stress \
  --health-cmd='/usr/bin/setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all --reuid=65532 --regid=65532 --init-groups --no-new-privs /usr/local/bin/catmonitor-stress-exec describe --benchmark stream --json' \
  --health-interval=5s --health-timeout=3s --health-retries=12 \
  --health-start-period=5s \
  "$CATMONITOR_CPU_STRESS_IMAGE"

docker run -d --name catmonitor --restart unless-stopped \
  --privileged --network host --pid host \
  -v /:/host:ro \
  -v /etc/os-release:/etc/os-release:ro \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/Ascend/nnae:/usr/local/Ascend/nnae:ro \
  -v /usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro \
  -v /usr/bin/hccn_tool:/usr/bin/hccn_tool:ro \
  -v /usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi:ro \
  -e LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:/usr/local/Ascend/nnae/latest/lib64 \
  -v "$CATMONITOR_GENERATED_DIR/catmonitor-stress.yaml:/etc/catmonitor/catmonitor.yaml:ro" \
  -v "$CATMONITOR_DOCKER_SOCKET:/var/run/docker.sock" \
  -v "$CATMONITOR_STRESS_STATE_DIR:/var/lib/catmonitor/stress" \
  -v cm-snapshot:/var/lib/catmonitor/snapshot \
  -v cm-data:/var/lib/catmonitor/data \
  -v cm-straggler:/var/lib/catmonitor/straggler \
  -v cm-control:/run/catmonitor \
  "$CATMONITOR_IMAGE"
```

**此处先停：daemon 创建返回后，立即执行 [第 3.3 节](#33-verify) 的时间采样块，
在采样结束后才继续下面的 Web/DFeE。** 不要数分钟后检查一次就称为首次生成耗时。

```bash
docker run -d --name catmonitor-web --restart unless-stopped --network host \
  --entrypoint /usr/local/bin/web \
  -v cm-snapshot:/var/lib/catmonitor/snapshot:ro \
  -v cm-control:/run/catmonitor:ro \
  "$CATMONITOR_IMAGE" \
  -addr=:19322 \
  -snapshot-dir=/var/lib/catmonitor/snapshot \
  -control-socket=/run/catmonitor/control.sock

docker run -d --name catmonitor-dfee --restart unless-stopped --network host \
  --entrypoint /usr/local/bin/dfee \
  -v cm-snapshot:/var/lib/catmonitor/snapshot:ro \
  -v cm-csv:/var/lib/catmonitor/csv \
  "$CATMONITOR_IMAGE" \
  -addr=:19323 \
  -snapshot-dir=/var/lib/catmonitor/snapshot \
  -exporter=enabled -exporter-port=9333 \
  -csv=disabled -csv-dir=/var/lib/catmonitor/csv -csv-interval=10s
```

与 canonical Compose 的契约对照：Control 使用 host network/PID、privileged、
generated YAML、state、control 与 Docker Socket；CPU workload 使用 `network none`、
只读根文件系统、最小 capabilities、16 GiB shm、只读安全选项和独立可写 state；
Web/DFeE 不挂 Docker Socket。

### 5.4 Doctor / Run / Cancel

首次 status 要单独执行、单独记录退出码，不与 doctor 混为一条成功结论：

```bash
docker exec catmonitor catmonitor stress status -o json
STATUS_RC=$?
printf 'FIRST_STATUS_EXIT=%s\n' "$STATUS_RC"
```

新 state 没有任务时曾返回 `no stress report` 和退出码 1。只有响应明确如此时，
记录为“尚无任务”；不能忽略其他非零错误。后续每个 doctor/run/status/cancel 也逐条执行。

终端 A：先执行第 3.3 节的 ready/snapshot 检查，再执行以下命令。预期 doctor 中 CPU
三项可用，NPU disabled。STREAM 完成后在 Web 的最近结果/历史核对同一 job ID。

```bash
docker exec catmonitor catmonitor stress doctor \
  -c /etc/catmonitor/catmonitor.yaml -o table
docker exec catmonitor catmonitor stress run --bench stream -o table
docker exec catmonitor catmonitor stress status -o table
```

步骤 08 的终端 A：记录旧 job ID 后启动 HPL；命令会等待结束，保持终端打开。

```bash
docker exec catmonitor catmonitor stress status -o json
docker exec catmonitor catmonitor stress run --bench hpl -o table
```

终端 B：使用相同 Docker endpoint；查看 status，确认 **新的** job ID、`running` 和
HPL，且真实 MPI/xhpl 进程已经出现，才输入该 ID 取消。不要使用上一条 STREAM ID。

```bash
printf 'DOCKER_HOST=%s\n' "${DOCKER_HOST:-unix:///var/run/docker.sock}"
docker exec catmonitor catmonitor stress status -o json
docker top catmonitor-stress-cpu -eo pid,ppid,stat,args
read -r -p '输入本次 running HPL job_id: ' JOB_ID
docker exec catmonitor catmonitor stress cancel --job "$JOB_ID"
docker exec catmonitor catmonitor stress status -o table
docker top catmonitor-stress-cpu -eo pid,ppid,stat,args
```

预期终端 A 返回 cancelled（非零退出正常），终端 B 中 `xhpl`/`mpirun`/Hydra 活进程
退出；取消是异步操作，可重复 status/top 到任务终态，超过 30 秒仍未退出则保留现场。
Web Run/Cancel 由操作者在 `/stress/` 点击；终端只检查共享 status，不代替点击。
确认页面与结果后按第 9 节清理 CPU 场景。

## 6. NPU Stress

### 6.1 Generate

步骤 10 在 CPU 场景确认清理后，为 NPU 选择新目录：

```bash
export CATMONITOR_GENERATED_DIR="$MANUAL_EVIDENCE/npu-generated"
export CATMONITOR_STRESS_STATE_DIR="$MANUAL_EVIDENCE/npu-state-live"
export CATMONITOR_NPU_OUTPUT_DIR="$CATMONITOR_STRESS_STATE_DIR/npu-burn-output"
install -d -m 0750 "$CATMONITOR_GENERATED_DIR" "$CATMONITOR_STRESS_STATE_DIR" "$CATMONITOR_NPU_OUTPUT_DIR"
```

目的：确认设备空闲和 init 支持。终端 A 执行：

```bash
npu-smi info
ls -l /dev/davinci[0-9]*
docker run --rm --init --network none --entrypoint /bin/true "$CATMONITOR_IMAGE"
```

存在外部业务进程时停在本步；不能为演示杀业务。无负载 init 探针应返回 0；若报
`docker-init` 找不到，应由管理员补齐 daemon 的 init binary，再继续。它不拉新镜像、
不加载 NPU runtime。仅 help/info 声称支持 init 不足以证明该探针通过。

```bash
sudo bash scripts/stress/generate_stress_deployment.sh \
  --output-dir "$CATMONITOR_GENERATED_DIR" \
  --control-image "$CATMONITOR_IMAGE" \
  --npu-image "$CATMONITOR_NPU_STRESS_IMAGE" \
  --npu-burn-device all \
  --npu-chip-generation A2 \
  --npu-runtime runc \
  --enable-web \
  --force
```

### 6.2 Device mapping

手工 NPU 命令从 `stress-profile.json` 读取 host IDs、映射数量与 runtime logical IDs：

```bash
export CATMONITOR_STRESS_PROFILE="$CATMONITOR_GENERATED_DIR/stress-profile.json"
mapfile -t CATMONITOR_NPU_PROFILE_FIELDS < <(
  python3 - "$CATMONITOR_STRESS_PROFILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    profile = json.load(stream)
npu = profile["npu"]
ids = npu["host_device_ids"]
if not npu["enabled"] or not ids:
    raise SystemExit("generated NPU profile is disabled or empty")
print(len(ids))
print(npu["runtime_visible_device_ids"])
print(npu["burn_logical_ids"])
for device_id in ids:
    print(device_id)
PY
)

export CATMONITOR_NPU_DEVICE_COUNT="${CATMONITOR_NPU_PROFILE_FIELDS[0]}"
export CATMONITOR_NPU_RUNTIME_VISIBLE_DEVICES="${CATMONITOR_NPU_PROFILE_FIELDS[1]}"
export CATMONITOR_NPU_BURN_DEVICE="${CATMONITOR_NPU_PROFILE_FIELDS[2]}"
CATMONITOR_NPU_DEVICE_ARGS=()
for device_id in "${CATMONITOR_NPU_PROFILE_FIELDS[@]:3}"; do
  test -e "/dev/davinci${device_id}"
  CATMONITOR_NPU_DEVICE_ARGS+=(
    "--device=/dev/davinci${device_id}:/dev/davinci${device_id}"
  )
done
test "${#CATMONITOR_NPU_DEVICE_ARGS[@]}" -eq "$CATMONITOR_NPU_DEVICE_COUNT"
```

例如宿主机观察到 `/dev/davinci2` 与 `/dev/davinci5`，只表示两个 host device
node；它们不代表 NPU Burn logical ID 是 `2,5`。generator 会得到 mapped count 2，
runtime logical namespace `0,1`，并在 workload preflight 中与 PCI topology、
`torch_npu.npu.device_count()` 交叉检查。

### 6.3 Compose

先执行第 6.1 节 NPU-only generator，然后：

```bash
CATMONITOR_IMAGE="$CATMONITOR_IMAGE" \
CATMONITOR_STRESS_STATE_DIR="$CATMONITOR_STRESS_STATE_DIR" \
  docker compose -p catmonitor \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.npu.yml \
  -f docker/docker-compose.stress.yml \
  -f "$CATMONITOR_GENERATED_DIR/docker-compose.stress.generated.yml" \
  --profile stress-npu up -d
```

### 6.4 Manual `docker run`

先执行第 6.1 节 NPU-only generator 和第 6.2 节 profile 读取块。下面命令动态使用 generator
发现的所有 host nodes，不允许手工把稀疏 host ID 当成 NPU Burn logical ID。

```bash
docker volume create cm-snapshot
docker volume create cm-data
docker volume create cm-straggler
docker volume create cm-control
docker volume create cm-csv
docker volume create cm-stress-npu-state

docker run -d --name catmonitor-stress-npu --restart unless-stopped \
  --init \
  --runtime runc --privileged --read-only --network none \
  "${CATMONITOR_NPU_DEVICE_ARGS[@]}" \
  --device=/dev/davinci_manager:/dev/davinci_manager \
  --device=/dev/devmm_svm:/dev/devmm_svm \
  --device=/dev/hisi_hdc:/dev/hisi_hdc \
  --tmpfs /tmp:rw,nosuid,nodev,size=256m \
  --tmpfs /opt/catmonitor/npuburn-home:rw,nosuid,nodev,size=1g,mode=0750 \
  -e CATMONITOR_NPU_DEVICE_COUNT="$CATMONITOR_NPU_DEVICE_COUNT" \
  -e ASCEND_RT_VISIBLE_DEVICES="$CATMONITOR_NPU_RUNTIME_VISIBLE_DEVICES" \
  -e NPU_BURN_DEVICE="$CATMONITOR_NPU_BURN_DEVICE" \
  -e NPU_BURN_RUN_CASE=matmul \
  -e NPU_BURN_GROUP= \
  -e NPU_BURN_CHIP_GENERATION=A2 \
  -e NPU_BURN_INTERNAL_TIMEOUT_SECONDS=300 \
  -v cm-stress-npu-state:/var/lib/catmonitor/stress \
  -v "$CATMONITOR_NPU_OUTPUT_DIR:/opt/catmonitor/npuburn-home/.ascend_npu_burn/output" \
  -v /sys/bus/pci:/sys/bus/pci:ro \
  -v /usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64:ro \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info:ro \
  -v /etc/ascend_install.info:/etc/ascend_install.info:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
  --health-cmd='/usr/local/bin/catmonitor-stress-exec describe --json' \
  --health-interval=10s --health-timeout=5s --health-retries=12 \
  --health-start-period=20s \
  "$CATMONITOR_NPU_STRESS_IMAGE"

docker run -d --name catmonitor --restart unless-stopped \
  --privileged --network host --pid host \
  -v /:/host:ro \
  -v /etc/os-release:/etc/os-release:ro \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/Ascend/nnae:/usr/local/Ascend/nnae:ro \
  -v /usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro \
  -v /usr/bin/hccn_tool:/usr/bin/hccn_tool:ro \
  -v /usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi:ro \
  -e LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:/usr/local/Ascend/nnae/latest/lib64 \
  -v "$CATMONITOR_GENERATED_DIR/catmonitor-stress.yaml:/etc/catmonitor/catmonitor.yaml:ro" \
  -v "$CATMONITOR_DOCKER_SOCKET:/var/run/docker.sock" \
  -v "$CATMONITOR_STRESS_STATE_DIR:/var/lib/catmonitor/stress" \
  -v cm-snapshot:/var/lib/catmonitor/snapshot \
  -v cm-data:/var/lib/catmonitor/data \
  -v cm-straggler:/var/lib/catmonitor/straggler \
  -v cm-control:/run/catmonitor \
  "$CATMONITOR_IMAGE"
```

**此处先停：daemon 创建返回后，立即执行 [第 3.3 节](#33-verify) 的时间采样块，
在采样结束后才继续下面的 Web/DFeE。** 不要数分钟后检查一次就称为首次生成耗时。

```bash
docker run -d --name catmonitor-web --restart unless-stopped --network host \
  --entrypoint /usr/local/bin/web \
  -v cm-snapshot:/var/lib/catmonitor/snapshot:ro \
  -v cm-control:/run/catmonitor:ro \
  "$CATMONITOR_IMAGE" \
  -addr=:19322 -snapshot-dir=/var/lib/catmonitor/snapshot \
  -control-socket=/run/catmonitor/control.sock

docker run -d --name catmonitor-dfee --restart unless-stopped --network host \
  --entrypoint /usr/local/bin/dfee \
  -v cm-snapshot:/var/lib/catmonitor/snapshot:ro \
  -v cm-csv:/var/lib/catmonitor/csv \
  "$CATMONITOR_IMAGE" \
  -addr=:19323 -snapshot-dir=/var/lib/catmonitor/snapshot \
  -exporter=enabled -exporter-port=9333 \
  -csv=disabled -csv-dir=/var/lib/catmonitor/csv -csv-interval=10s
```

NPU workload 的根文件系统只读；`HOME=/opt/catmonitor/npuburn-home` 由 tmpfs 提供
运行期可写目录，结果另外持久化到 `$CATMONITOR_NPU_OUTPUT_DIR`。A2/CANN 8.3/runc
profile 只给 NPU workload `privileged=true`，其网络为 `none`；Web/DFeE 不获得该权限。

### 6.5 Doctor / Run / Cancel

先检查 init 确实生效、进程列表和设备状态，再做 doctor。本场景只启用 NPU；CPU
三项应 disabled。终端 A 使用第 3.3 节等待 snapshot 后执行：

```bash
docker inspect catmonitor-stress-npu --format 'init={{.HostConfig.Init}}'
docker exec catmonitor-stress-npu ps -eo pid,ppid,stat,args
npu-smi info
docker exec catmonitor catmonitor stress doctor \
  -c /etc/catmonitor/catmonitor.yaml -o table
```

确认无外部业务、doctor 中 CANN/torch_npu/PCI topology/映射数量通过后，在终端 A
执行完整 Burn，等待自然结束；保存其 job ID 和输出，不立即启动第二条任务：

```bash
docker exec catmonitor catmonitor stress run --bench npu_burn -o table
docker exec catmonitor catmonitor stress status -o table
cat "$CATMONITOR_NPU_OUTPUT_DIR/npu_burn_results.csv"
```

预期全部映射 logical device 对应 CSV 结果 PASS，`err_count=0`。随后执行进程检查，
分别记录活跃 workload 与僵尸数；`ps` 失败必须报错，不能当成“零残留”：

<!-- manual-npu-process-check:start -->
```bash
(
  process_table=$(docker exec catmonitor-stress-npu ps -eo pid,ppid,stat,args) || exit 1
  printf '%s\n' "$process_table"
  printf '%s\n' "$process_table" | awk '
    NR > 1 && $3 !~ /^Z/ && /ascend_npu_burn|multiprocessing/ {live++}
    NR > 1 && $3 ~ /^Z/ {zombies++}
    END {printf "LIVE_WORKLOAD_COUNT=%d\nZOMBIE_PROCESS_COUNT=%d\n", live+0, zombies+0}'
)
```
<!-- manual-npu-process-check:end -->

两项预期都为 0；记录 PID、PPID、STAT。若有僵尸，先看其 PPID：init 只能收养并
回收孤儿，不能替仍存活的父进程调用 wait。此时保留同一个容器并报告回收失败，不能
以重启后归零宣称修复。`--init` 与 Compose `init: true` 是部署修正候选，实际效果以
本轮自然结束和 Cancel 两次检查为准。

Cancel：终端 A 再运行一次，保持终端打开：

```bash
docker exec catmonitor catmonitor stress run --bench npu_burn -o table
```

终端 B 使用相同 endpoint，确认新的 running job 与真实 Python
worker 已出现，再取消：

```bash
docker exec catmonitor catmonitor stress status -o json
docker exec catmonitor-stress-npu ps -eo pid,ppid,stat,args
read -r -p '输入本次 running NPU job_id: ' JOB_ID
docker exec catmonitor catmonitor stress cancel --job "$JOB_ID"
docker exec catmonitor catmonitor stress status -o table
```

到 cancelled 终态后，在**同一容器**再次执行上面的进程检查块，保存计数；30 秒后
仍有活进程则停止手操并保留现场。操作者在 Web 核对相同结果，也可亲自发起/取消任务。
完成页面检查并确认后才执行第 9 节清理，CSV/日志须先复制进本步 evidence。

## 7. CPU + NPU Full

### 7.1 Generate

```bash
sudo bash scripts/stress/generate_stress_deployment.sh \
  --output-dir "$CATMONITOR_GENERATED_DIR" \
  --control-image "$CATMONITOR_IMAGE" \
  --cpu-image "$CATMONITOR_CPU_STRESS_IMAGE" \
  --stream-threads 0 \
  --hpl-processes 8 \
  --hpl-threads 12 \
  --hpcg-processes 96 \
  --hpcg-threads 1 \
  --npu-image "$CATMONITOR_NPU_STRESS_IMAGE" \
  --npu-burn-device all \
  --npu-chip-generation A2 \
  --npu-runtime runc \
  --enable-web \
  --force
```

### 7.2 Compose

先执行第 7.1 节 Full generator，然后：

```bash
CATMONITOR_IMAGE="$CATMONITOR_IMAGE" \
CATMONITOR_STRESS_STATE_DIR="$CATMONITOR_STRESS_STATE_DIR" \
  docker compose -p catmonitor \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.npu.yml \
  -f docker/docker-compose.stress.yml \
  -f "$CATMONITOR_GENERATED_DIR/docker-compose.stress.generated.yml" \
  --profile stress-cpu --profile stress-npu up -d
```

### 7.3 Manual `docker run`

先执行第 7.1 节 Full generator 和第 6.2 节 profile 读取块。下面是完整的 5 容器命令，不需要从
其他章节拼接隐藏参数。

```bash
docker volume create cm-snapshot
docker volume create cm-data
docker volume create cm-straggler
docker volume create cm-control
docker volume create cm-csv
docker volume create cm-stress-cpu-state
docker volume create cm-stress-npu-state

docker run -d --name catmonitor-stress-cpu --restart unless-stopped \
  --read-only --network none \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add SETGID --cap-add SETPCAP --cap-add SETUID --cap-add SYS_NICE \
  --security-opt no-new-privileges:true \
  --pids-limit 4096 --shm-size=16g \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  -e STREAM_THREADS=0 \
  -e HPL_MPI_PROCESSES=8 -e HPL_THREADS_PER_PROCESS=12 \
  -e HPCG_MPI_PROCESSES=96 -e HPCG_THREADS_PER_PROCESS=1 \
  -e HPCG_NX=32 -e HPCG_NY=32 -e HPCG_NZ=32 \
  -e HPCG_RUNTIME_SECONDS=60 \
  -v cm-stress-cpu-state:/var/lib/catmonitor/stress \
  --health-cmd='/usr/bin/setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all --reuid=65532 --regid=65532 --init-groups --no-new-privs /usr/local/bin/catmonitor-stress-exec describe --benchmark stream --json' \
  --health-interval=5s --health-timeout=3s --health-retries=12 \
  --health-start-period=5s \
  "$CATMONITOR_CPU_STRESS_IMAGE"

docker run -d --name catmonitor-stress-npu --restart unless-stopped \
  --init \
  --runtime runc --privileged --read-only --network none \
  "${CATMONITOR_NPU_DEVICE_ARGS[@]}" \
  --device=/dev/davinci_manager:/dev/davinci_manager \
  --device=/dev/devmm_svm:/dev/devmm_svm \
  --device=/dev/hisi_hdc:/dev/hisi_hdc \
  --tmpfs /tmp:rw,nosuid,nodev,size=256m \
  --tmpfs /opt/catmonitor/npuburn-home:rw,nosuid,nodev,size=1g,mode=0750 \
  -e CATMONITOR_NPU_DEVICE_COUNT="$CATMONITOR_NPU_DEVICE_COUNT" \
  -e ASCEND_RT_VISIBLE_DEVICES="$CATMONITOR_NPU_RUNTIME_VISIBLE_DEVICES" \
  -e NPU_BURN_DEVICE="$CATMONITOR_NPU_BURN_DEVICE" \
  -e NPU_BURN_RUN_CASE=matmul -e NPU_BURN_GROUP= \
  -e NPU_BURN_CHIP_GENERATION=A2 \
  -e NPU_BURN_INTERNAL_TIMEOUT_SECONDS=300 \
  -v cm-stress-npu-state:/var/lib/catmonitor/stress \
  -v "$CATMONITOR_NPU_OUTPUT_DIR:/opt/catmonitor/npuburn-home/.ascend_npu_burn/output" \
  -v /sys/bus/pci:/sys/bus/pci:ro \
  -v /usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64:ro \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info:ro \
  -v /etc/ascend_install.info:/etc/ascend_install.info:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
  --health-cmd='/usr/local/bin/catmonitor-stress-exec describe --json' \
  --health-interval=10s --health-timeout=5s --health-retries=12 \
  --health-start-period=20s \
  "$CATMONITOR_NPU_STRESS_IMAGE"

docker run -d --name catmonitor --restart unless-stopped \
  --privileged --network host --pid host \
  -v /:/host:ro \
  -v /etc/os-release:/etc/os-release:ro \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/Ascend/nnae:/usr/local/Ascend/nnae:ro \
  -v /usr/local/Ascend/ascend-toolkit:/usr/local/Ascend/ascend-toolkit:ro \
  -v /usr/bin/hccn_tool:/usr/bin/hccn_tool:ro \
  -v /usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi:ro \
  -e LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux/lib64:/usr/local/Ascend/nnae/latest/lib64 \
  -v "$CATMONITOR_GENERATED_DIR/catmonitor-stress.yaml:/etc/catmonitor/catmonitor.yaml:ro" \
  -v "$CATMONITOR_DOCKER_SOCKET:/var/run/docker.sock" \
  -v "$CATMONITOR_STRESS_STATE_DIR:/var/lib/catmonitor/stress" \
  -v cm-snapshot:/var/lib/catmonitor/snapshot \
  -v cm-data:/var/lib/catmonitor/data \
  -v cm-straggler:/var/lib/catmonitor/straggler \
  -v cm-control:/run/catmonitor \
  "$CATMONITOR_IMAGE"
```

**此处先停：daemon 创建返回后，立即执行 [第 3.3 节](#33-verify) 的时间采样块，
在采样结束后才继续下面的 Web/DFeE。** 不要数分钟后检查一次就称为首次生成耗时。

```bash
docker run -d --name catmonitor-web --restart unless-stopped --network host \
  --entrypoint /usr/local/bin/web \
  -v cm-snapshot:/var/lib/catmonitor/snapshot:ro \
  -v cm-control:/run/catmonitor:ro \
  "$CATMONITOR_IMAGE" \
  -addr=:19322 -snapshot-dir=/var/lib/catmonitor/snapshot \
  -control-socket=/run/catmonitor/control.sock

docker run -d --name catmonitor-dfee --restart unless-stopped --network host \
  --entrypoint /usr/local/bin/dfee \
  -v cm-snapshot:/var/lib/catmonitor/snapshot:ro \
  -v cm-csv:/var/lib/catmonitor/csv \
  "$CATMONITOR_IMAGE" \
  -addr=:19323 -snapshot-dir=/var/lib/catmonitor/snapshot \
  -exporter=enabled -exporter-port=9333 \
  -csv=disabled -csv-dir=/var/lib/catmonitor/csv -csv-interval=10s
```

Full 必须恰好 5 个容器。daemon 因启用 Stress 获得 Docker Socket；Web 与 DFeE
仍没有 Docker Socket。

## 8. Web

```text
http://<node-address>:19322/
```

HTTP/API、页面视觉审查与按钮交互分别记录为 `HTTP_API_CHECK`、
`VISUAL_UI_REVIEW`、`WEB_RUN_CANCEL_INTERACTION`。没有浏览器或没有实际点击时，
后两项写 `NOT_PERFORMED`，不从 HTTP 200 推断通过。

这是唯一 Web listener，同时提供 Monitoring、Stress Run、Cancel、Status 与 History。
Web/DFeE 不挂 Docker Socket。当前 operator API 尚无认证/RBAC，只能向可信管理网络
开放，或由带认证的反向代理保护。

## 9. 停止与清理

手操步骤 05/09/12：先由操作者确认页面检查结束并保存输出。下面只清理本轮通过
名称/端口门禁后创建的场景；若这些名称不属于本轮，停下核对，不能直接执行。
三种场景分别在 Bash 终端 A 执行对应块，不删除镜像、不使用 prune。

Monitoring-only：

```bash
docker logs catmonitor > "$MANUAL_EVIDENCE/monitoring-daemon.log" 2>&1
docker rm -f catmonitor-web catmonitor-dfee catmonitor
docker volume rm cm-snapshot cm-data cm-straggler cm-csv
docker ps -a --format '{{.Names}} {{.Status}}'
```

CPU-only（已确认 HPL 取消并且无活进程）：

```bash
mkdir -p "$MANUAL_EVIDENCE/cpu-config" "$MANUAL_EVIDENCE/cpu-state"
cp -a "$CATMONITOR_GENERATED_DIR/." "$MANUAL_EVIDENCE/cpu-config/"
cp -a "$CATMONITOR_STRESS_STATE_DIR/." "$MANUAL_EVIDENCE/cpu-state/"
docker logs catmonitor > "$MANUAL_EVIDENCE/cpu-daemon.log" 2>&1
docker rm -f catmonitor-web catmonitor-dfee catmonitor catmonitor-stress-cpu
docker volume rm cm-snapshot cm-data cm-straggler cm-control cm-csv cm-stress-cpu-state
docker ps -a --format '{{.Names}} {{.Status}}'
```

NPU-only（已保存自然结束和 Cancel 两次进程计数）：

```bash
mkdir -p "$MANUAL_EVIDENCE/npu-config" "$MANUAL_EVIDENCE/npu-state" "$MANUAL_EVIDENCE/npu-output"
cp -a "$CATMONITOR_GENERATED_DIR/." "$MANUAL_EVIDENCE/npu-config/"
cp -a "$CATMONITOR_STRESS_STATE_DIR/." "$MANUAL_EVIDENCE/npu-state/"
cp -a "$CATMONITOR_NPU_OUTPUT_DIR/." "$MANUAL_EVIDENCE/npu-output/"
docker logs catmonitor-stress-npu > "$MANUAL_EVIDENCE/npu-workload.log" 2>&1
docker rm -f catmonitor-web catmonitor-dfee catmonitor catmonitor-stress-npu
docker volume rm cm-snapshot cm-data cm-straggler cm-control cm-csv cm-stress-npu-state
docker ps -a --format '{{.Names}} {{.Status}}'
```

默认保留 bind 目录中的 history/CSV/profile。为了下一场景独立，步骤 06 和 10 重新
设置第 4 节三个目录为未使用的场景子目录；不要覆盖上一场景配置。容器/卷若已经清零
无需重复删除；需要删除 bind 目录时先逐一列出其绝对路径并核对备份，由管理员执行。

手工入口停止但保留容器：

```bash
docker stop catmonitor catmonitor-web catmonitor-dfee \
  catmonitor-stress-cpu catmonitor-stress-npu 2>/dev/null || true
```

重新启动只选择当前 profile 实际存在的容器。删除容器不会删除 named volumes；不要在
需要保留 snapshot/history 时删除这些 volumes。

切换到新的 Stress 镜像集合：

```text
OLD_STRESS_YAML_COMPATIBLE=false
```

必须重新运行 generator，不能复制旧 `script_path`、固定 NPU 容器、CPU Runner socket
或独立 Stress Web 配置。Monitoring-only YAML 可以没有 `stress:` 段。

## 10. 故障排查

- NPU Monitoring 为空：检查 `npu-smi info`、driver/toolkit 挂载和 daemon 日志。
- NPU Burn unavailable：执行 doctor，核对 CANN、torch_npu、lspci 与 device count。
- 稀疏设备映射错误：不要手写连续 `0..N-1` host node，让 generator 动态发现。
- `No available device`：核对容器内 `lspci -D -d 19e5:`、
  `ASCEND_RT_VISIBLE_DEVICES`、`torch_npu.npu.device_count()` 与 logical topology。
- `aclInit 507899` / `Resource_Busy` / `Device id is invalid`：A2 验收 profile 必须让
  NPU workload 使用 `--privileged`；不要把该权限授予 Web 或 DFeE。
- HPL 立即失败：核对 `HPL_MPI_PROCESSES == P×Q`，不要盲用默认值 1。
- Web snapshot 未就绪：先检查 `19320/-/ready`，不要另起第二个 Web。
- Docker API 版本不匹配：当前 Stress Controller 会通过配置的 Unix socket 自动协商，
  用户不应手工设置 `DOCKER_API_VERSION`。
- Registry 不可达：离线传输同一标签和 Image ID 的镜像，不得替换成旧 a2-r1 镜像。
