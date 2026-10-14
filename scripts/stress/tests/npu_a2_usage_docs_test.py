#!/usr/bin/env python3
"""Check the A2 companion guide without Docker, network, or NPU workloads."""
import os
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
BLOCKS = re.findall(r"^```bash\n(.*?)^```", TEXT, re.M | re.S)
BASH = shutil.which("bash") if os.name == "posix" else None


class A2UsageGuideTest(unittest.TestCase):
    def test_markdown_and_links(self):
        self.assertEqual(len(re.findall(r"^```", TEXT, re.M)) % 2, 0)
        self.assertGreater(len(BLOCKS), 15)
        for path in re.findall(r"\]\(([^)]+)\)", TEXT):
            if not path.startswith(("https://", "http://", "#")):
                self.assertTrue((GUIDE.parent / path.split("#")[0]).is_file(), path)

    def test_generator_options_are_real(self):
        source = (ROOT / "scripts/stress/generate_stress_deployment.sh").read_text()
        help_text = source.split("Usage:", 1)[1].split("EOF", 1)[0]
        command = next(b for b in BLOCKS if "bash scripts/stress/generate_stress_deployment.sh" in b)
        for option in re.findall(r"(?<!\S)--[a-z][a-z-]*", command):
            self.assertIn(option, help_text, option)

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
            self.assertEqual(len(slides), 5)
            xml_text = []
            for name in archive.namelist():
                if name.endswith(".xml"):
                    xml_text.append("".join(ET.fromstring(archive.read(name)).itertext()))
        material = TEXT + "\n".join(xml_text)
        # Report only the presence of a match, never a potential credential.
        self.assertIsNone(re.search(r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN .*PRIVATE KEY-----)", material),
                          "Potential credential in publication material")

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


if __name__ == "__main__":
    unittest.main()
