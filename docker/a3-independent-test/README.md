# A3 新环境独立验证：必要补充

使用分支 `codex/a3-independent-handoff`，产品源码基于主仓
`main@c1821ca4fa2eec53eb2605dc263561c6076421d0`。本分支仅补充文档。

```powershell
git clone --branch codex/a3-independent-handoff --single-branch https://github.com/spike677/CATMonitor.git CATMonitor-A3-Test
cd CATMonitor-A3-Test
git rev-parse HEAD
git status --short
```

记录实际 HEAD，测试中不要自动更新。部署命令仍以
[Ascend README](../README-npu.md) 为准，不另建安装器。
交给 Claude 时使用 [起始提示](CLAUDE_START_PROMPT.md)。

## 新环境必须重新确认什么

| 必须项 | 为什么必须 | 未满足时 |
|---|---|---|
| SSH 连接及主机身份 | 新 Windows 不能沿用旧 A2 地址/密钥配置 | 不执行远端操作 |
| 源码 HEAD、镜像 ref/digest/Image ID、linux/arm64 | checkout 不会更新镜像；旧镜像不一定包含当前 V2 协议 | 不标记版本匹配 |
| 已有服务、容器、端口、卷和可用磁盘 | 防止覆盖正式 CATMonitor 或业务 | 不启动冲突实例 |
| A3 NPU 镜像兼容性 | A2 镜像不能因配置改为 A3 就自动兼容 | NPU 阶段延期 |
| CPU/内存预算、NPU 授权设备及空闲状态 | 同机测试会共享实际硬件资源 | 不运行未经授权负载 |
| CLI/Web、运行结果、取消后进程清理 | A2 的历史 PASS 不等于新 A3 环境 PASS | 按实际结果记录失败/未执行 |

节点地址、连接方式、目录、镜像和预算填写到仓库外的
[身份记录模板](identity.template.json) 副本中。不要提交密钥、PAT、节点配置或测试日志。

## 1. 先只读盘点

连接后检查主机和资源；再针对确认的 Docker endpoint 盘点容器及镜像：

```bash
hostname
uname -m
ss -lntp
df -h
nproc
cat /sys/devices/system/cpu/online
free -m
npu-smi info
find /dev -maxdepth 1 -type c -name 'davinci[0-9]*' -print
```

```bash
: "${REVIEW_DOCKER_SOCKET:?填写已确认的 Docker socket 绝对路径}"
docker -H "unix://$REVIEW_DOCKER_SOCKET" version
docker -H "unix://$REVIEW_DOCKER_SOCKET" info --format 'root={{.DockerRootDir}}'
docker -H "unix://$REVIEW_DOCKER_SOCKET" ps -a --no-trunc
docker -H "unix://$REVIEW_DOCKER_SOCKET" image ls --digests --no-trunc
```

另外确认宿主机直接运行的 CATMonitor/systemd 服务，以及现有容器 mounts、ID、
StartedAt；不能只看运行中的容器。该阶段不停止、删除、重命名任何既有资源。

## 2. 启动前必须处理的差异

- **端口隔离**：本基线 daemon 固定监听 `:19320`。host 网络下仅修改容器名或加
  `-p` 不能避让。若正式服务占用端口，先确认可用的隔离网络环境；不要编造
  `--metrics-port`。仅换 Docker socket/data-root 也不隔离端口。
- **镜像**：Control 要验证驱动/DCMI及 V2 CLI/Web；CPU 镜像要有 V2 执行入口和
  STREAM/HPL/HPCG；A3 NPU 镜像要核对 CANN、torch/torch_npu、custom ops、
  `lspci`/拓扑及 `catmonitor-stress-exec`。旧原生 NPU Burn 容器不等于 V2 workload。
- **配置与目录**：README 的容器名、卷、generated/state/output 路径必须与正式环境
  分离；Controller 的目标容器名和 Docker socket 挂载必须指向本次测试环境。
  Web/DFeE 不挂 Docker socket。
- **CPU**：按批准预算设置线程和问题规模；HPL 的 MPI ranks 必须匹配 `P×Q`。
  不把默认全线程运行视为已获许可。
- **NPU**：使用已验证的 A3 镜像，设置 `--npu-chip-generation A3`；选择一张
  已授权空闲的 logical ID，不能原样使用 A2 README 的 `all`。核对生成 profile
  的 host 节点、runtime visible ID、Burn logical ID，不假设相等或最多只有 8 个。
  `privileged` 不提供严格设备隔离，运行时观察实际使用设备；业务忙则延期，不杀业务。
- **进程回收**：NPU workload 使用 `--init` 前确认 Docker 支持且 init binary 可用；
  自然退出与 Cancel 后都检查进程及僵尸，不能通过重启容器隐藏残留。

在执行前展示实际展开的命令及上述替换值；缺参数或资源授权先停止该阶段，
不在独立验证中临时改产品代码、重编镜像或安装算子。

## 3. 最小验收顺序

1. Monitoring-only：3 容器；metrics、首次 snapshot、Web、DFeE；Stress 未启用。
2. CPU：4 容器；doctor 3/3、获准的 STREAM、CLI/Web 同一 job 可见、启动与取消清理。
3. NPU：4 容器；A3 环境/拓扑预检、获准单设备完整 CSV、错误数及真实 Cancel 清理。

每步保存实际命令、退出码和结果；CPU/NPU若无资源则记录延期。
HTTP/API成功、浏览器视觉检查、Web按钮实际操作分别记录。
清理只针对本轮创建且核对过 ID/endpoint 的容器和卷，保留镜像及证据；不测 Full。
开始和结束核对既有服务身份与状态。

当前 `:19322` 的 Run/Cancel 尚无认证/RBAC，只能开放给受控管理网络。

## 当前状态

文档已具备开始只读预检的必要说明；本次未连接目标 A3。
镜像兼容、隔离和资源条件仍待现场确认，**不等于已允许部署或开始 A3 压测**。
