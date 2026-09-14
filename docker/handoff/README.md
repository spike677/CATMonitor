# Claude 独立部署与操作验收交接

本目录是可公开的独立验收资料，不是安装器，也不是已完成验收的证明。
交接者固定输入并盘点现场；Claude 亲自按指南生成配置、创建容器和执行检查。
交接者不能先把环境部署好，再让 Claude 复查结果。

## 文件与使用顺序

1. 本文：职责、版本、环境补全、权限和验收边界。
2. [冻结操作指南](guide/README-npu.md)：Monitoring / CPU / NPU 的完整手工命令。
3. [身份清单模板](identity.template.json)：交接者在 Git 仓库外填写节点实例。
4. [Claude 起始提示词](CLAUDE_START_PROMPT.md)：开始独立执行。

节点地址、SSH 密钥路径、Docker endpoint、保护对象清单和资源窗口只放在
**仓库外的私有环境附录/identity.json**。不要提交 PAT、密码、私钥、Docker auth、
业务进程参数、实际节点配置、运行报告或验收 evidence。

本公开目录不包含某台机器的实时盘点。模板内的 null/NOT_CHECKED 不是通过。
Claude 必须拿到管理员补全的环境附录，才能连接或部署。
若缺少，停止并索取，不能从历史聊天猜默认 socket 或主机地址。

## 1. 固定版本，分开记录三个身份

| 项目 | 本次固定对象 |
|---|---|
| 部署源码 | c1821ca4fa2eec53eb2605dc263561c6076421d0 |
| 原操作指南 | manual-c1821ca-r1 |
| 本冻结指南 | manual-c1821ca-r2-handoff；公开副本仅调整链接与来源路径 |
| 已取得镜像标签 | arm64-v0.3.5-stress |
| 平台 | linux/arm64 |

镜像 ref / Image ID / registry digest 见模板的 expected_images。
这些是预期身份，交接者与 Claude 分别实际 inspect 后才能填写验证结果。
不要静默换成 latest、旧 a2-r1、官方其他版本或另一 RC。

源码基线、未提交指南修订、既有镜像必须分别记录。
没有重建镜像，不能声称镜像来自指南修订提交。
本任务验证“已有源码和镜像后从零创建容器”，不是空缓存下载。

允许的显式差异：
- ready/snapshot 限时轮询和 JSON 校验；
- NPU docker run 的 --init，对应 Compose init:true；
- 同机独立 Docker endpoint 的显式 socket bind 来源；
- 录制前 mkdir、尊重目录覆盖、daemon 后立即采样、首次 status 单独记录。

本目录保留完整指南是为了冻结独立验收输入，不建立第二套部署实现。
无需执行旧验收脚本。固定源码中的 generator 是唯一配置生成实现。
本任务只使用 Manual docker run，不运行 Full 或 Compose 部署。

## 2. 交接者只准备，不预部署

交接前只读核对：
- 远端源码 HEAD、工作树差异；
- 冻结指南路径、SHA256；
- Docker socket、DockerRootDir、真实 daemon PID/cmdline；
- daemon 与宿主的 network namespace；
- 镜像身份、测试容器/卷、当前轮 generated config/report；
- 磁盘、CPU/内存、NPU健康和业务占用；
- 所有禁止修改的正式/业务 daemon 及其容器身份。

只清理确认属于旧测试的残留，保留镜像、旧 evidence、源码和 data-root。
不要新建 daemon、复制大镜像、build/pull/save/load。
不要运行 generator、启动 CATMonitor、代跑 doctor 或 workload。

测试 endpoint 独立不等于 CPU、NPU、内存、端口隔离。
若与宿主共享网络，host-network 容器直接监听宿主端口；必须在实际 namespace 检查
19320/19322/19323/9333。不要使用旧 PID 或容器 PID 猜测 nsenter 目标。
当前正式容器数量只来自实际盘点，不使用历史数字。

准备完成后停止操作测试环境，不在 Claude 执行期间后台补配置、重启或代跑失败步骤。

## 3. 私有环境附录必须提供的字段

管理员复制 identity.template.json 到仓库外的 identity.json，填写：

- SSH 主机、用户、端口，已有授权配置或密钥路径（不包含密钥内容）；
- Claude 实际使用的终端：Windows PowerShell / WSL / Linux；
- TEST_ROOT、SOURCE_DIR、TEST_DOCKER_SOCKET、TEST_DOCKER_ROOT、
  TEST_DOCKER_CONFIG、init binary；
- 同机端口/namespace，以及浏览器所在机器的访问或 SSH 转发方式；
- 允许创建的测试容器/卷名称和本轮状态目录；
- 正式/业务 endpoint、目录、容器 ID、Image ID、StartedAt、状态；
- CPU/内存可用预算、NPU可用设备、维护窗口和授权限制；
- 实际盘点时间、镜像/源码/指南身份检查结果。

使用已有可信 SSH 配置，保留主机身份校验。不读取私钥内容、不放宽整个 .ssh 权限，
不在命令行或文档里放 PAT/密码。
交接者连接成功不代表 Claude 所在工具环境已连接成功。

Claude 第一个动作必须是**只读连接和身份复核**。
环境附录没有完整路径时，不能把下方变量当作已设置，也不能回退到默认 daemon。

每个新 SSH Bash 会话，包括 Cancel 终端 B，都重新设置：
```bash
# 以下四个变量的确切值来自私有环境附录；先逐一 export，再执行本块。
: "${TEST_ROOT:?missing private appendix TEST_ROOT}"
: "${SOURCE_DIR:?missing private appendix SOURCE_DIR}"
: "${TEST_DOCKER_SOCKET:?missing private appendix socket}"
: "${TEST_DOCKER_CONFIG:?missing private appendix Docker config}"

export CATMONITOR_TEST_ROOT="$TEST_ROOT"
export DOCKER_HOST="unix://$TEST_DOCKER_SOCKET"
export DOCKER_CONFIG="$TEST_DOCKER_CONFIG"
export CATMONITOR_DOCKER_SOCKET="$TEST_DOCKER_SOCKET"
cd "$SOURCE_DIR"
git rev-parse HEAD
git status --short
docker info --format 'root={{.DockerRootDir}} init={{.InitBinary}}'
docker ps -a --format '{{.ID}} {{.Names}} {{.Image}} {{.Status}}'
docker volume ls
```

对照填写后的 identity.json。开始时应0测试容器、0测试卷；
场景已启动后终端B不再断言0容器，但仍复核 endpoint 和同一 MANUAL_EVIDENCE。
身份不符停止，不自动切换或清理。

## 4. 资源条件与安装条件分开

分别记录：
```text
INSTALLATION_PREPARATION_READY=
CPU_LOAD_PERMISSION=
CPU_RESOURCE_AVAILABLE=
NPU_LOAD_PERMISSION=
NPU_RESOURCE_AVAILABLE=
RESOURCE_CHECK_TIME=
```

全局idle高不代表可以运行全核负载。
冻结README的 STREAM_THREADS=0 和按 nproc 计算的 HPL/HPCG 示例可能占用整个节点。
核对业务需求、CPU/内存预算、NUMA与HPL.dat的P×Q；不能把8 ranks或128CPU当通用常量。
Claude 应按README亲自读取当前CPU镜像内的HPL.dat。

NPU必须核对业务进程、设备范围和空闲窗口。容器隔离不允许抢占业务NPU。
NPU describe/healthcheck可能初始化设备，因此忙时不仅Burn，部署及预检也要暂缓。
不得停业务、kill worker、自行预约维护窗口，或偷偷缩参数后称原指南通过。

如无资源预算/窗口，标记 INSTALL_ONLY / PARTIAL_READY；
受影响步骤写 DEFERRED_RESOURCE_BUSY 或未确认原因。
受限smoke只能在明确预算和公开配置支持下，先记录指南变更再执行。

## 5. 本轮 evidence 与目录覆盖

身份门禁通过后，Claude 在附录指定 TEST_ROOT 内创建新证据目录：
```bash
export MANUAL_EVIDENCE="$CATMONITOR_TEST_ROOT/claude-results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$MANUAL_EVIDENCE"
printf 'MANUAL_EVIDENCE=%s\n' "$MANUAL_EVIDENCE"
```

只初始化一次。重连/终端B粘贴实际打印的同一路径，不重复运行 date 生成新目录。

同机独立测试必须在README第4节之前设置目录覆盖，不写正式/etc/catmonitor
或/var/lib/catmonitor。CPU阶段：
```bash
export CATMONITOR_GENERATED_DIR="$MANUAL_EVIDENCE/cpu-generated"
export CATMONITOR_STRESS_STATE_DIR="$MANUAL_EVIDENCE/cpu-state-live"
export CATMONITOR_NPU_OUTPUT_DIR="$CATMONITOR_STRESS_STATE_DIR/npu-burn-output"
```
NPU阶段在资源门禁通过后：
```bash
export CATMONITOR_GENERATED_DIR="$MANUAL_EVIDENCE/npu-generated"
export CATMONITOR_STRESS_STATE_DIR="$MANUAL_EVIDENCE/npu-state-live"
export CATMONITOR_NPU_OUTPUT_DIR="$CATMONITOR_STRESS_STATE_DIR/npu-burn-output"
```

之后 generator、设备映射、逐个 docker run 全部从冻结README执行，不靠上轮command.sh。
仅设置 DOCKER_HOST 不会改变容器 bind mount；CATMONITOR_DOCKER_SOCKET 同样必须正确。
不要把本节点附录的测试路径作为普通产品默认安装前提。

## 6. 独立执行路线

| 场景 | README章节 | 镜像 / 容器 | 必须区分的验证 |
|---|---|---|---|
| Monitoring | 1/2只读→3.2→3.3→9 | 1 / 3 | ready、JSON snapshot、collect/health、Web/DFeE/metrics、Stress disabled、无socket依赖 |
| CPU | 4/5.1→5.3→5.4→9 | 2 / 4 | 配置与部署、CPU doctor3/3、STREAM、共享job、HPL真实启动/Cancel、进程回收 |
| NPU | 资源门禁→6.1/6.2→6.4→6.5→9 | 2 / 4 | 动态映射、init/PID1、CANN/torch_npu/PCI预检、Burn CSV、同容器Cancel/回收 |

每次一条主要步骤：完整展示命令，再执行并记录结果。
不复用上一场景daemon/Web，仅增加workload并不等于已启用Controller。
每场景结束精确清理，最后零测试容器/卷，不追加Full或最终Monitoring部署。

### Snapshot

daemon docker run返回后立即采样，再继续Web/DFeE。
记录 StartedAt、采样开始、首次ready成功、首次有效snapshot观察时间。
分别报告daemon→snapshot、ready→snapshot、poll→成功；
这些是观察时间，受采样间隔影响，不是内部精确生成时间。
不能将数分钟后开始检查的0秒写成生成耗时0秒。
超时保存日志并停止，不固定sleep35或无限等待。

### 首次 status

全新state可能返回 no stress report / exit1，单独记录。
不能与doctor混为一条总PASS，也不能忽略其他非零退出码。
没有任务就没有job/CSV/错误计数，不填写0或PASS。

### 真实Cancel与NPU init

取消前核对本次新job_id、benchmark、running、开始时间和真实主进程/worker；
不能误用上一条任务ID。区分取消受理、任务终态和实际进程退出。

NPU --init/init:true已准备，但真实自然退出/Cancel僵尸回收仍需独立验证。
同一容器记录HostConfig.Init、实际PID1、PID/PPID/STAT、活跃worker和僵尸数。
中间不重启或删除容器来隐藏僵尸。进程检查工具失败不能作为零残留。
HPL只要求真实启动与取消，不要求重跑完整HPL/HPCG。

### Web

分别报告 HTTP_API_CHECK、VISUAL_UI_REVIEW、WEB_RUN_CANCEL_INTERACTION。
浏览器访问方式来自私有环境附录；本目录不预开隧道或页面。
没有工具或未实际操作就写NOT_PERFORMED。HTTP200不等于视觉/按钮验证。
:19322 Stress操作API尚无认证/RBAC，只向可信管理网络开放。
SSH转发是可选访问方式，不恢复第二Web或29592入口。

## 7. 清理与失败记录

清理前再次核对测试DockerRootDir、Container ID、卷引用及备份。
仅清理本轮在指定endpoint创建的资源。正式与业务对象即使已停止也受保护。
不prune、不删镜像/源码/data-root/旧evidence，不rm整个TEST_ROOT。
Cancel/reaping失败先留证并停止受影响步骤，不重建掩盖。

每步保存 command.sh、stdout.log、stderr.log、start.txt、end.txt、
exit-code.txt、observation.md。日志管道保留真实退出码。
对话与记录格式：
```text
[Step XX] 名称
目的：
执行位置：
指南章节：
实际命令：
真实退出码：
关键stdout/stderr：
观察现象：
判定及依据：
日志位置：
```

安全边界、资源占用、身份不符、端口冲突、磁盘不足、指南缺口或回收失败时，
暂停受影响步骤。成功后连续推进，不逐条等待交接者。
如需读实现才能补README缺失安装步骤，先报告README_GAP和首次失败。
允许只读诊断，不偷偷补mount/env/config或产品代码。

结果拆分为 FIRST_ATTEMPT_RESULT / DIAGNOSIS / DOCUMENTED_WORKAROUND /
RETEST_RESULT。不要把修补后的结果冒充原指南一次通过。
每场景分别输出 DEPLOYMENT / PREFLIGHT / WORKLOAD_RUN / STATUS / CANCEL /
PROCESS_REAPING / WEB_INTERACTION / CLEANUP。

交接者不得在后台协助修复；待独立问题清单出来后另行处理。
本轮不修改源码/version、不commit/push/tag、不build或重新下载已有镜像。
