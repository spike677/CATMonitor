# Claude 交接提示词：CATMonitor 从拉取到完整部署验收

将本文完整交给 Claude 执行。本文是验收任务，不是新的安装器或已通过的测试报告。
用户授权本轮测试环境内的拉取、部署、CPU/NPU 压测和清理；不授权修改生产环境。

## 1. 目标与执行边界

请模拟新用户，实际完成：

Git fresh clone → 固定源码 → GHCR pull/身份校验 → 配置生成 → Manual docker run →
Monitoring → CPU-only → NPU-only → Full → CLI/Web/负载/取消/回收验证 → 归档与清理。

成功步骤自动继续，不逐条等待用户复制命令。每一步先展示完整实际命令，执行后报告
关键输出、观察、结论和日志位置。不是只给建议，也不是一次性运行旧 acceptance 总脚本。

- 不 build/rebuild 镜像，不替换镜像里的二进制，不修改产品源码、版本、架构或上游源码。
- 不 commit/push，不创建 Git tag，不发布镜像，不自动安装或升级 Docker/Compose/驱动。
- 不恢复旧 Runner、benchmark_check.sh、catmonitor-install 或独立 Stress Web。
- 只能使用唯一 daemon Controller：CLI/Web → control.sock → Controller → docker exec → workload。
- Web 保留一个 listener :19322；Web/DFeE 不挂 Docker socket 或 workload 内部目录。
- 不停止、重启、重命名、删除已有正式容器或 vLLM/其他业务，不改变 Docker data-root。
- 不创建新 Docker daemon，不复制 Docker data-root，不执行 system prune 或批量删除历史镜像。
- 设备/CPU/内存正在被业务使用时，不抢占资源；只读检查和安全步骤可以继续，负载标记
  DEFERRED_RESOURCE_BUSY。需要维护窗口时说明具体占用，不为全绿杀业务。
- 出现 Cancel/回收失败、磁盘不足、端口冲突或文档外产品修复需求，停止受影响阶段并保存现场。
- SSH 地址、密钥、Docker endpoint、代理由用户本机安全提供；不从旧聊天复制 PAT 或硬编码节点。
  不把凭据、业务完整环境变量或代理认证 URL 写入报告。公开归档前对 inspect/logs 做脱敏。

本轮可以执行完整 HPL/HPCG/NPU workload，不再将仅 doctor 或启动/取消称为完整负载通过。
但 A2 结果不能外推为 A3/A5 或 NVIDIA GPU 验收。

## 2. 已知事实，不是实时结论

上一轮于 2026-09-09 完成：Monitoring 三容器、CPU 四容器、CPU doctor 3/3、Web 配置检查。
当时存在 vLLM 占用，STREAM/HPL/NPU workload 被暂缓。HTTP 200 不等于浏览器视觉审查。
测试资源结束时已清理；节点、进程、空间、镜像和登录状态必须重新盘点。

当前主开发工作树有未提交文档/测试修正。本交接分支**不包含那些未提交文件**，不能要求
新用户拿到它们，也不能把它们当作已进入源码基线的功能。第 6 节列出本轮显式部署修正。

## 3. 发行身份与操作依据

区分三个身份：交接文档 commit、部署源码 commit、镜像 Image ID/digest。
旧镜像 tag 中的 0.3.5 不等于部署源码版本，也不等于正式 v0.3.6 发布声明。

固定部署源码：

```text
SOURCE_REPOSITORY=https://github.com/Computing-Availability-Tools/CATMonitor.git
SOURCE_COMMIT=c1821ca4fa2eec53eb2605dc263561c6076421d0
RELEASE_LABEL=arm64-v0.3.5-stress
PLATFORM=linux/arm64
TARGET_HARDWARE=A2/Ascend910B4
```

该源码是本轮明确的复现基线，不声称是执行当天最新 main。不要自动 merge/rebase 新 main。
若用户要测另一 release，先重新确定 source/image 矩阵，不能悄悄混用。

| 角色 | tag | 预期 Image ID | 固定 registry manifest digest |
|---|---|---|---|
| NPU Control | ghcr.io/spike677/catmonitor-npu:arm64-v0.3.5-stress | sha256:278ed943dbae16c7a0fb5d6d1eb3ae0a61444f5aa543571c8afc43a21ed98521 | sha256:4a86d3dedd27ee616911208b7d8730f8b745eec5948bc4e6bb68b8044012df40 |
| CPU workload | ghcr.io/spike677/catmonitor-stress-cpu:arm64-v0.3.5-stress | sha256:ed2a91fefd06033ebd75cd47786624d8e0edc1b3234d70310bbe60b47660d586 | sha256:584b59a27d9debff4fe662cb73b0117489f89e06b545a9b38e123065bdafbfb9 |
| NPU workload | ghcr.io/spike677/catmonitor-stress-npu:arm64-v0.3.5-stress | sha256:9509425e7bf3b36458c521176fab2935ade06f939f7f4f601001903ac9b92f90 | sha256:e1ad80f88fe8826440e0ced798d6cc4c54c45c44b472db48e8fce5f5368e9f25 |

拉取前重新验证 registry，身份不匹配就停止该镜像；不重新 build 来凑预期 ID。
运行时优先用 repo@sha256 固定引用。不要拿继承自 vLLM base 的 OCI revision 当作
CATMonitor 源码构建 provenance。

操作依据按以下顺序：本任务安全约束/显式差异 → 固定源码的 CLI --help、generator、
Compose 与实现 → 固定源码的 docker/README-npu.md、features/stress/STRESS_USER_GUIDE.md。
发现 README 与实际接口矛盾，记录 DOC_GAP，不通过猜测参数来绕过。
本文不复制全部 docker run 实现；从固定源码逐条展开并记录实际命令。

## 4. Phase 0：只读盘点与日志准备

请先确认操作者提供了目标节点与预期 Docker endpoint。每个新 SSH 会话重新 export，
不要依赖上一次 shell 环境，也不要只用 docker context 名猜测实际连接。

检查并记录：

```bash
hostname
date -Is
uname -m
printf 'DOCKER_HOST=%s\n' "${DOCKER_HOST:-unix:///var/run/docker.sock}"
docker version
docker info --format 'root={{.DockerRootDir}} init={{.InitBinary}}'
docker ps -a --no-trunc
docker image ls --digests --no-trunc
docker volume ls
df -h / /home
nproc
cat /sys/devices/system/cpu/online
free -m
vmstat 1 3
npu-smi info
```

日志和源码用用户批准的、空间足够的磁盘。先创建 EVIDENCE_ROOT 再启动 script/tee，
不能向尚不存在的目录写 transcript。Docker layer 空间取决于 DockerRootDir，不由
日志或 build-root 所在盘决定。不要据压缩体积直接估算展开后所需空间。

记录正式容器的 ID/Image/StartedAt/Status/RestartCount 和业务 PID 只读基线。
不要输出 Docker config 中的 auth，也不要把全部业务 inspect 不加筛选公开上传。

默认名称 catmonitor、catmonitor-web、catmonitor-dfee、catmonitor-stress-cpu、
catmonitor-stress-npu 和 cm-* 卷只可在确认未占用的测试环境使用；已有同名卷也算冲突。
发现冲突不得停止旧环境让位，也不得清理已有卷。需要隔离命名/端口时先列出方案，
保持 generator 的容器名契约一致，只有获得确认后再改；不能隐藏改名继续验收。
检查 19320/19322/19323/9333；如测试 daemon 位于 netns，端口与 HTTP 检查必须在
经过 PID/namespace 核实的同一网络空间内执行。不要复用旧 PID。

## 5. Phase 1：真实拉取 Git 和 GHCR

先在新、空目录获取源码，不覆盖旧工作树。SOURCE_DIR 由本轮选择并记录：

```bash
git -c http.version=HTTP/1.1 clone \
  https://github.com/Computing-Availability-Tools/CATMonitor.git "$SOURCE_DIR"
git -C "$SOURCE_DIR" checkout --detach c1821ca4fa2eec53eb2605dc263561c6076421d0
git -C "$SOURCE_DIR" rev-parse HEAD
git -C "$SOURCE_DIR" status --short
```

不使用任何本地历史 adapter、image tar、docker load 或离线 acceptance bundle 作为输入。
网络失败记录 DNS/TLS/HTTP/错误及每次重试，不重新设计产品。管理员临时代理可以使用，
但 Git/curl 的 proxy 不自动等于 Docker daemon 的 pull proxy；不要未经授权改 daemon。

三张镜像逐张执行并记录 pull 的真实退出码，先 Control、后 CPU、最后 NPU：

```bash
export CONTROL_IMAGE='ghcr.io/spike677/catmonitor-npu@sha256:4a86d3dedd27ee616911208b7d8730f8b745eec5948bc4e6bb68b8044012df40'
export CPU_IMAGE='ghcr.io/spike677/catmonitor-stress-cpu@sha256:584b59a27d9debff4fe662cb73b0117489f89e06b545a9b38e123065bdafbfb9'
export NPU_IMAGE='ghcr.io/spike677/catmonitor-stress-npu@sha256:e1ad80f88fe8826440e0ced798d6cc4c54c45c44b472db48e8fce5f5368e9f25'
docker pull "$CONTROL_IMAGE"
docker image inspect "$CONTROL_IMAGE" \
  --format 'id={{.Id}} platform={{.Os}}/{{.Architecture}} digest={{json .RepoDigests}}'
# 核对本节身份表后才继续 CPU；再次核对磁盘后才继续 NPU。
docker pull "$CPU_IMAGE"
docker image inspect "$CPU_IMAGE" \
  --format 'id={{.Id}} platform={{.Os}}/{{.Architecture}} digest={{json .RepoDigests}}'
docker pull "$NPU_IMAGE"
docker image inspect "$NPU_IMAGE" \
  --format 'id={{.Id}} platform={{.Os}}/{{.Architecture}} digest={{json .RepoDigests}}'
```

如需证明匿名分发，使用新空 DOCKER_CONFIG 进行 pull，不更改用户现有登录。
若 private/denied 就报告分发门禁阻塞，让用户安全完成登录；不要反复尝试旧 PAT。
按运行环境记录 AUTH_MODE=anonymous/existing_login/user_supplied_login。

存在 layer 缓存时记录 PULL_MODE=registry_verified_cached_layers；没有删除镜像或
创建新daemon来制造“全新下载”。只有观察到确实未缓存、完成下载，才标记 cold download。

将 README 使用的 CATMONITOR_IMAGE、CATMONITOR_CPU_STRESS_IMAGE、
CATMONITOR_NPU_STRESS_IMAGE 分别赋值为上面的固定引用。
源码 smoke 与镜像 smoke 是不同门禁；Control 的 CLI 可能依赖 DCMI，按 README 的
实际驱动挂载验证 version、collect、health、stress --help，不以缺库误报镜像内无程序。

## 6. 必须显式记录的部署/观察修正

这些是已知但未随本交接提交其他文件的修正。你可以在本轮实际命令中明确使用，
保存 DEPLOYMENT_DELTA，不修改源仓文件，不声称是原始 README 原封不动通过。

1. 首次 snapshot：在启动 daemon 之前开始计时并安排只读采样；分别记录第一次
   ready 成功和第一次非空、JSON可解析的 snapshot。默认120秒限时，轮询间隔2秒，
   curl 和 docker exec 也需单次timeout。读取snapshot_npu.json；无数据不能只因
   ready=200判FAIL，也不能固定sleep35。若首次观察已就绪，只给观察上界，不编造生成时刻。
2. NPU workload 的 docker run 加 --init；若选择核对Compose，要求等价init:true。
   先用现有Control镜像、无设备的 --init --network none --entrypoint /bin/true 探针。
   Docker help支持不代表docker-init已安装。缺init即阻塞，不偷偷移除 --init、不重启daemon。
   在实际NPU容器中核对HostConfig.Init与PID1；本轮必须重新验证自然结束和Cancel回收。
3. 显式 CATMONITOR_DOCKER_SOCKET 映射到daemon容器预期的Docker socket路径，确保
   executor连的正是当前测试daemon。不要把测试socket与control.sock混为一谈。
4. CPU参数来自本机online CPU、可用内存与实际镜像HPL.dat，不沿用历史96/128核或8 ranks。
   HPL rank必须等于实际P×Q；线程乘积不得超出允许容量；检查N矩阵与MPI额外内存。
   HPCG同样核对rank、每rank网格及内存。generator和docker run使用同一组参数。
5. 所有generated YAML、stress state、NPU输出使用本轮专属目录。NPU generator
   显式传 --npu-output-dir，与docker run的结果bind一致；核对profile/manifest/容器三者一致。
6. 检查进程必须先确保docker top/ps成功，再分别统计live与STAT=Z；不能用
   grep无输出或“命令 || true”把工具失败当成无残留。返回no stress report的全新status
   可以为非零，应保留原始退出码并单独说明，不能覆盖doctor的真实结果。

此外需要任何隐藏环境变量、额外挂载或代码修复，先记录DOC_GAP并停止该路径，
不要静默加入后称“新用户按README通过”。

## 7. Phase 2：Monitoring-only（三容器）

按固定源码README逐条展开并执行daemon、Web、DFeE的docker run。
只使用NPU Control一张镜像；不创建CPU/NPU workload、不生成Stress配置。
每个容器保存ID、Image ID、entrypoint、args、mounts、network、privileged。

必须验证：

- 容器数3（只数本轮拥有的容器）；daemon无Docker socket，Web/DFeE无control卷。
- /-/ready、/metrics有效；snapshot_npu.json非空、JSON可解析、时间戳持续更新。
- 宿主机执行docker exec catmonitor catmonitor collect -o table和health -o table正常。
- Web :19322、/stress/，DFeE :19323、exporter :9333/metrics。
- /api/stress/config：enabled=false、available=false，不是Web未启用。
- daemon没有实际control.sock；Monitoring无需Stress运行依赖。
- 如有浏览器工具，截图健康页和DFeE，确认有真实数据而非快照等待/404；无浏览器则
  VISUAL_UI_REVIEW=NOT_PERFORMED，不把HTTP200当作视觉PASS。

保存后仅清理本轮三容器/卷。保留证据和镜像，再进入CPU。

## 8. Phase 3：CPU-only（四容器，完整负载）

先做CPU/内存/业务门禁，再执行README CPU-only generator；打印完整命令和参数依据。
只有Control+CPU两张镜像；逐条启动CPU workload、daemon、Web、DFeE，不创建NPU workload。

边界：daemon挂Docker socket；Web只通过control.sock；DFeE无Docker socket；CPU workload
network=none、只读rootfs、privileged=false，capabilities/pids/shm/user与README一致。
三个Monitoring服务与上一场景完全重新创建，不能复用未启用Stress的daemon。

按CLI --help确认参数，并分别执行以下负载，不并行：

```bash
docker exec catmonitor catmonitor stress doctor -c /etc/catmonitor/catmonitor.yaml -o table
docker exec catmonitor catmonitor stress run --bench stream -o table
docker exec catmonitor catmonitor stress run --bench hpcg -o table
docker exec catmonitor catmonitor stress run --bench hpl -o table
docker exec catmonitor catmonitor stress status -o json
```

每个job保存开始/结束/耗时/profile/hash/结果，CLI与Web latest/history核对相同job ID。
不能在三次结束后只读latest，然后声称前三次都有证据。

- STREAM：Copy/Scale/Add/Triad均存在，结果状态正常。
- HPCG：本次新结果包含VALID、GFLOP/s与真实完成信息；不能读取旧文件。
- HPL：本次正常完成和数值正确性检查通过，GFLOP/s及N/NB/P/Q明确。
- timeout窗口结束可能被产品记录为通过，但不能代替HPL/HPCG FULL_COMPLETION。
  提前根据规模确认窗口，不在失败后抹日志放大超时“重算通过”。

双终端和跨入口测试：

1. CLI启动HPL，B终端/浏览器确认新job、benchmark、started_at与active状态。
2. 观察真实MPI/Hydra/xhpl进程，实际rank依据profile；Web取消同一job。
3. Web启动CPU任务，CLI观察并取消同一job；任务太快结束不算Cancel通过。
4. active任务期间另一入口发起任务，必须被拒绝且不出现第二套workload。
5. Cancel分开记录请求受理、终态、workload真正退出；30秒限时检查PID/PPID/STAT。
6. 与启动前进程表比较，无本次MPI/xhpl活进程、无新增僵尸；失败保留现场，不重启掩盖。

Web路径优先真实浏览器点击Run/Cancel并截图；没有浏览器可用实际前端请求契约做API
验证，但必须另记WEB_API和WEB_UI，不能把curl叫作点击。不得猜header、路径和JSON。
结束归档报告/历史/进程和日志，清理本阶段四容器/卷/临时状态。

## 9. Phase 4：NPU-only（四容器）

先npu-smi/业务PID/内存门禁；vLLM占用时，本阶段有设备初始化的doctor也暂缓。
空闲后按README生成A2、runc、npu-only配置，动态读取stress-profile.json生成设备数组。
正确检查JSON解析退出码，不因mapfile/process substitution成功而忽略内部Python失败。

- 记录host device nodes、mapped count、runtime visible IDs、Burn logical IDs。
- 不硬编码2/5、0..7，不将max设备号当count；当前host与logical对应关系要实测。
- 检查lspci、PCI topology、CANN、torch_npu，通过正式catmonitor-stress-exec describe链。
  不用未source CANN的裸Python替代正式doctor；不增加exec_count等无效参数。
- NPU使用 --init、runc、privileged、network none、read-only以及README可写HOME/output。
  核对实际PID1、Init、driver映射、环境和目录；CPU workload不存在，共四容器。

自然完成：从CLI启动一次完整npu_burn（A2 matmul），持续记录主进程与workers。
要求全部本次映射设备/预定case都有新CSV，无error，errors/err_count=0。
核对job、结果文件时间/归属，不读旧CSV，不用其他版本镜像历史成绩替代。

在同一NPU容器内保存运行前、运行中、自然结束后PID/PPID/STAT：
LIVE_WORKLOAD_PROCESS_COUNT=0、ZOMBIE_PROCESS_COUNT=0才算自然回收通过。
继续使用同一容器，从Web再次启动，待Burn主进程和multiprocessing worker实际出现后
通过CLI取消；记录受理/终态/退出过程，验证live与zombie均0、PID1正常。
不能删除或重启容器后再报告回收PASS。

分别报告NPU_FUNCTIONAL_RUN、NPU_CANCEL、NPU_NATURAL_EXIT_REAPING、NPU_CANCEL_REAPING。
功能PASS但僵尸FAIL必须分别保留。归档新CSV/报告后清理本阶段资源。

## 10. Phase 5：Full（五容器，集成验证）

仅CPU和NPU独立门禁都通过且资源空闲后执行。使用同样三张镜像，生成新的Full配置，
启动三个Control服务+CPU workload+NPU workload，共五容器，仍然只有一个Controller。

- doctor 4/4；Monitoring、Web、DFeE不回退。
- 顺序完整运行STREAM/HPCG/HPL/NPU Burn，保存Full自身的新结果；独立阶段结果不冒充Full。
- CLI/Web状态和历史共享；active CPU job时NPU请求被拒绝，反向同理。
- CPU/NPU跨入口取消与残留检查；不要为了检查互斥实际并行压两类设备。
- 同一Web :19322提供Monitoring与Stress；不出现第二个operator listener或Stress Web容器。

资源忙则Full暂缓，最终不得标记完整验收PASS。

## 11. 可选源码测试，不能冒充镜像测试

若主机已有满足go.mod的Go/编译器，可另跑以下只读源码检查；不要安装工具链或build镜像：

```bash
"$GO_BIN" version
GOTOOLCHAIN=local "$GO_BIN" test ./...
GOTOOLCHAIN=local "$GO_BIN" vet ./...
GOTOOLCHAIN=local make GO="$GO_BIN" test-stress
GOTOOLCHAIN=local make GO="$GO_BIN" test-stress-race
```

测试可能创建缓存，放在允许的测试目录。先读当前Makefile区分fixture与实机target，
不要误调用全局部署脚本。GO覆写不传播、测试清理竞态或ARM64 race工具链阻塞分别报告。
无合适工具链记NOT_RUN_ENVIRONMENT，不作为镜像运行失败。源码检查不证明旧镜像包含源码修复。
本交接不要求验证Generic/GPU镜像或A3/A5硬件；分别列OUT_OF_SCOPE，不能宣称全平台通过。

## 12. 证据、失败与最终清理

每个主要步骤独立保存：command.sh、stdout.log、stderr.log、start/end、exit-code、
observation.md；长任务另存job.json、profile、report/history、新CSV、进程表和截图。
日志管道保存真实PIPESTATUS；不覆盖第一次失败；预期Cancel非零也保留，不一律改成0。
不运行run_all隐藏总流程；只读采样、分步日志记录和JSON断言可以辅助。

集中生成MANUAL_OPERATION_RECORD.md，列每步目的/执行位置/实际命令/输出/观察/判定/证据。
标记EXECUTION_MODE=CLAUDE_SIMULATED_MANUAL、HUMAN_EXECUTED=false。
额外记录source/guide SHA、镜像引用/ID/digest、下载缓存情况、参数依据、显式部署差异。

清理前后再次确认endpoint和对象归属。只删本轮创建且不再被引用的容器、卷、临时状态；
先保存CSV和故障证据。故障需要保留现场时停止测试workload防止持续占资源，并列明未清理项。
不删任何镜像、源码、evidence、旧业务数据；不自动留下新Full/Monitoring常驻环境。
正式与业务容器ID/Image/StartedAt/Status/RestartCount前后比对；如他人改动，应报告差异
及本轮实际动作，不能无条件宣称UNCHANGED，也不要尝试恢复别人操作。

最终至少输出以下字段，不预填PASS：

```text
EXECUTION_MODE=CLAUDE_SIMULATED_MANUAL
HUMAN_EXECUTED=false
HANDOFF_COMMIT=
SOURCE_COMMIT=
SOURCE_CLEAN=
GUIDE_SHA256=
DEPLOYMENT_DELTA=
GIT_CLONE=
GHCR_AUTH_MODE=
CONTROL_PULL=
CPU_PULL=
NPU_PULL=
PULL_MODE=
IMAGE_IDS_AND_DIGESTS=
MONITORING_DEPLOYMENT=
SNAPSHOT_READY_AND_JSON=
SNAPSHOT_TIMING=
HOST_CLI_COLLECT_HEALTH=
WEB_MONITORING=
DFEE_AND_EXPORTER=
CPU_DEPLOYMENT=
CPU_DOCTOR=
STREAM_FULL=
HPCG_FULL_COMPLETION=
HPL_FULL_COMPLETION=
CPU_CROSS_ENTRY_VISIBILITY=
CPU_CANCEL_AND_REAPING=
NPU_DEPLOYMENT=
NPU_TOPOLOGY_AND_ENV=
NPU_DOCTOR=
NPU_BURN_FULL=
NPU_ERRORS=
NPU_NATURAL_EXIT_REAPING=
NPU_CANCEL_REAPING=
FULL_FIVE_CONTAINERS=
FULL_FOUR_BENCHMARK_COMPLETION=
SINGLE_ACTIVE_JOB=
WEB_API_RUN_CANCEL=
WEB_VISUAL_RUN_CANCEL=
SOURCE_REGRESSION=
DOC_GAPS=
FORMAL_ENVIRONMENT_UNCHANGED=
BUSINESS_ENVIRONMENT_UNCHANGED=
FINAL_TEST_CONTAINER_COUNT=
FINAL_TEST_VOLUME_COUNT=
MANUAL_OPERATION_RECORD=
EVIDENCE_ROOT=
COMPLETE_ACCEPTANCE=PASS/FAIL/PARTIAL_DEFERRED
```

所有要求的真实负载与入口未完成，不得标COMPLETE_ACCEPTANCE=PASS。
结束后停止，不修改产品、不提交、不推送、不创建tag。
