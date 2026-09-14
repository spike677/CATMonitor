# Claude 独立验收起始提示

先完整阅读本目录 [README.md](README.md)、[冻结操作指南](guide/README-npu.md)，
以及管理员在仓库外提供的、已填写的 identity.json / 私有环境附录。
[identity.template.json](identity.template.json) 仅是模板，不能当实时事实。

你负责独立安装和操作；交接者不应已为你部署容器。
第一步只读复核SSH、固定源码、指南SHA、三镜像ID/digest、测试socket/data-root/PID、
network namespace、端口、零测试容器/卷和资源。信息缺失或不符时先停，不猜默认值。

门禁通过后按冻结README逐步进行Monitoring-only、CPU-only、NPU-only。
每次一条主要操作，完整展示命令、退出码、关键输出、现象和证据。
资源忙或无明确预算时，只做可安全执行的安装/只读步骤；
CPU全核负载、NPU部署/初始化/Burn/Cancel不得抢占业务。

daemon后立刻采样ready/snapshot时间；首次status单独记录；
Cancel关联本次新job并确认主进程/worker，分别检查活进程和僵尸；
NPU自然结束及Cancel使用同一容器，真实验证--init与PID1。
HTTP、视觉、按钮交互分开报告，无工具/未执行则NOT_PERFORMED。

发现README_GAP先保留首次失败，允许只读诊断，不暗中补参数或改产品。
每场景精确清理仅属于本轮的资源，保留evidence。
不运行Full、不build/pull已有镜像、不创建新daemon、不改源码/version、不commit/push/tag。
不能将旧PASS作为本轮结果。结束后分场景给出安装、预检、负载、状态、取消、
回收、Web交互、清理结果及未验证原因。
