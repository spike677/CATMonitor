# CATMonitor A2 a2-r1 在线安装指南

本指南面向新的 Linux/ARM64 Ascend 910B4 节点。默认交付链为：

~~~text
Git source → GHCR Golden images → a2-r1 installer → 六容器 → stress doctor
~~~

/opt/catmonitor/releases/a2-r1 是 Golden Offline Acceptance Bundle，只在
GHCR 不可用时作为显式 fallback，不是默认安装路径。安装器不构建镜像或 benchmark，
也不会自动启动 STREAM、HPL、HPCG 或 NPU Burn 工作负载。

## 1. 固定版本

黄金镜像的源码提交：

~~~text
e8c6f0ae4b2d0d7ba3c6a9d705533ed3a887e213
~~~

a2-r1 标签在该提交之上仅增加在线发行元数据、安装器和文档，不改变三张镜像内容。

| 角色 | GHCR 镜像 | Golden Image ID |
|---|---|---|
| Control | ghcr.io/spike677/catmonitor-npu:a2-r1 | sha256:f238d75fe8902a7ea39ec6c1261a674cb6446815116355f94b4b945b21a60424 |
| CPU Runner | ghcr.io/spike677/catmonitor-stress-cpu:a2-r1 | sha256:61e5a5f273684be3cdf18031ad742cf38bbe3512136b64c6e5f705f4356bd2aa |
| NPU Burn | ghcr.io/spike677/catmonitor-npuburn:a2-r1 | sha256:d23553954429c9c16e7f4bb1407b48c4b5bfa8c70b2d57b681245bc46e566160 |

安装器会在 pull/load 后逐一核对 Image ID 和 linux/arm64，不接受同名但内容不同的镜像。

## 2. 节点要求

- Linux/ARM64，默认 Docker daemon 可用；
- Docker CLI 可用；不要求 Docker Compose；
- Ascend 910B4、CANN 8.3.RC2、兼容宿主机驱动；
- 宿主机存在 /usr/local/Ascend/driver、nnae、ascend-toolkit、
  /usr/bin/hccn_tool 和 /usr/local/sbin/npu-smi；
- 当前 A2 profile 已验收稀疏设备 /dev/davinci2、/dev/davinci5；
- Docker data-root 有足够空间容纳约 18 GB 的 NPU Burn 镜像。

确认平台和 Docker：

~~~bash
uname -m
docker version
docker info --format 'root={{.DockerRootDir}}'
~~~

## 3. 获取固定源码

~~~bash
sudo install -d -m 0755 /opt/catmonitor
sudo chown "$(id -u):$(id -g)" /opt/catmonitor

git -c http.version=HTTP/1.1 clone   https://github.com/spike677/CATMonitor.git   /opt/catmonitor/CATMonitor

cd /opt/catmonitor/CATMonitor
git fetch --tags --prune
git checkout a2-r1
git status --short
~~~

git status --short 应无输出。确认发行标签包含 Golden source：

~~~bash
git merge-base --is-ancestor   e8c6f0ae4b2d0d7ba3c6a9d705533ed3a887e213   HEAD
~~~

## 4. 查看无副作用安装计划

~~~bash
cd /opt/catmonitor/CATMonitor
sudo bash scripts/releases/a2-r1/install.sh --action plan
~~~

plan 只显示版本、镜像、目录和策略，不 pull/load 镜像，不创建目录或容器。

## 5. 在线安装

三张 GHCR package 为 Public 时无需登录。可先手工拉取：

~~~bash
docker pull ghcr.io/spike677/catmonitor-npu:a2-r1
docker pull ghcr.io/spike677/catmonitor-stress-cpu:a2-r1
docker pull ghcr.io/spike677/catmonitor-npuburn:a2-r1
~~~

也可以直接由安装器按 Control → CPU Runner → NPU Burn 顺序拉取：

~~~bash
cd /opt/catmonitor/CATMonitor

sudo bash scripts/releases/a2-r1/install.sh   --action up   --acknowledge-root-docker-socket
~~~

确认 Docker socket 是因为过渡期的 Control/运维 Stress Web 需要管理固定 NPU Burn
容器；CPU Runner 不挂 Docker socket。

安装器会：

1. 在线拉取三张镜像并核对 Golden Image ID 与平台；
2. 使用仓内 Golden manifests 生成固定 benchmark adapter 和 YAML；
3. 安装 /opt/catmonitor/stress，创建 /var/lib/catmonitor 状态目录；
4. 生成 /etc/catmonitor/catmonitor.yaml；
5. 通过 runc 创建固定 NPU Burn 容器并保留稀疏设备映射；
6. 使用明确的 docker run 参数启动六个容器；
7. 验证 metrics、snapshot、Web、DFeE、Exporter 和运维 Stress Web；
8. 执行 stress doctor，但不执行任何真实压测。

若已有非 a2-r1 管理的 /etc/catmonitor/catmonitor.yaml，安装器会停止。审核后
才可显式替换：

~~~bash
sudo bash scripts/releases/a2-r1/install.sh   --action up   --replace-config   --acknowledge-root-docker-socket
~~~

旧文件会按 UTC 时间戳备份。

## 6. 容器与端口

| 容器 | 作用 | 网络/端口 |
|---|---|---|
| catmonitor | daemon、采集、metrics、CLI | host，:19320 |
| catmonitor-web | 健康概览 | host，:19322 |
| catmonitor-dfee | DFeE 与 Exporter | host，:19323、:9333 |
| catmonitor-cpu-runner | STREAM/HPL/HPCG 受限执行器 | network none，Unix socket |
| catmonitor-npuburn | 固定 NPU Burn 执行环境 | runc，映射真实 NPU 设备 |
| catmonitor-stress-web | 可 Run/Cancel 的运维页面 | host，仅 127.0.0.1:29592 |

查看状态和 doctor：

~~~bash
sudo bash scripts/releases/a2-r1/install.sh --action status
sudo bash scripts/releases/a2-r1/install.sh --action doctor
~~~

doctor 预期：

~~~text
stream    PASS
hpl       PASS
hpcg      PASS
npu_burn  PASS
~~~

接口检查：

~~~bash
curl -fsS http://127.0.0.1:19320/metrics >/dev/null
curl -fsS http://127.0.0.1:19322/ >/dev/null
curl -fsS http://127.0.0.1:19323/ >/dev/null
curl -fsS http://127.0.0.1:9333/metrics >/dev/null
curl -fsS http://127.0.0.1:29592/api/stress/config
~~~

## 7. Windows 查看运维 Stress Web

在 Windows PowerShell 建立 SSH 隧道：

~~~powershell
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 `
  -L 127.0.0.1:29592:127.0.0.1:29592 `
  root@<节点IP>
~~~

浏览器访问：

~~~text
http://127.0.0.1:29592/stress/
~~~

## 8. 人工运行压测

安装验收只运行 doctor。管理员确认节点空闲后，再运行真实负载。例如 STREAM：

~~~bash
docker exec catmonitor   /usr/local/bin/catmonitor stress run   --bench stream   -c /etc/catmonitor/catmonitor.yaml   -o table
~~~

也可以在 29592/stress/ 页面选择项目后 Run/Cancel。HPL、HPCG 和 NPU Burn
会占用大量计算、内存、MPI 或 NPU 资源，不应与业务并行执行。

## 9. Offline fallback

只有 GHCR pull 失败时才显式指定 Golden Bundle：

~~~bash
sudo bash scripts/releases/a2-r1/install.sh   --action up   --offline-bundle /opt/catmonitor/releases/a2-r1   --acknowledge-root-docker-socket
~~~

安装器会对所需 tar 单独执行 SHA-256 校验、docker load、添加相同 GHCR tag，
并再次核对 Golden Image ID。在线 pull 成功时不会读取 offline tar/evidence。

## 10. 停止与恢复

停止六个容器但保留镜像、配置、报告和历史：

~~~bash
sudo bash scripts/releases/a2-r1/install.sh --action down
~~~

重新启动并重新执行就绪门禁：

~~~bash
sudo bash scripts/releases/a2-r1/install.sh   --action up   --acknowledge-root-docker-socket
~~~

安装器遇到部分同名容器（不是 0/6 或完整 6/6）时会停止，要求管理员先审查，
避免覆盖未知部署。