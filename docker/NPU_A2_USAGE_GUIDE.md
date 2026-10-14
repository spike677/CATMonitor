# CATMonitor A2 NPU Burn 部署与管理员使用指南

本指南是 [九页使用 PPT（含可编辑流程图）](presentations/CATMonitor_A2_NPU_Burn_使用指南.pptx) 的完整命令版，覆盖镜像下载、Compose 部署、按作业选卡选算子、外部配置、Web 模型参考与 SDC，以及管理员启停压测。

PPT 前五页保留功能、下载、部署、参数及真实 A2 页面说明；第 6–9 页分别展示部署与首次作业验收、功能代码修改与镜像更新、三类配置的生效方式、管理员开启与关闭压测。流程图区分重编镜像、重建容器和仅对本次 Job 生效，不表示新增 A3 实机验收已经通过。

适用范围：Linux/ARM64、Ascend A2，配套代码基线 `5a3537cfc0cd1420c5e63bb4991e72c832781eca`。镜像和命令核对日期为 2026-10-14。这是一套候选版本使用说明，不是 A3 兼容认证或正式版本发布声明。分支名称含 `a3-migration`，不代表下文 A2 workload 镜像适用于 A3。

## 1. 镜像包含什么

| 镜像 | 内含组件 | 职责及宿主要求 |
| --- | --- | --- |
| `catmonitor-npu` | `catmonitor` daemon/CLI/Stress Controller、Web、DFeE、监控工具及配置 | 一张 Control 镜像启动三个服务。Ascend 监控仍需宿主驱动与对应只读挂载；不包含 CPU/NPU 压测件的完整运行环境 |
| `catmonitor-stress-cpu` | STREAM、HPL、HPCG、MPI、OpenBLAS、NUMA 工具、workload executor | 只执行 CPU 压测，不单独提供 CATMonitor Web/Controller |
| `catmonitor-stress-npu` | CANN 8.5.1、Python、PyTorch/torch_npu、NPU Burn、Custom Ops、`lspci`、workload executor及模型 SDC 工具 | 执行算子和模型测试。CANN 位于镜像内，宿主提供兼容 Ascend 驱动及设备；不挂宿主 Python 包目录 |

本次下载量约为 Control 123 MB、CPU 60 MB、NPU 5.94 GB，具体取决于已有层缓存。NPU 镜像展开后约 16.1 GB，不能按压缩下载量估算磁盘需求。这不是承诺为 4 GB 的精简镜像。

| 使用场景 | 必需镜像 | 运行服务数 |
| --- | --- | --- |
| 仅监控 | Control | 3：catmonitor、web、dfee |
| 监控 + CPU | Control + CPU | 4 |
| 监控 + NPU | Control + NPU | 4，无需下载 CPU 镜像 |
| 监控 + CPU + NPU | Control + CPU + NPU | 5 |

统一调用链：CLI/Web → `/run/catmonitor/control.sock` → 唯一 daemon Controller → Docker executor → workload executor。Web/DFeE 不挂 Docker socket。

## 2. 获取配套源码与镜像

以下命令在目标 Linux 节点的 **Bash 同一会话**执行。使用 root 或具有相应目录与 Docker 管理权限的账号。需要 Docker Engine、Compose v2、Git；外部 JSON 配置工具额外需要 Python 3。已取得镜像无需重新编译。

### 2.1 源码

使用新的目录，不覆盖已有部署源码：

```bash
git clone -b codex/npu-model-a3-migration \
  https://github.com/spike677/CATMonitor.git CATMonitor-a2-guide
cd CATMonitor-a2-guide
git checkout --detach 5a3537cfc0cd1420c5e63bb4991e72c832781eca
git rev-parse HEAD
git status --short
```

本指南和 PPT 属于后续文档提交；checkout 上述构建基线后新文档可能不在目录中，请保留已下载文档或在 GitHub 查看。部署脚本以这个确定的代码提交为准，不混用任意最新源码与旧镜像。

### 2.2 下载

```bash
R=ghcr.io/spike677
T=arm64-v0.3.6-a2-5a3537cfc0cd
CT=arm64-candidate-5a3537c-20261014
CONTROL="$R/catmonitor-npu:$T"
CPU="$R/catmonitor-stress-cpu:$CT"
NPU="$R/catmonitor-stress-npu:$T"

docker pull "$CONTROL"
docker pull "$CPU"
docker pull "$NPU"
docker image inspect "$CONTROL" "$CPU" "$NPU" \
  --format '{{.RepoTags}} {{.Os}}/{{.Architecture}} {{.Id}}'
```

三张镜像均应为 `linux/arm64`。CPU 镜像使用独立 candidate tag，不能把三张 tag 强行写成同一个值。

| 镜像 | 预期 Image ID |
| --- | --- |
| Control | `sha256:65ea0e1a39b191300f5c1af7c3ebafbc36c33b6a74fc8f393c7c764f0679bb33` |
| CPU | `sha256:b3e5748d1e8b6451b057574d032d8cce6cfb794e2ff86cf125c3efd55c803b03` |
| NPU | `sha256:441578d7c49c3773a86a0625b6a1f99fd517668ffb905d822bc462dbfd799735` |

为避免 tag 日后变化，可改用以下已核对的不可变 digest：

```bash
CONTROL=ghcr.io/spike677/catmonitor-npu@sha256:e12c566bb953c1fcfb532a26c5c3001afef95520117a04247990a726dd8c3982
CPU=ghcr.io/spike677/catmonitor-stress-cpu@sha256:9b80439eab43b502a6db7bb8bc6183405e858f7dbf943f7db1dc7b5b3412844c
NPU=ghcr.io/spike677/catmonitor-stress-npu@sha256:f63e6072de5abf5e2113da9c1ff72165eeef2985fff6366145c6f56a9479417b
docker pull "$CONTROL"
docker pull "$CPU"
docker pull "$NPU"
```

若仓库要求认证，使用管理员自己的凭据通过 `docker login ghcr.io -u <账号> --password-stdin` 输入。不要把 PAT 写进本指南、脚本、Git、命令行参数或日志。

离线环境可在获准联网节点用 **tag 形式**的三个变量执行：

```bash
docker save -o catmonitor-a2-images.tar "$CONTROL" "$CPU" "$NPU"
# 将 tar 传到目标节点后：
docker load -i catmonitor-a2-images.tar
docker image inspect "$CONTROL" "$CPU" "$NPU" \
  --format '{{.RepoTags}} {{.Os}}/{{.Architecture}} {{.Id}}'
```

`docker save/load` 不应被当成 registry digest 持久化机制；离线方式使用 tag，并核对 Image ID。tar 文件不进入 Git。

## 3. 部署前管理员检查

```bash
uname -m
docker version
docker compose version
npu-smi info
ls -l /dev/davinci[0-9]*
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
ss -lntp
docker info --format '{{.DockerRootDir}}'
df -h / /home
```

确认架构为 aarch64，Ascend 驱动可用，镜像所在 Docker data-root 空间足够。容器内有 CANN 不代表任意宿主驱动都兼容。

首次启动前检查端口 `19320/19322/19323/9333` 和固定 workload 容器名 `catmonitor-stress-cpu`、`catmonitor-stress-npu`。若已经占用，先确定所属部署，不执行删除或停止命令。**Compose 项目名不能隔离 host network 的端口，也不能隔离显式 `container_name`。** 本文命令用于新的空闲部署位置；替换现有服务需维护窗口。

生成器检查以下宿主资源：

```bash
ls -ld /usr/local/Ascend/driver/lib64 /usr/local/dcmi
ls -l /usr/local/Ascend/driver/version.info /etc/ascend_install.info \
  /usr/local/bin/npu-smi /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc
```

监控 overlay 另使用 `/usr/local/Ascend/nnae`、`/usr/local/Ascend/ascend-toolkit`、`/usr/bin/hccn_tool`、`/usr/local/sbin/npu-smi`。两处 npu-smi 路径用途不同，均需核实；不通过创建空文件或空目录伪装依赖存在。实际安装路径不同应先审查本地 override 和节点依赖，不能盲目 `up`。

当前 NPU 空闲门禁保守地检查整机业务进程。`busy` 阻止启动 NPU workload，不阻止 clone、pull、生成配置。不要杀业务，也不要关闭空闲门禁以通过 doctor。

## 4. 生成配置并用 Compose 启动

下面是 Full 五服务示例。首次执行用新输出目录；已有同名配置不要直接 `--force` 覆盖。

### 4.1 管理员选卡与授权

| 层次 | 参数/字段 | 含义 |
| --- | --- | --- |
| 宿主映射 | `--npu-device-nodes` | 宿主 `/dev/davinciN` 的 N；默认动态发现 |
| 运行时范围 | 拓扑及 `ASCEND_RT_VISIBLE_DEVICES` | 容器逻辑设备索引，需要 runtime preflight 核实 |
| Controller 授权 | `--npu-allowed-devices` | 允许 CLI/Web 请求的 logical ID，不是设备隔离机制 |
| 部署默认选卡 | `--npu-burn-device` | 未显式指定本次设备时使用的默认值，必须在授权范围内 |
| 当前 Job | `--npu-devices` 或 Web 勾选 | 本次作业参数，不改共享 YAML |

开源 A2 示例节点的宿主设备为 `/dev/davinci2,/dev/davinci5`，已验证的运行时逻辑编号为 `0,1`。**不能把 2、5 直接填入 logical allowlist，也不能推断所有机器都有这组映射。** 其他节点先核实实际拓扑，下面 `0,1` 仅适合已确认双卡映射的节点。

`full + legacy-privileged` 沿用本次 A2 runc 契约，workload 是高权限容器。allowlist 限制 Controller 请求，不会把 privileged 变成设备隔离。严格单设备隔离需要 `single + restricted` 及独立拓扑证明，不能仅删掉数量检查，详见 [NPU 算子指南](NPU_OPERATOR_GUIDE.md)。

### 4.2 完整生成命令

```bash
G=/etc/catmonitor/a2-stress
OUT=/var/lib/catmonitor/npu-output
install -d -m 0750 "$G" "$OUT" /var/lib/catmonitor/stress

bash scripts/stress/generate_stress_deployment.sh \
  --output-dir "$G" --control-image "$CONTROL" \
  --cpu-image "$CPU" --npu-image "$NPU" \
  --stream-threads 1 \
  --hpl-profile small --hpl-processes 1 --hpl-threads 1 \
  --hpcg-processes 1 --hpcg-threads 1 \
  --hpcg-nx 32 --hpcg-ny 32 --hpcg-nz 32 --hpcg-runtime 60 \
  --npu-chip-generation A2 --npu-runtime runc \
  --npu-device-mode full --npu-security-profile legacy-privileged \
  --npu-burn-device 0 --npu-allowed-devices 0,1 \
  --npu-run-case matmul --npu-threads 1 \
  --npu-output-dir "$OUT" \
  --npu-ascend-env-script /usr/local/Ascend/cann-8.5.1/set_env.sh \
  --npu-allowed-models gpt3,llama2 \
  --allow-npu-reference-generation \
  --npu-model-memory-mode checkpointed \
  --enable-web
```

这里只生成配置，不启动压力任务。`checkpointed` 显式启用激活重计算，不自动缩小模型形状，也不保证任意参数能在当前 HBM 中运行。30 分钟是默认作业上限；需要长任务时管理员显式加 `--npu-job-timeout 12h`，这不表示一定运行 12 小时。

仅 NPU：省略 `--cpu-image` 及 CPU sizing 参数，后续只启用 `stress-npu` profile。仅 CPU：省略 NPU image 和所有 NPU 参数，只启用 `stress-cpu`。生成器至少要求一种 workload；仅监控不使用此生成器。

### 4.3 Compose 组合

```bash
export CATMONITOR_IMAGE="$CONTROL"
export CATMONITOR_WEB_ADDR=:19322

dc() {
  docker compose -p catmonitor-a2 \
    -f docker/docker-compose.yml \
    -f docker/docker-compose.npu.yml \
    -f docker/docker-compose.stress.yml \
    -f "$G/docker-compose.stress.generated.yml" \
    --profile stress-cpu --profile stress-npu "$@"
}

dc config --services
dc config
```

应包含 `catmonitor`、`web`、`dfee`、`catmonitor-stress-cpu`、`catmonitor-stress-npu`。前者是 service 名，不保证实际容器名就是 `catmonitor`；后续使用 `dc exec` 避免名称混淆。

生成文件是 overlay，不能单独 `-f generated.yml`。`--control-image` 记录生成身份，Control 实际镜像还需 `CATMONITOR_IMAGE`。两个 workload 属于 profiles，缺少 profile 不代表 NPU overlay 把服务删了。合并前后以 `config` 为准。参见 Docker [多文件合并](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/) 和 [profiles](https://docs.docker.com/compose/how-tos/profiles/)。

核对最终 image、挂载、devices、环境变量和权限后启动：

```bash
dc up -d
dc ps
dc exec -T catmonitor catmonitor stress doctor \
  -c /etc/catmonitor/catmonitor.yaml -o table
curl -fsS http://127.0.0.1:19320/-/ready
curl -fsS http://127.0.0.1:19322/api/stress/config
curl -fsS -o /dev/null http://127.0.0.1:19323/
```

Full doctor 目标为 stream/hpl/hpcg/npu_burn 四项通过。还需确认 NPU CANN 环境、torch_npu、PCI 拓扑及实际 logical IDs。**doctor PASS 只说明当前预检通过，不等于所有算子、所有 shape 或模型训练实机通过。** 直接调用 workload describe 时应加 `--require-pass`，或检查 JSON 的 `preflight.status`；不能只看进程返回 0。

数据保留：监控 snapshot/data/csv 为项目命名卷；Controller history 位于 `/var/lib/catmonitor/stress` 的宿主绑定目录；NPU CSV 位于 `$OUT`；模型参考位于 NPU state 卷中的 `/var/lib/catmonitor/stress/model-references`。不要用 `down -v` 做日常更新。

## 5. 设备、算子和 tensor 参数

### 5.1 本次作业选卡选算子

确认授权和空闲后才执行以下真实压测命令：

```bash
npu-smi info
dc exec -T catmonitor catmonitor stress run \
  --bench npu_burn --npu-devices 0,1 --npu-cases matmul,conv2d \
  -c /etc/catmonitor/catmonitor.yaml -o table
dc exec -T catmonitor catmonitor stress status -o table
```

`--npu-cases` 只能选择当前镜像准入通过的算子。A2 的 `quant_matmul` 缺少上游策略，不能改 batch 或套用 A3/A5 策略绕过。GPT3/Llama2 走独立模型入口，不属于算子选项。

不传新的设备/算子字段时沿用部署默认；显式空选择不会扩大成全设备。Web 的“全选”只应选择已授权设备，仍须确认空闲。取消始终按 Job ID：

```bash
JOB_ID='<实际 Job ID>'
dc exec -T catmonitor catmonitor stress cancel --job "$JOB_ID"
dc exec -T catmonitor catmonitor stress status --job "$JOB_ID" -o json
dc top catmonitor-stress-npu
```

等待任务进入终态，并确认训练/Burn 进程及子进程退出；保留空闲入口进程是正常的。不要按全机进程名 kill，也不要取消其他业务。

### 5.2 管理员切换外部配置

这是“不重编镜像的只读配置挂载”，**不是运行中 Job 的原子热更新**。可保存多套命名配置目录，由管理员在生成器选择；当前没有按产品型号自动选择最优参数的功能。

先从当前 workload 复制完整配置目录作为基准，不修改镜像或 Python 源码：

```bash
PROFILE_ROOT=/etc/catmonitor/npu-config-profiles
install -d -m 0750 "$PROFILE_ROOT"
# image-default 必须是新目录，避免覆盖已有基准。
dc cp catmonitor-stress-npu:/opt/catmonitor/npuburn-python/ascend_npu_burn/config \
  "$PROFILE_ROOT/image-default"

python3 scripts/stress/npu_config_profile.py \
  --source-dir "$PROFILE_ROOT/image-default" \
  --output-dir "$PROFILE_ROOT/a2-smoke-v1" \
  --batch-size 1 --num-warmup 2 --run-count 10
python3 scripts/stress/npu_config_profile.py \
  --validate-dir "$PROFILE_ROOT/a2-smoke-v1"
```

此工具只改 A2 GPT3/Llama2 的指定模型参数，保留完整 `a3_config.json`，不会为任意算子自动调参。这个小步数示例是配置用法，不是新的硬件 PASS。仓库还提供 [A2 batch32 preset](../configs/stress/npu-model/README.md)，其历史结果同样不能替代新节点验收。

算子的 `tensor shape`、`dtype`、`pattern`、`run_count` 应由管理员在独立副本的实际 case 字段中调整，保留原结构与完整两个 JSON 文件。不同算子字段不同，不凭空添加 `exec_count`，不替换不支持的 dtype。用校验工具检查后，在第 4.2 节完整命令中增加：

```bash
--npu-config-dir /etc/catmonitor/npu-config-profiles/a2-smoke-v1
```

以上是附加参数片段，不是独立 Shell 命令。完整目录只读挂载到 `/opt/catmonitor/npuburn-python/ascend_npu_burn/config`；Web 展开 tensor 详情显示当前有效配置，历史报告保留本次 Job 使用的参数。

更新流程：先停止接收新任务并等待无活动 Job；备份旧 `$G`；以完整参数输出到新的 `G_NEW`；核对新 `dc config` 后切换 `$G` 并仅重建受影响服务。模型参数、运行栈或 memory mode 改变后重新做参考匹配检查，不能继续强用旧参考。

### 5.3 CPU 参数

| 目的 | generator 参数 |
| --- | --- |
| STREAM 单线程 | `--stream-threads 1`；0 表示不设置 OMP 线程数 |
| 小规模 HPL | `--hpl-profile small --hpl-processes 1 --hpl-threads 1` |
| 显式 HPL 网格 | `--hpl-n 4096 --hpl-nb 256 --hpl-p 1 --hpl-q 1 --hpl-processes 1` |
| HPCG 规模/目标时间 | `--hpcg-processes 1 --hpcg-threads 1 --hpcg-nx 32 --hpcg-ny 32 --hpcg-nz 32 --hpcg-runtime 60` |

HPL 的 `P × Q` 必须等于 MPI ranks。只设置 `--hpl-processes 1` 而保留镜像中 `P=4,Q=2` 的 HPL.dat 会预检失败。N/NB/P/Q 显式配置须四项成组；HPCG 参数独立。作业超时和程序目标运行时间不是同一个概念。

## 6. Web 算子操作与报告

浏览器打开 `http://<节点IP>:19322/stress/`；健康概览为 `:19322/`，DFeE 为 `:19323/`。节点可路由且监听/防火墙允许时不需要 SSH 隧道。开源演示的 `:5001` 是该环境访问入口，不是产品固定端口。

当前 `:19322` 的操作 API 尚无认证/RBAC，只允许可信网络。若需要更换 Web 端口，设置 `CATMONITOR_WEB_ADDR=:5001`，确认空闲后仅重建 `web`。当前 host network 下不使用 `ports: 5001:19322` 做映射。不要同时重启 Controller 或 workload 来改 Web 端口。

操作步骤：

1. 选择 NPU Burn 和获准的 logical 设备，确认业务空闲。
2. 在算子区勾选本次算子，展开“已选算子的 tensor 参数（只读）”，核对 shape/dtype/pattern/run_count。
3. 点击“开始压测”并确认。Controller 会再次预检；CLI 与 Web 查看同一 Job。
4. 完成后核对实际设备、算子、当前 Job CSV 覆盖及 `err_count=0`；请求与结果不一致不能判总体通过。
5. 需要停止时取消当前 Job，确认报告终态及进程回收。

报告中的“420/420 用例通过”表示 **420 条 CSV 用例记录**，不是 420 个算子、420 张卡或 run_count。累计用例时间是 CSV 时间之和；作业耗时包含预检、启动和收尾。预检通过、历史运行通过、当前设备可用是三个不同状态。

PPT 的算子截图是 2026-10-13 的历史 Job：matmul、logical 0/1，各 210 条记录，总 420/420、错误 0，耗时 1.99 分钟；截图日期为 2026-10-14，不能当成当天新镜像全套验收。

## 7. Web 生成参考和执行模型 SDC

### 7.1 管理员授权

生成器参数对应 `catmonitor-stress.yaml` 的 `stress.benchmarks.npu_burn`：

```yaml
allowed_npu_devices: [0, 1]
allowed_npu_models: [gpt3, llama2]
allow_npu_reference_generation: true
```

缺省不授权模型，不授权参考生成。授权参考生成意味着允许创建新的检测基准；应限于可信管理员。普通算子 doctor PASS 不能替代本次模型依赖/HBM/参考匹配预检。

### 7.2 首次生成参考

1. 进入 `/stress/`，选择 NPU Burn，切换到“模型 SDC”，选 GPT3 或 Llama2。
2. 展开“首次使用：准备参考”，点“切换到生成参考（单卡）”。**切换模式本身不运行训练。**
3. 选择一张获准、空闲、已确认健康的逻辑设备。填写新的参考 ID，例如 `llama2-a2-baseline-01`，已有 ID 不覆盖。
4. 点“预检本次选择（不训练）”。参数、设备、参考 ID 改变后重新预检；页面只列本次未通过项，不把“参考缺失”写成“模型不支持”。
5. 预检通过后点主按钮“生成参考”并确认。这一步是真实模型运行，会使用 NPU。
6. 报告必须满足 `outcome=reference_generated`、`saved_steps=expected_steps`、错误为 0。目录/文件存在不是通过条件；失败或取消留下的 staging 不能当有效参考。

参考存于 `CATMONITOR_MODEL_REFERENCE_ROOT=/var/lib/catmonitor/stress/model-references` 的持久化 state。它是固定参数和运行环境的 SDC 标准结果，不是预训练模型权重。首次参考并不天然正确，应在已确认健康的环境生成并独立重复对照，避免把稳定硬件错误写入基准。

### 7.3 使用参考执行 SDC

1. 切回模型 SDC 对照模式，选择同一模型，填写已完成生成的 reference ID。
2. 选择本次获准设备（可多卡），核对当前模型参数、软件栈和 memory mode 与参考身份匹配。
3. 再点只读预检，通过后点“开始 SDC 检测”。参考不匹配时应重新生成匹配参考，不能修改哈希绕过。
4. 最终必须为 `outcome=sdc_passed`，每个请求设备都有完整 `checked_steps`、错误 0，实际设备和 Job CSV 与请求一致。

该候选多设备模型测试为逐设备顺序训练/比较，不代表跨卡分布式训练，也不能把两卡显存相加估算单设备模型容量。对照报告的 `saved_steps=0` 可以正常：它在读取参考并比较，而不是再次生成参考。

PPT 的 Llama2 截图来自 2026-10-13 的 Web 历史对照 Job：logical 0/1，比较 72 步，错误 0，激活重计算。它不证明任何其他参数、A3 或新节点已通过。

### 7.4 等价 CLI 与参考检查

以下是真实任务命令，**不要与 Web 重复提交同一个测试**：

```bash
# 第一次：单卡生成新的参考。
dc exec -T catmonitor catmonitor stress run \
  --bench npu_burn --npu-devices 0 \
  --npu-model llama2 --model-action create_reference \
  --reference-id llama2-a2-baseline-01 \
  -c /etc/catmonitor/catmonitor.yaml -o json

# 仅在参考生成成功后，对照同一模型和配置。
dc exec -T catmonitor catmonitor stress run \
  --bench npu_burn --npu-devices 0,1 \
  --npu-model llama2 --model-action compare \
  --reference-id llama2-a2-baseline-01 \
  -c /etc/catmonitor/catmonitor.yaml -o json

dc exec -T catmonitor-stress-npu \
  ls -lah /var/lib/catmonitor/stress/model-references
```

GPT3 替换 `--npu-model` 并使用独立参考 ID。`case_catalog` 中 GPT3/Llama2 的 `selectable=false` 只表明它们不作为算子选项，不能据此判断模型不可运行或参考缺失。

## 8. 管理员开启与关闭压测

### 8.1 开关层级

| 需求 | 配置或操作 | 实际作用 |
| --- | --- | --- |
| 开启全部 Stress Controller | `stress.enabled: true` | 建立唯一 Controller；仍需各 benchmark enabled 和实际 workload |
| 关闭全部 Stress | `stress.enabled: false` 并重建 daemon | 不再启动 Stress Controller；监控配置保持原样 |
| 开/关 NPU | `stress.benchmarks.npu_burn.enabled` | 控制算子及模型的 NPU 请求准入，不影响 CPU 项目 |
| 开/关 CPU | stream/hpl/hpcg 各自 `enabled` | 控制对应 CPU 项目 |
| 调整允许设备 | `allowed_npu_devices` | 限定本次作业 logical ID；不等于物理设备隔离 |
| 开/关模型 | `allowed_npu_models` | 空列表禁模型，算子仍可运行 |
| 仅关闭新参考生成 | `allow_npu_reference_generation: false` | 已有匹配参考仍可用于 compare |
| 显示/关闭 Web 运行入口 | `stress.web_enabled` | 当前版本的页面能力开关，**不能当作后端安全隔离** |
| 停止当前任务 | `stress cancel --job ID` | 只取消指定 Job，不改变以后是否允许压测 |

**当前实现限制：**在 `5a3537c` 中，`web_enabled` 参与 config 响应和前端按钮状态，但 Web mutation handler/Controller 未完整地将它作为后端权限检查。不要声称 `web_enabled=false` 已阻止所有 HTTP Run/Cancel。需要硬禁压测时使用对应 benchmark 或全局 `stress.enabled=false`；需要保留 CLI 而阻止 Web 写接口时，须用已审核的网关方法/路径访问控制或暂时停止 Web，不能仅依靠此字段。本指南不修改实现。

### 8.2 所有变更前先清空活动任务

在维护窗口限制新的操作请求，再执行：

```bash
dc exec -T catmonitor catmonitor stress status -o table
# 如有活动 Job，使用真实 ID 取消；无活动任务就不要执行这一条。
dc exec -T catmonitor catmonitor stress cancel --job '<活动 Job ID>'
dc exec -T catmonitor catmonitor stress status --job '<活动 Job ID>' -o json
dc top catmonitor-stress-cpu
dc top catmonitor-stress-npu
```

确认终态、相关进程清理完成后再重建 Controller/执行面。不能用重启 Controller 代替 Cancel，也不能在活动任务中改配置或参考。

### 8.3 只关闭 NPU，保留 CPU 与监控

以下 `sed` 只适用于本版本生成器的单行 `npu_burn: { ... }` 格式；自定义多行 YAML 请用编辑器精确修改同一字段。先备份当前生效配置：

```bash
CFG="$G/catmonitor-stress.yaml"
cp -p "$CFG" "$CFG.before-npu-disable.$(date +%Y%m%dT%H%M%S)"
sed -i '/^    npu_burn:/s/enabled: true/enabled: false/' "$CFG"
grep '^    npu_burn:' "$CFG"
# 确认该行确实为 enabled: false 后再继续。
dc config --quiet
dc up -d --no-deps --force-recreate catmonitor
dc stop catmonitor-stress-npu
dc exec -T catmonitor catmonitor stress doctor \
  -c /etc/catmonitor/catmonitor.yaml -o table
curl -fsS http://127.0.0.1:19322/api/stress/config
```

NPU 应显示 disabled，CPU 三项仍可用，Monitoring 继续采集。Controller 重建有短暂监控中断，应安排维护窗口。`dc config` 只验证 Compose，不能证明应用 YAML 语义正确；必须检查容器状态/日志、doctor 和 API。

再次开启 NPU：确认空闲和授权仍正确，将同一行改回 true，再启动 workload 和 Controller：

```bash
sed -i '/^    npu_burn:/s/enabled: false/enabled: true/' "$CFG"
grep '^    npu_burn:' "$CFG"
dc up -d --no-deps catmonitor-stress-npu
dc up -d --no-deps --force-recreate catmonitor
dc exec -T catmonitor catmonitor stress doctor \
  -c /etc/catmonitor/catmonitor.yaml -o table
```

只去掉 `--profile stress-npu` 不会自动停止已运行容器，也不会同步修改 Controller 授权。只 stop workload 而不禁用配置，会得到“容器未运行”的预检失败，而不是管理员已关闭状态。后续全量 `dc up -d` 可能再启用被 stop 的 profile 服务；配置禁用应保留。

### 8.4 关闭全部 Stress，保留监控页面

先完成 8.2，备份后只在 `stress` 段修改全局开关：

```bash
CFG="$G/catmonitor-stress.yaml"
cp -p "$CFG" "$CFG.before-stress-disable.$(date +%Y%m%dT%H%M%S)"
sed -i '/^stress:/,$s/^  enabled: true$/  enabled: false/' "$CFG"
sed -n '/^stress:/,$p' "$CFG"
dc up -d --no-deps --force-recreate catmonitor
dc stop catmonitor-stress-cpu catmonitor-stress-npu
curl -fsS http://127.0.0.1:19320/-/ready
curl -fsS http://127.0.0.1:19322/api/stress/config
```

API 应为 `enabled=false`、`available=false`；Stress 静态页面仍可访问，不代表 Controller 已启用。snapshot/collector 配置不变。恢复时将 **stress 段**的 `enabled` 改回 true，再启动需要的 workload、重建 daemon 并 doctor；不要误改 `snapshot.enabled` 或各 collector。

这是功能停用，当前 Compose 的 Docker socket 挂载仍存在。长期 Monitoring-only 如需同时移除 Docker socket，空闲窗口内改用仅 base+npu 两份 Compose 文件（同一 `-p catmonitor-a2`），核对镜像内监控配置后重建 daemon；不加入 stress overlay，也不删数据卷。自定义采集配置先按原 Monitoring 配置 overlay 保留，不能静默退回默认值。

### 8.5 模型、参考和 Web 的管理

管理员在 `$CFG` 中编辑 `stress.benchmarks.npu_burn`，保留其他配置：

- 仅允许 Llama2：`allowed_npu_models: [llama2]`。
- 不允许模型：`allowed_npu_models: []` 且 `allow_npu_reference_generation: false`。
- 只允许已有参考对照：保留模型列表，设置 `allow_npu_reference_generation: false`。
- 开放参考生成：设置为 true，且需已授权模型、健康单卡和维护窗口。
- 更改设备授权：修改 `allowed_npu_devices`，同时确保默认 `NPU_BURN_DEVICE` 在新的范围内；如需修改默认值，应重新生成完整配置并重建 NPU workload，不只改网页。

可用 `vi "$CFG"` 编辑；完成 8.2 后，用 `dc up -d --no-deps --force-recreate catmonitor` 应用，再从 `/api/stress/config` 核对 `model_capabilities` 与 allowed devices。YAML 不自动热加载。

仅关闭页面运行入口，可在 `stress` 段设 `web_enabled: false` 并重建 daemon；保留第 8.1 节的安全限制。改变 Web 监听地址则重建 Web：

```bash
export CATMONITOR_WEB_ADDR=:5001
dc config
dc up -d --no-deps --force-recreate web
curl -fsS http://127.0.0.1:5001/stress/ >/dev/null
```

临时硬停止 Web（CLI/监控 daemon 不停）可以执行 `dc stop web`，此时监控 Web 也不可访问。重新 `dc up -d --no-deps web` 恢复；DFeE 是独立服务。

手工维护开关后，原 `stress-deployment-manifest.json` 的哈希仍描述生成时输入，不再代表已修改的 live YAML。保存管理员变更记录及当前配置校验和；不要伪称旧 manifest 仍匹配。后续重生成配置时复核这些开关，避免不经意重新授权。

## 9. 更新、回滚与常见问题

只改配置不需要 build/push 镜像，也不应在运行容器 `pip install` 或覆盖 Python/wheel。软件变更使用带新身份的受审镜像，与完整源码/兼容 profile 匹配。

更新前记录并备份：

```bash
dc exec -T catmonitor catmonitor stress status -o table
BACKUP=/var/lib/catmonitor/deployment-backups/$(date +%Y%m%dT%H%M%S)
install -d -m 0700 "$BACKUP"
cp -a "$G" "$BACKUP/generated"
dc config > "$BACKUP/compose.resolved.yaml"
dc ps -a > "$BACKUP/containers.txt"
docker image inspect "$CONTROL" "$CPU" "$NPU" > "$BACKUP/images.json"
```

配置更新输出新目录，保留旧目录供回滚。不要把含本地路径的备份或运行证据上传 Git。完成空闲检查、切换 `$G` 并 `dc config` 后，仅重建受影响服务：

```bash
# 示例：NPU 环境/外部配置与 Controller 授权一起变化。
dc up -d --no-deps --force-recreate catmonitor-stress-npu catmonitor
dc exec -T catmonitor catmonitor stress doctor \
  -c /etc/catmonitor/catmonitor.yaml -o table
```

只有 CPU sizing 变化则重建 CPU workload；Web 端口变化只重建 Web。回滚使用原镜像 ref、原 `$G` 和原配置路径；如果原目录曾原地修改，先恢复已备份的文件到原路径。重新 inspect/config 后重建相应服务，不移除 snapshot/history/model reference 卷。生成 overlay 内含绝对路径，仅把备份目录复制到新路径不会自动改正其中的挂载。

| 现象 | 检查和处理 |
| --- | --- |
| `service catmonitor has neither an image nor a build context` | 不要单独加载 generated overlay；使用第 4.3 节完整组合 |
| `config --services` 没 workload | 检查 stress 文件、两个 profile 和 generated 文件路径；不凭此删除 npu overlay |
| HPL doctor 网格不匹配 | `P×Q` 对齐 ranks；用 small 或完整四个维度，不能只改进程数 |
| 页面能打开但无法 Run | 核对 `stress.enabled`、`web_enabled`、benchmark.enabled、control socket、workload 状态；不是镜像 pull 成功就部署成功 |
| NPU busy | 等授权空闲窗口；不关闭门禁或杀业务 |
| 模型 reference 缺失/不匹配 | 根据本次模型预检处理；允许时在健康单卡生成新的匹配参考 |
| 模型 OOM | 调整独立配置或显式 memory mode，重新匹配参考；两卡显存不能直接合并 |
| API HTTP 200 但预检失败 | 检查 JSON `status`/`preflight.status` 和失败列表，不能仅按 HTTP 成功判 PASS |
| `web_enabled=false` 后按钮隐藏 | 这是 UI 状态，不是已完成鉴权；硬禁用按第 8 节处理 |

## 10. 进一步阅读

- [NPU 部署 README](README-npu.md)：Monitoring 与手工 docker run 路径。
- [模型 SDC 设计与配置](NPU_MODEL_SDC_GUIDE.md)：参考身份、模型参数和限制。
- [NPU 算子指南](NPU_OPERATOR_GUIDE.md)：设备映射与兼容边界。
- [A3 迁移指南](NPU_A3_MIGRATION_GUIDE.md)：A3 使用对应软件栈并重新生成参考，不能直接替换成本文 A2 镜像。
- [开发者指南](DEVELOPER_GUIDE.md)：构建和镜像发布；普通使用者无需执行。

本文没有重新运行负载。PPT 截图是开源 A2 历史作业；新节点仍应完成实际映射 → doctor → 算子短任务 → 健康单卡生成参考 → SDC 对照 → Web/CLI 同一作业 → Cancel 清理验收。
