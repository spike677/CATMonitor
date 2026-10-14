# 从 85 的现有 A2 部署迁移到其他 A2 节点

## 1. 本轮范围与两种入口

本轮来源是 **85 已经运行的 A2 部署**，目标是另一台获准使用的 Linux/ARM64 A2 节点。不是重新构建，也不更换芯片代际、CANN、torch_npu 或 wheel。本文未连接 85 或目标机，未证明目标机验收通过。

- 85：读取实际运行镜像身份，保存现成镜像和配套的公开部署源码；不停止、不重启现有服务。
- 新 A2：导入同一镜像，在新目录重新生成本机配置，再创建容器、预检和测试。
- `docker save` 打包镜像，不打包 Compose 启动后的容器、可写层或挂载卷；`docker load` 只导入，不运行。Compose 随后从这些镜像创建普通容器，不再套一层容器。
- 若目标机可访问存放这些**相同镜像身份**的 registry，可以直接 pull 后核对 Image ID，省略 save/load。不能把可变 tag 或程序版本号当作同一构建的证明。

本节以完整五服务为例：Control、Web、DFeE、CPU workload、NPU workload。Control/Web/DFeE 常来自同一镜像，但也可能已经混用版本；下面逐个记录，绝不假定三者相同。五个传输标签不等于五张不同镜像，共用的镜像层只保存一次。

如果 85 没有 CPU workload，不要拿不明镜像凑齐此模板；改用 [A2 使用指南](NPU_A2_USAGE_GUIDE.md) 的仅 NPU 四服务入口。设备和驱动兼容性仍需在新节点验证；A2 型号、HBM 容量和 CPU 数量不同，不能照搬源节点负载规模或既往 PASS。

以下命令由管理员在 **Bash** 执行，分别标明 85 和目标机。括号内失败只停止该代码块，不退出 SSH 登录 shell；失败后不要继续下一块。仅转移获准的镜像、公共源码及经过审查的 JSON 配置，不向公共仓库上传现场数据、凭据、参考或私有依赖。

## 2. 在 85 确认实际来源

### 2.1 填真实容器名和配套源码目录

只读列出容器，不依据文档示例猜名称：

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker info --format 'DockerRootDir={{.DockerRootDir}}'
df -h / /home

read -r -p '85 的 Controller 容器名：' SRC_CONTROL
read -r -p '85 的 Web 容器名：' SRC_WEB
read -r -p '85 的 DFeE 容器名：' SRC_DFEE
read -r -p '85 的 CPU workload 容器名：' SRC_CPU
read -r -p '85 的 NPU workload 容器名：' SRC_NPU
read -r -p '与85运行镜像配套的公共源码绝对目录：' SOURCE_DIR
```

这里必须使用该部署构建记录对应的源码，不能仅凭 `0.3.6` 推断是某个 commit。没有配套构建记录、源码脏或使用了容器内临时补丁时，先补齐身份，不把任意最新分支混入本次迁移。盘点至打包期间暂停软件/JSON 配置变更（不需要停止现有服务）；参数搜索还在修改配置时先等待稳定，避免打包出混合版本。

```bash
(
set -euo pipefail
test -d "$SOURCE_DIR/.git" || git -C "$SOURCE_DIR" rev-parse --git-dir >/dev/null
git -C "$SOURCE_DIR" rev-parse HEAD
git -C "$SOURCE_DIR" status --short
test -z "$(git -C "$SOURCE_DIR" status --porcelain)"

for name in "$SRC_CONTROL" "$SRC_WEB" "$SRC_DFEE" "$SRC_CPU" "$SRC_NPU"; do
  docker inspect "$name" \
    --format '{{.Name}} image={{.Image}} running={{.State.Running}} privileged={{.HostConfig.Privileged}}'
  docker inspect "$name" \
    --format '{{range .Mounts}}{{println .Type .Source "->" .Destination}}{{end}}'
  docker diff "$name"
done

docker exec "$SRC_CONTROL" catmonitor stress run --help
docker exec "$SRC_NPU" /usr/local/bin/catmonitor-stress-exec describe --json
)
```

**镜像独立性门禁：**审查 `docker diff` 和 mounts。运行期日志/缓存与软件变更要区分。若二进制、Python 包、wheel、Custom Ops 或源代码依赖容器可写层、宿主 bind 覆盖，镜像 save 不含这些修改。本流程应停止，先取得包含这些获准修复的明确镜像；不通过提交容器或临时拷包掩盖。允许另传完整 JSON 参数目录，但不允许把它当成软件补丁目录。

`describe --json` 不带 benchmark 时用于确认 workload 协议，不训练，也不是目标机硬件预检通过。

### 2.2 记录 NPU 的实际环境设置

只提取几个非凭据字段，不打印完整环境变量：

```bash
read_npu_env() {
  docker inspect "$SRC_NPU" --format '{{json .Config.Env}}' |
    python3 -c 'import json,sys; e=dict(x.split("=",1) for x in json.load(sys.stdin) if "=" in x); print(e.get(sys.argv[1], ""))' "$1"
}

NPU_ASCEND_ENV_SCRIPT=$(read_npu_env ASCEND_ENV_SCRIPT)
NPU_MEMORY_MODE=$(read_npu_env CATMONITOR_MODEL_MEMORY_MODE)
NPU_DEVICE_MODE=$(read_npu_env CATMONITOR_NPU_DEVICE_MODE)

printf 'ASCEND_ENV_SCRIPT=%s\nMODEL_MEMORY_MODE=%s\nDEVICE_MODE=%s\n' \
  "$NPU_ASCEND_ENV_SCRIPT" "$NPU_MEMORY_MODE" "$NPU_DEVICE_MODE"

# 如果85依赖自动发现，管理员需核实并填写镜像内真实路径，不能套其他镜像路径。
if [ -z "$NPU_ASCEND_ENV_SCRIPT" ]; then
  read -r -p '已核实的镜像内 CANN set_env.sh 绝对路径：' NPU_ASCEND_ENV_SCRIPT
fi
if [ -z "$NPU_MEMORY_MODE" ]; then
  read -r -p '已核实的模型 memory mode（standard/checkpointed）：' NPU_MEMORY_MODE
fi
if [ -z "$NPU_DEVICE_MODE" ]; then
  read -r -p '已核实的设备模式（本模板仅full）：' NPU_DEVICE_MODE
fi

NPU_SECURITY_PROFILE=restricted
if [ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$SRC_NPU")" = true ]; then
  NPU_SECURITY_PROFILE=legacy-privileged
fi

(
set -euo pipefail
case "$NPU_ASCEND_ENV_SCRIPT" in /*) ;; *) exit 1 ;; esac
docker exec "$SRC_NPU" test -f "$NPU_ASCEND_ENV_SCRIPT"
case "$NPU_MEMORY_MODE" in standard|checkpointed) ;; *) exit 1 ;; esac
test "$NPU_DEVICE_MODE" = full
)
```

本模板只处理已获准全节点映射的 `full` 部署，并保留源 NPU 的 privileged/restricted 选择，不自动提权。源节点是 `single` 或目标要求设备隔离时，使用 [设备子集说明](NPU_OPERATOR_GUIDE.md) 另行确定映射；不能把 full 模板中的设备数改成 1 就声称隔离成立。Controller 持有 Docker socket 的权限边界保持不变。

## 3. 在 85 保存镜像、公共源码和完整配置

`/home` 只是示例数据盘；先确认空间。下列命令不启动或停止任何服务。

```bash
install -d -m 0750 /home/catmonitor-transfer
PACK=$(mktemp -d /home/catmonitor-transfer/a2-from85.XXXXXXXX)
TRANSFER_ID=$(basename "$PACK")

(
set -euo pipefail
umask 077
SOURCE_COMMIT=$(git -C "$SOURCE_DIR" rev-parse HEAD)
test -z "$(git -C "$SOURCE_DIR" status --porcelain)"

read -r -p '已核实镜像无运行期软件覆盖、源码配套且允许转运，输入 VERIFIED：' approval
test "$approval" = VERIFIED

: > "$PACK/image-ids.tsv"
for role in CONTROL WEB DFEE CPU NPU; do
  case "$role" in
    CONTROL) name=$SRC_CONTROL ;;
    WEB) name=$SRC_WEB ;;
    DFEE) name=$SRC_DFEE ;;
    CPU) name=$SRC_CPU ;;
    NPU) name=$SRC_NPU ;;
  esac
  # .Image 是运行容器实际绑定的 ID，不是可能已经移动的 .Config.Image tag。
  id=$(docker inspect --format '{{.Image}}' "$name")
  platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$id")
  test "$platform" = linux/arm64
  ref="catmonitor-transfer/a2-${role,,}:$TRANSFER_ID"
  docker tag "$id" "$ref"
  printf -v "$role" '%s' "$ref"
  printf '%s\t%s\t%s\t%s\n' "$role" "$ref" "$id" "$platform" >> "$PACK/image-ids.tsv"
done

declare -p CONTROL WEB DFEE CPU NPU SOURCE_COMMIT \
  NPU_ASCEND_ENV_SCRIPT NPU_MEMORY_MODE NPU_DEVICE_MODE NPU_SECURITY_PROFILE \
  > "$PACK/release.env"

git -C "$SOURCE_DIR" archive --format=tar.gz --prefix=CATMonitor/ \
  --output="$PACK/source.tar.gz" "$SOURCE_COMMIT"

# 从现有容器读取完整生效JSON；不复制整个运行HOME、参考或输出。
mkdir "$PACK/npu-config"
docker cp "$SRC_NPU:/opt/catmonitor/npuburn-python/ascend_npu_burn/config/." \
  "$PACK/npu-config/"
python3 "$SOURCE_DIR/scripts/stress/npu_config_profile.py" \
  --validate-dir "$PACK/npu-config"
tar -czf "$PACK/npu-config.tar.gz" -C "$PACK" npu-config

docker save "$CONTROL" "$WEB" "$DFEE" "$CPU" "$NPU" |
  gzip -1 > "$PACK/images.tar.gz"

cd "$PACK"
sha256sum images.tar.gz source.tar.gz npu-config.tar.gz release.env image-ids.tsv \
  > SHA256SUMS
cat image-ids.tsv
du -h images.tar.gz source.tar.gz npu-config.tar.gz
printf '转运目录：%s\n' "$PACK"
)
```

保存的 JSON 仍需管理员审查是否允许离开源节点；如含内部信息，按内部合规渠道处理，不能发到聊天或公共 Git。`release.env` 只有本步骤挑选的镜像/运行参数，没有 PAT、Docker config 或全部环境变量。

**不要传递并直接复用**85 的 generated Compose/YAML、Docker data-root、设备编号、容器运行状态、历史报告、模型参考及结果目录。部署配置有节点绝对路径和设备绑定，应在目标重生成。完整模型参数可作为起点，但不同 HBM 规格未必能执行。

通过获准通道传送六个文件。例如目标目录已由管理员创建时：

```bash
read -r -p '目标A2的SSH登录地址（例如root@管理网IP）：' TARGET_SSH
ssh "$TARGET_SSH" 'install -d -m 0750 /home/catmonitor-transfer/from85'
scp "$PACK/images.tar.gz" "$PACK/source.tar.gz" "$PACK/npu-config.tar.gz" \
  "$PACK/release.env" "$PACK/image-ids.tsv" "$PACK/SHA256SUMS" \
  "$TARGET_SSH:/home/catmonitor-transfer/from85/"
```

受限节点采用管理员批准的文件传输方式即可，不要求跨域 SSH。校验和用于检查传输完整性，不替代来源信任或安全审批。

## 4. 新 A2：导入，不重建

以下开始全部在**目标节点**执行，不在 85 执行。`release.env` 仅加载自己核对过来源的转运文件。

```bash
PACK=/home/catmonitor-transfer/from85
(
set -euo pipefail
cd "$PACK"
sha256sum -c SHA256SUMS
test "$(uname -m)" = aarch64
docker load -i images.tar.gz
while IFS=$'\t' read -r role ref expected platform; do
  test "$(docker image inspect -f '{{.Id}}' "$ref")" = "$expected"
  test "$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$ref")" = "$platform"
  printf '%s IMAGE_ID=PASS platform=%s\n' "$role" "$platform"
done < image-ids.tsv
)
```

只有上块导入及五项身份核对全部成功，才在下一块建立新目录：

```bash
source "$PACK/release.env"
install -d -m 0750 /home/catmonitor
DEPLOY=$(mktemp -d /home/catmonitor/a2-from85.XXXXXXXX)
install -d -m 0750 "$DEPLOY/source" "$DEPLOY/state" "$DEPLOY/npu-output" "$DEPLOY/results"
tar -xzf "$PACK/source.tar.gz" -C "$DEPLOY/source"
tar -xzf "$PACK/npu-config.tar.gz" -C "$DEPLOY"
cd "$DEPLOY/source/CATMonitor"

printf 'DEPLOY=%s\nSOURCE_COMMIT=%s\n' "$DEPLOY" "$SOURCE_COMMIT"
```

不要求 load 后仍保留 registry RepoDigest，用传输前后完整 Image ID 核对。源码 tar 来自固定 Git commit，不包含 `.git`；`SOURCE_COMMIT` 是其导出身份，不声称目标进行了 clone。

## 5. 新 A2：前置检查与本机配置

### 5.1 不与已有部署抢名称或端口

```bash
PROJECT="catmonitor-$(basename "$DEPLOY" | tr '[:upper:]' '[:lower:]')"
CPU_CONTAINER="$PROJECT-cpu"
NPU_CONTAINER="$PROJECT-npu"
G="$DEPLOY/generated"
OUT="$DEPLOY/npu-output"

(
set -euo pipefail
docker version
docker compose version
docker info --format 'DockerRootDir={{.DockerRootDir}}'
df -h / /home
npu-smi info
find /dev -maxdepth 1 -type c -name 'davinci*' -print

test -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")"
test -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")"
for name in "$CPU_CONTAINER" "$NPU_CONTAINER"; do
  if docker container inspect "$name" >/dev/null 2>&1; then
    echo "STOP: name already used: $name" >&2
    exit 1
  fi
done
listeners=$(ss -lntp)
if printf '%s\n' "$listeners" | grep -E ':(19320|19321|19322|19323|9333)([[:space:]]|$)'; then
  echo 'STOP: required ports are already used; do not stop existing services.' >&2
  exit 1
fi

for path in /usr/local/Ascend/driver/lib64 /usr/local/Ascend/driver/version.info \
  /usr/local/dcmi /etc/ascend_install.info /usr/local/bin/npu-smi \
  /usr/local/Ascend/nnae /usr/local/Ascend/ascend-toolkit \
  /usr/bin/hccn_tool /usr/local/sbin/npu-smi \
  /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc; do
  test -e "$path" || { echo "STOP: missing $path" >&2; exit 1; }
done
python3 scripts/stress/npu_config_profile.py --validate-dir "$DEPLOY/npu-config"
)
```

这是空闲部署位的 host-network 模板。独立项目名隔离项目卷，但**不隔离 host 网络端口**。当前 daemon Metrics 固定 `19320`，不能仅改 Web 端口就声称可与旧 daemon 并存。冲突时停止，另行制定旁路网络方案；本指南不停止/重命名任何已有服务。不用空文件或空目录假装驱动依赖存在。

### 5.2 明确目标节点的设备授权

先由管理员确认目标的预期逻辑索引和全部设备映射授权，再由实际 doctor 验证。不要照抄 85 的宿主节点编号，也不预设新机器是 `/dev/davinci2,/dev/davinci5`。

```bash
read -r -p '目标已授权的logical ID列表（逗号分隔，非宿主davinci编号）：' ALLOWED_DEVICES
read -r -p '本次初始单卡logical ID：' ONE_DEVICE

(
set -euo pipefail
[[ "$ONE_DEVICE" =~ ^[0-9]+$ ]]
[[ "$ALLOWED_DEVICES" =~ ^[0-9]+(,[0-9]+)*$ ]]
case ",$ALLOWED_DEVICES," in *",$ONE_DEVICE,"*) ;; *) exit 1 ;; esac
test "$NPU_DEVICE_MODE" = full

bash scripts/stress/generate_stress_deployment.sh \
  --output-dir "$G" --control-image "$CONTROL" \
  --cpu-image "$CPU" --cpu-container "$CPU_CONTAINER" \
  --npu-image "$NPU" --npu-container "$NPU_CONTAINER" \
  --stream-threads 1 \
  --hpl-profile small --hpl-processes 1 --hpl-threads 1 \
  --hpcg-processes 1 --hpcg-threads 1 \
  --hpcg-nx 32 --hpcg-ny 32 --hpcg-nz 32 --hpcg-runtime 60 \
  --npu-chip-generation A2 --npu-runtime runc \
  --npu-device-mode full --npu-security-profile "$NPU_SECURITY_PROFILE" \
  --npu-burn-device "$ONE_DEVICE" --npu-allowed-devices "$ALLOWED_DEVICES" \
  --npu-run-case matmul --npu-threads 1 \
  --npu-ascend-env-script "$NPU_ASCEND_ENV_SCRIPT" \
  --npu-config-dir "$DEPLOY/npu-config" --npu-output-dir "$OUT" \
  --npu-allowed-models gpt3,llama2 --allow-npu-reference-generation \
  --npu-model-memory-mode "$NPU_MEMORY_MODE" --npu-job-timeout 12h \
  --enable-web

python3 -m json.tool "$G/stress-profile.json"
)
```

本节点动态发现宿主设备，doctor 还必须核实 runtime logical namespace 和 PCI 拓扑。授权列表不是设备隔离；`full + legacy-privileged` 是高权限运行，必须获准才能沿用。若 restricted 不通过，不能自行提权或映射更多业务设备。

CPU 使用明确的小规模迁移 smoke 参数，不宣称复制了 85 的性能负载。模型保留转运的完整配置和 memory mode，12h 只是上限，不是持续时长，也不保证当前 HBM 足够。若不授权参考生成或模型操作，生成时删除对应 opt-in 参数。

## 6. 新 A2：从已有镜像创建五容器

为保留 85 的实际 Web/DFeE 镜像身份，增加两个 image override；即使它们与 Control 相同也可以保留。不修改产品 Compose 文件。

```bash
cat > "$DEPLOY/images.override.yml" <<EOF
services:
  web:
    image: $WEB
  dfee:
    image: $DFEE
EOF

export CATMONITOR_IMAGE="$CONTROL"
export CATMONITOR_STRESS_STATE_DIR="$DEPLOY/state"
export CATMONITOR_DOCKER_SOCKET=/var/run/docker.sock
export CATMONITOR_WEB_ADDR=:19322

dc() {
  docker compose -p "$PROJECT" \
    -f "$DEPLOY/source/CATMonitor/docker/docker-compose.yml" \
    -f "$DEPLOY/source/CATMonitor/docker/docker-compose.npu.yml" \
    -f "$DEPLOY/source/CATMonitor/docker/docker-compose.stress.yml" \
    -f "$G/docker-compose.stress.generated.yml" \
    -f "$DEPLOY/images.override.yml" \
    --profile stress-cpu --profile stress-npu "$@"
}

dc config --services
dc config > "$DEPLOY/results/compose.resolved.yaml"
less "$DEPLOY/results/compose.resolved.yaml"
```

检查五个 image 与转运清单一致；workload 名是新名称；state/output/config 指向新目录；命名卷是新项目卷；Web/DFeE 没有 Docker socket；只读 NPU 根目录、完整只读 JSON 挂载、目标设备和权限均正确。CANN/torch_npu 留在 workload 镜像内，不挂宿主 Python/site-packages，不临时 pip 安装。

```bash
# 检查通过后才执行；Compose v2 禁止构建、禁止联网替换镜像。
dc up -d --no-build --pull never
dc ps

# 对实际启动容器再次核对五个角色，而非只检查本地标签。
(
set -euo pipefail
test "$(dc ps -q | wc -l | tr -d ' ')" = 5
while IFS=$'\t' read -r role ref expected platform; do
  case "$role" in
    CONTROL) service=catmonitor ;;
    WEB) service=web ;;
    DFEE) service=dfee ;;
    CPU) service=catmonitor-stress-cpu ;;
    NPU) service=catmonitor-stress-npu ;;
    *) exit 1 ;;
  esac
  cid=$(dc ps -q "$service")
  test -n "$cid"
  test "$(docker inspect -f '{{.Image}}' "$cid")" = "$expected"
  test "$(docker inspect -f '{{.State.Running}}' "$cid")" = true
done < "$PACK/image-ids.tsv"
)
```

Compose 创建的是新节点的容器，不是把 85 的容器搬过来；85 不需要再次执行 Compose。data/snapshot/reference 等卷也是目标新建，旧节点 reference 不随镜像迁移。

## 7. 新 A2：doctor、选卡选算子和 Web

等待首次采集。以下每项失败都先查看 `dc logs --tail 100 catmonitor catmonitor-stress-npu`，不要用最后一个成功的 echo 覆盖前面的失败。

```bash
(
set -euo pipefail
curl -fsS http://127.0.0.1:19320/-/ready
curl -fsS http://127.0.0.1:19320/metrics > "$DEPLOY/results/metrics.txt"
dc exec -T catmonitor test -s /var/lib/catmonitor/snapshot/snapshot_npu.json
curl -fsS http://127.0.0.1:19322/ >/dev/null
curl -fsS http://127.0.0.1:19322/stress/ >/dev/null
curl -fsS http://127.0.0.1:19323/ >/dev/null

dc exec -T catmonitor-stress-npu /usr/local/bin/catmonitor-stress-exec \
  describe --benchmark npu_burn --json --require-pass > "$DEPLOY/results/npu-describe.json"
dc exec -T catmonitor catmonitor stress doctor \
  -c /etc/catmonitor/catmonitor.yaml -o json > "$DEPLOY/results/doctor.json"
python3 - "$DEPLOY/results/doctor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r['status'] == 'pass', r
enabled = [x for x in r['benchmarks'] if x['enabled']]
assert {x['name'] for x in enabled} == {'stream', 'hpl', 'hpcg', 'npu_burn'}
assert all(x['available'] and x['status'] == 'pass' for x in enabled), enabled
print('DOCTOR=PASS_4_OF_4')
PY
)

python3 -m json.tool "$DEPLOY/results/npu-describe.json"
npu-smi info
```

核对本机 CANN/torch_npu、实际宿主节点与 logical IDs、选定设备和算子目录。预检通过不是硬件 workload PASS。存在业务占用时等待维护窗口，不关闭空闲检查，不杀业务。

管理员确认 CPU 和 NPU 测试资源获准且空闲后，先做短路径：

```bash
(
set -euo pipefail
dc exec -T catmonitor catmonitor stress run --bench stream \
  -c /etc/catmonitor/catmonitor.yaml -o json | tee "$DEPLOY/results/stream.json"
dc exec -T catmonitor catmonitor stress run \
  --bench npu_burn --npu-devices "$ONE_DEVICE" --npu-cases matmul \
  --timeout 30m -c /etc/catmonitor/catmonitor.yaml -o json \
  | tee "$DEPLOY/results/npu-matmul.json"
)
```

首次成功后再按实际授权选择多卡、多个当前准入通过的算子，例如：

```bash
dc exec -T catmonitor catmonitor stress run \
  --bench npu_burn --npu-devices "$ALLOWED_DEVICES" --npu-cases matmul,conv2d \
  --timeout 30m -c /etc/catmonitor/catmonitor.yaml -o json
```

在本版本 A2 上，`quant_matmul` 缺少上游 A2 策略，不强行启用。最终检查 Job healthy、本次 CSV 的设备/算子覆盖完整、用例 PASS 和 err_count=0，不以 CSV 文件存在判通过。

浏览器直接访问 `http://<目标A2管理网IP>:19322/stress/`，健康概览 `:19322/`，DFeE `:19323/`。网络可达且防火墙允许时不需要 SSH 隧道。当前 Web Run/Cancel 无完整认证/RBAC，只开放给可信管理网；`web_enabled` 不能替代后端鉴权。

## 8. 模型 SDC 和 Cancel

参考不从 85 复制。本节点先对完整参数做模型预检，再在已确认健康的单卡生成新参考；新节点的通过结论不能由源节点报告代替。模型命令不混用 `--npu-cases`。

```bash
REF_STAMP=$(date +%Y%m%dT%H%M%S)
GPT3_REF="gpt3-a2-$REF_STAMP"
LLAMA2_REF="llama2-a2-$REF_STAMP"

(
set -euo pipefail
dc exec -T catmonitor catmonitor stress run \
  --bench npu_burn --npu-devices "$ONE_DEVICE" \
  --npu-model gpt3 --model-action create_reference --reference-id "$GPT3_REF" \
  -c /etc/catmonitor/catmonitor.yaml -o json | tee "$DEPLOY/results/gpt3-reference.json"
dc exec -T catmonitor catmonitor stress run \
  --bench npu_burn --npu-devices "$ALLOWED_DEVICES" \
  --npu-model gpt3 --model-action compare --reference-id "$GPT3_REF" \
  -c /etc/catmonitor/catmonitor.yaml -o json | tee "$DEPLOY/results/gpt3-compare.json"
)

(
set -euo pipefail
dc exec -T catmonitor catmonitor stress run \
  --bench npu_burn --npu-devices "$ONE_DEVICE" \
  --npu-model llama2 --model-action create_reference --reference-id "$LLAMA2_REF" \
  -c /etc/catmonitor/catmonitor.yaml -o json | tee "$DEPLOY/results/llama2-reference.json"
dc exec -T catmonitor catmonitor stress run \
  --bench npu_burn --npu-devices "$ALLOWED_DEVICES" \
  --npu-model llama2 --model-action compare --reference-id "$LLAMA2_REF" \
  -c /etc/catmonitor/catmonitor.yaml -o json | tee "$DEPLOY/results/llama2-compare.json"
)
```

- 生成参考：`outcome=reference_generated`、`saved_steps=expected_steps`、`checked_steps=0`、`errors=0`。这不是 SDC 对照通过。
- 对照：`outcome=sdc_passed`、`checked_steps=expected_steps × 请求设备数`、`errors=0`，Job、参考、设备和 CSV 必须属于本轮。
- 多卡模型是逐卡顺序验证，不合并 HBM。不支持的容量/参数需另建受审配置，不能暗中缩减后声称原配置通过。详情见 [A2 模型操作](NPU_A2_USAGE_GUIDE.md#7-web-生成参考和执行模型-sdc)。

Cancel 推荐在 Web 启动作业，再用同一 Bash 会话取消，以验证跨入口共享 Job。等 `dc top` 观察到本次真实训练/Burn worker 后执行：

```bash
dc exec -T catmonitor catmonitor stress status -o json
dc top catmonitor-stress-npu
read -r -p '复制本次待取消的job_id：' JOB_ID
dc exec -T catmonitor catmonitor stress cancel --job "$JOB_ID"
dc exec -T catmonitor catmonitor stress status --job "$JOB_ID" -o json
dc top catmonitor-stress-npu
npu-smi info
```

轮询至 `status=cancelled`，确认本次 workload 子进程退出、固定容器仍运行、原参考未删除；accepted 不是清理完成。也可 CLI 发起、Web Cancel；CLI run 同步等待，不能误以为要等它结束才能在网页取消。不能按全机进程名 kill。

## 9. 保留现场与停止本次新部署

保存本机变量和函数，方便重新登录使用同一项目，不将它们上传 Git：

```bash
(
umask 077
declare -p PACK DEPLOY PROJECT G OUT CPU_CONTAINER NPU_CONTAINER \
  CONTROL WEB DFEE CPU NPU ONE_DEVICE ALLOWED_DEVICES \
  CATMONITOR_IMAGE CATMONITOR_STRESS_STATE_DIR CATMONITOR_DOCKER_SOCKET CATMONITOR_WEB_ADDR \
  > "$DEPLOY/session.sh"
declare -f dc >> "$DEPLOY/session.sh"
)
printf '下次登录：source %q/session.sh\n' "$DEPLOY"
```

先 Cancel 并确认没有活动 Job，再停止本次项目：

```bash
dc stop
```

需要移除本次容器时：

```bash
dc down
```

不加 `-v`，保留数据卷、配置、参考、结果和镜像。不要操作其他项目。85 始终不停止，本流程也不替换目标机原有部署；因此没有“恢复85旧容器”的步骤。目标机若已被其他部署占用，在第 5 节停止，不把清理或停旧服务混入迁移。

## 10. 验收记录边界

逐项记录实际结果：`SOURCE_IDENTITY`、`IMAGE_IDS`、`FIVE_CONTAINERS`、`METRICS`、`SNAPSHOT`、`WEB`、`DFEE`、`DOCTOR_4_OF_4`、`STREAM`、`NPU_OPERATOR_CSV`、`GPT3_SDC`、`LLAMA2_SDC`、`CANCEL_CLEANUP`、`SOURCE85_UNTOUCHED`。

本文只提供详细部署命令和本地文档契约检查；尚未在目标 A2 执行的项目统一记为 **NOT_RUN/PENDING**。镜像导入成功不等于驱动兼容、doctor 或压测成功，不能把85的既往通过结果复制成新节点的验收报告。
