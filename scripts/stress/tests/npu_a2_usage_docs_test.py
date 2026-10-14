#!/usr/bin/env python3
"""Check the A2 companion guide without Docker, network, or NPU workloads."""
import os
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
GUIDE = ROOT / "docker/NPU_A2_USAGE_GUIDE.md"
PPT = ROOT / "docker/presentations/CATMonitor_A2_NPU_Burn_使用指南.pptx"
TEXT = GUIDE.read_text(encoding="utf-8")
TRANSFER = ROOT / "docker/A2_NODE_TRANSFER_GUIDE.md"
TRANSFER_TEXT = TRANSFER.read_text(encoding="utf-8")
GUIDE_BLOCKS = re.findall(r"^```bash\n(.*?)^```", TEXT, re.M | re.S)
TRANSFER_BLOCKS = re.findall(r"^```bash\n(.*?)^```", TRANSFER_TEXT, re.M | re.S)
BLOCKS = GUIDE_BLOCKS + TRANSFER_BLOCKS
BASH = shutil.which("bash") if os.name == "posix" else None


class A2UsageGuideTest(unittest.TestCase):
    def test_markdown_and_links(self):
        self.assertGreater(len(BLOCKS), 15)
        for guide, material in ((GUIDE, TEXT), (TRANSFER, TRANSFER_TEXT)):
            self.assertEqual(len(re.findall(r"^```", material, re.M)) % 2, 0)
            for path in re.findall(r"\]\(([^)]+)\)", material):
                if not path.startswith(("https://", "http://", "#")):
                    self.assertTrue((guide.parent / path.split("#")[0]).is_file(), path)

    def test_generator_options_are_real(self):
        source = (ROOT / "scripts/stress/generate_stress_deployment.sh").read_text()
        help_text = source.split("Usage:", 1)[1].split("EOF", 1)[0]
        for command in BLOCKS:
            if "bash scripts/stress/generate_stress_deployment.sh" not in command:
                continue
            command = command[command.index("bash scripts/stress/generate_stress_deployment.sh"):]
            command = command.split("\n\n", 1)[0]
            for option in re.findall(r"(?<!\S)--[a-z][a-z-]*", command):
                self.assertIn(option, help_text, option)

    def test_transfer_identity_and_non_destructive_scope(self):
        shells = "\n".join(TRANSFER_BLOCKS)
        for part in ("docker inspect --format '{{.Image}}'", "docker diff", "docker save",
                     "docker load", "image-ids.tsv", 'test -z "$(git -C "$SOURCE_DIR" status --porcelain)"',
                     "docker image inspect -f '{{.Id}}'", "sha256sum -c SHA256SUMS",
                     '--npu-chip-generation A2', '--npu-allowed-devices "$ALLOWED_DEVICES"',
                     '--npu-config-dir "$DEPLOY/npu-config"', "dc up -d --no-build --pull never",
                     'image: $WEB', 'image: $DFEE', "--require-pass", "set -euo pipefail",
                     "model-action create_reference", "model-action compare"):
            self.assertIn(part, shells)
        for forbidden in ("docker build", "docker commit", "docker export", "docker import",
                          "docker stop", "docker rm", "docker rename", "docker system prune",
                          "--chip-generation A3", "--npu-chip-generation A3", "cann-9.1",
                          "v0.23.0rc1-a3", "docker/build.sh", "build_npu_burn_image.sh",
                          "--npu-device-nodes 2,5"):
            self.assertNotIn(forbidden, shells)
        for part in ("不隔离 host 网络端口", "NOT_RUN/PENDING", "镜像 save 不含这些修改",
                     "参考不从 85 复制", "85 始终不停止"):
            self.assertIn(part, TRANSFER_TEXT)

    def test_compose_and_admin_contract(self):
        for part in ("docker/docker-compose.yml", "docker/docker-compose.npu.yml",
                     "docker/docker-compose.stress.yml", "$G/docker-compose.stress.generated.yml",
                     "--profile stress-cpu --profile stress-npu", 'export CATMONITOR_IMAGE="$CONTROL"',
                     "dc stop catmonitor-stress-npu", "dc stop catmonitor-stress-cpu catmonitor-stress-npu",
                     "allow_npu_reference_generation: false", "不能当作后端安全隔离",
                     "不再启动 Stress Controller", "参考不匹配", "saved_steps=expected_steps"):
            self.assertIn(part, TEXT)
        self.assertNotIn("docker system prune", TEXT)
        self.assertNotIn("docker rm -f", TEXT)
        self.assertNotIn("catmonitor-install", TEXT)

    def test_ppt_and_no_secrets(self):
        with zipfile.ZipFile(PPT) as archive:
            slides = [n for n in archive.namelist() if re.fullmatch(r"ppt/slides/slide\d+.xml", n)]
            self.assertEqual(len(slides), 9)
            xml_text = []
            for name in archive.namelist():
                if name.endswith(".xml"):
                    xml_text.append("".join(ET.fromstring(archive.read(name)).itertext()))
        material = TEXT + TRANSFER_TEXT + "\n".join(xml_text)
        # Report only the presence of a match, never a potential credential.
        self.assertIsNone(re.search(r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN .*PRIVATE KEY-----)", material),
                          "Potential credential in publication material")

    def test_editable_process_diagrams(self):
        ns = {"p": "http://schemas.openxmlformats.org/presentationml/2006/main",
              "a": "http://schemas.openxmlformats.org/drawingml/2006/main"}
        titles = (
            "部署流程：配套交付到首次作业",
            "压测功能修改：代码、测试与镜像更新",
            "压测配置调整：三种生效方式",
            "管理员启停：功能开关与任务取消",
        )
        with zipfile.ZipFile(PPT) as archive:
            for number, title in enumerate(titles, 6):
                slide = ET.fromstring(archive.read(f"ppt/slides/slide{number}.xml"))
                text = "\n".join(node.text or "" for node in slide.findall(".//a:t", ns))
                self.assertIn(title, text)
                self.assertGreaterEqual(len(slide.findall(".//p:cxnSp", ns)), 3,
                                        f"Slide {number} requires editable flow connectors")
                self.assertGreaterEqual(len(slide.findall(".//p:sp", ns)), 8,
                                        f"Slide {number} requires editable diagram content")

    @unittest.skipUnless(BASH, "Bash syntax checks require a POSIX test host")
    def test_bash_syntax(self):
        for index, block in enumerate(BLOCKS):
            result = subprocess.run([BASH, "-n"], input=block, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, "Bash block " + str(index) + ": " + result.stderr)

    @unittest.skipUnless(BASH, "Generator fixture requires a POSIX test host")
    def test_documented_generator_and_disable_commands(self):
        block = next(b for b in BLOCKS if "bash scripts/stress/generate_stress_deployment.sh" in b)
        # Execute only the generator, never the preceding host mkdir or any docker command.
        command = block[block.index("bash scripts/stress/generate_stress_deployment.sh"):].strip()
        self.assertNotIn("docker ", command)
        with tempfile.TemporaryDirectory(prefix="catmonitor-a2-guide-") as temp:
            root = Path(temp)
            host = root / "host"
            for directory in ("usr/local/Ascend/driver/lib64", "usr/local/dcmi"):
                (host / directory).mkdir(parents=True)
            for file in ("dev/davinci2", "dev/davinci5", "dev/davinci_manager", "dev/devmm_svm", "dev/hisi_hdc",
                         "usr/local/Ascend/driver/version.info", "etc/ascend_install.info", "usr/local/bin/npu-smi"):
                target = host / file
                target.parent.mkdir(parents=True, exist_ok=True)
                target.touch()
            env = dict(os.environ, G=str(root / "generated"), OUT=str(root / "output"), FIXTURE_HOST=str(host),
                       CONTROL="example/control:fixture", CPU="example/cpu:fixture", NPU="example/npu:fixture")
            result = subprocess.run([BASH, "-eu", "-c", command + ' \\\n  --npu-host-root "$FIXTURE_HOST"\n'],
                                    cwd=ROOT, env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            cfg = root / "generated/catmonitor-stress.yaml"
            content = cfg.read_text()
            self.assertIn("allowed_npu_devices: [0,1]", content)
            self.assertIn("allow_npu_reference_generation: true", content)
            cpu_env = (cfg.parent / "cpu-workload.env").read_text()
            for setting in ("HPL_MPI_PROCESSES=1", "HPL_P=1", "HPL_Q=1", "HPL_N=4096"):
                self.assertIn(setting, cpu_env)
            env["CFG"] = str(cfg)
            changes = [line for b in BLOCKS for line in b.splitlines() if line.startswith("sed -i ")]
            self.assertEqual(len(changes), 3)
            for command, expected_npu in zip(changes, (False, True, True)):
                result = subprocess.run([BASH, "-eu", "-c", command], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                content = cfg.read_text()
                self.assertIn("npu_burn: { enabled: " + str(expected_npu).lower(), content)
                self.assertIn("snapshot:\n  enabled: true", content)
                self.assertIn("stream: { enabled: true", content)
            self.assertIn("stress:\n  enabled: false", content)

    @unittest.skipUnless(BASH, "Transfer generator fixture requires a POSIX test host")
    def test_transfer_generator_discovers_target_devices(self):
        block = next(b for b in TRANSFER_BLOCKS if "bash scripts/stress/generate_stress_deployment.sh" in b)
        command = block[block.index("bash scripts/stress/generate_stress_deployment.sh"):]
        command = command.split("\n\n", 1)[0]
        self.assertNotIn("docker ", command)
        for ids, security in (((2, 5), "legacy-privileged"), ((0, 3, 7), "restricted")):
            with self.subTest(ids=ids, security=security), tempfile.TemporaryDirectory(prefix="a2-transfer-guide-") as temp:
                root = Path(temp)
                host = root / "host"
                for directory in ("usr/local/Ascend/driver/lib64", "usr/local/dcmi"):
                    (host / directory).mkdir(parents=True)
                for file in tuple(f"dev/davinci{i}" for i in ids) + (
                        "dev/davinci_manager", "dev/devmm_svm", "dev/hisi_hdc",
                        "usr/local/Ascend/driver/version.info", "etc/ascend_install.info", "usr/local/bin/npu-smi"):
                    target = host / file
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.touch()
                shutil.copytree(ROOT / "third_party/ascend_npu_burn/source/ascend_npu_burn/config", root / "npu-config")
                env = dict(os.environ, G=str(root / "generated"), DEPLOY=str(root), OUT=str(root / "output"),
                           FIXTURE_HOST=str(host), CONTROL="example/control:fixture", CPU="example/cpu:fixture",
                           NPU="example/npu:fixture", CPU_CONTAINER="a2-transfer-cpu", NPU_CONTAINER="a2-transfer-npu",
                           ONE_DEVICE="0", ALLOWED_DEVICES="0,1", NPU_MEMORY_MODE="checkpointed",
                           NPU_SECURITY_PROFILE=security, NPU_ASCEND_ENV_SCRIPT="/usr/local/Ascend/cann-fixture/set_env.sh")
                fixture_command = command.replace("--output-dir", '--npu-host-root "$FIXTURE_HOST" --output-dir', 1)
                result = subprocess.run([BASH, "-eu", "-c", fixture_command], cwd=ROOT, env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                generated = root / "generated"
                profile = json.loads((generated / "stress-profile.json").read_text())
                self.assertEqual(profile["npu"]["host_device_ids"], list(ids))
                self.assertEqual(profile["npu"]["privileged"], security == "legacy-privileged")
                cfg = (generated / "catmonitor-stress.yaml").read_text()
                self.assertIn("container: a2-transfer-cpu", cfg)
                self.assertIn("container: a2-transfer-npu", cfg)
                self.assertIn("allowed_npu_devices: [0,1]", cfg)
                workload = (generated / "npu-workload.env").read_text()
                self.assertIn(f"CATMONITOR_NPU_DEVICE_COUNT={len(ids)}", workload)
                self.assertIn("NPU_BURN_CHIP_GENERATION=A2", workload)
                self.assertIn("ASCEND_ENV_SCRIPT=/usr/local/Ascend/cann-fixture/set_env.sh", workload)
                self.assertIn("CATMONITOR_MODEL_MEMORY_MODE=checkpointed", workload)
                self.assertIn(str(root / "npu-config"), (generated / "docker-compose.stress.generated.yml").read_text())


if __name__ == "__main__":
    unittest.main()
