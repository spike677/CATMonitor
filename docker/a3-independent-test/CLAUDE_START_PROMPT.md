# Claude 起始提示

使用 `codex/a3-independent-handoff` 分支并记录精确 HEAD。
先读本目录 [README.md](README.md) 和管理员在仓库外填写的
[身份模板](identity.template.json)，再读 [Ascend 部署指南](../README-npu.md)。

通过新 Windows 已验证的 SSH 配置连接目标 A3，先只读确认镜像、已有服务、端口、
隔离和资源预算。不要沿用旧 A2 地址/路径，不要直接执行 A2 镜像与 all 设备默认值。

条件满足后，逐步展示并执行实际部署命令，独立验证 Monitoring三容器、CPU四容器、
NPU四容器；不测Full。CLI/Web可见性、真实负载和Cancel进程回收分别留证。
缺A3镜像或设备忙时延期NPU，不杀业务、不修改代码、不build/push/tag。
不预先假定通过，不删除或替换既有服务，仅清理本轮创建的资源。
