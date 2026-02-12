# ARM64 Support for SWE-bench Evaluation

This documentation covers the complete implementation of ARM64 support for running SWE-bench evaluations on aarch64 systems (NVIDIA Grace, Apple Silicon, AWS Graviton, etc.).

## Environment Variables

Throughout this documentation, we use the following environment variables:

- `$PROJECT_ROOT` - This repository (swebench-eval-next)
- `$SWE_BENCH_ROOT` - SWE-bench repository location
- `$SWE_AGENT_ROOT` - SWE-agent repository location

**Example setup:**
```bash
export PROJECT_ROOT=~/swebench-eval-next
export SWE_BENCH_ROOT=~/SWE-bench
export SWE_AGENT_ROOT=~/SWE-agent
```

Adjust these paths to match your local setup.

## Table of Contents

1. [Overview](#overview)
2. [Architecture Changes](#architecture-changes)
3. [Building ARM64 Images](#building-arm64-images)
4. [Running Evaluations](#running-evaluations)
5. [Troubleshooting](#troubleshooting)

## Overview

### What Was Changed

To support ARM64 architecture, we made modifications to two upstream repositories:

1. **SWE-bench** - Modified Docker image build process to support ARM64-specific dependencies
2. **SWE-agent** - Added architecture parameter to instance loading and configuration

### Why These Changes Were Needed

1. **Chrome vs Chromium**: Google Chrome is not available for ARM64, requiring Chromium as a substitute for JavaScript projects
2. **pnpm Architecture**: pnpm binaries are architecture-specific (x64 vs arm64)
3. **Image Naming**: Docker images need architecture-specific naming (x86_64 vs arm64)
4. **Platform Flags**: Docker build commands need correct `--platform` flags

## Architecture Changes

### SWE-bench Modifications

#### Location: `swebench/harness/dockerfiles/javascript.py`

**Changes Made:**
- Added `{chrome_install}` placeholder for dynamic Chrome/Chromium installation
- Added `{pnpm_arch}` placeholder for architecture-specific pnpm downloads

```python
# Before (hardcoded):
RUN wget -qO- https://get.pnpm.io/install.sh | ENV="$HOME/.bashrc" SHELL="$(which bash)" bash -
ENV PNPM_HOME="/root/.local/share/pnpm"

# After (architecture-aware):
RUN wget https://github.com/pnpm/pnpm/releases/download/v9.1.0/pnpm-linux-{pnpm_arch} -O /usr/local/bin/pnpm \\
    && chmod +x /usr/local/bin/pnpm
```

#### Location: `swebench/harness/dockerfiles/__init__.py`

**Changes Made:**
- Added logic in `get_dockerfile_base()` to set `chrome_install` based on architecture
- Added logic in `get_dockerfile_env()` to set `pnpm_arch` and `chrome_install`

```python
# ARM64 uses Chromium
if arch == "arm64":
    chrome_install = """# Install Chromium for browser testing (ARM64 - Chrome not available)
RUN apt-get update \\
    && apt-get install -y chromium-browser fonts-ipafont-gothic fonts-wqy-zenhei fonts-thai-tlwg \\
        fonts-khmeros fonts-kacst fonts-freefont-ttf libxss1 dbus dbus-x11 \\
        --no-install-recommends \\
    && rm -rf /var/lib/apt/lists/* \\
    && ln -sf /usr/bin/chromium-browser /usr/bin/google-chrome"""

# x86_64 uses Chrome
else:
    chrome_install = """# Install Chrome for browser testing
RUN wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | apt-key add - \\
    && echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google-chrome.list \\
    && apt-get update \\
    && apt-get install -y google-chrome-stable fonts-ipafont-gothic fonts-wqy-zenhei fonts-thai-tlwg \\
        fonts-khmeros fonts-kacst fonts-freefont-ttf libxss1 dbus dbus-x11 \\
        --no-install-recommends \\
    && rm -rf /var/lib/apt/lists/*"""
```

### SWE-agent Modifications

#### Location: `sweagent/run/batch_instances.py`

**Changes Made:**

1. **Added `arch` parameter to `SWEBenchInstances` class:**

```python
class SWEBenchInstances(BaseModel, AbstractInstanceSource):
    """Load instances from SWE-bench."""

    subset: Literal["lite", "verified", "full", "multimodal", "multilingual"] = "lite"
    split: Literal["dev", "test"] = "dev"

    # NEW: Architecture parameter
    arch: Literal["x86_64", "arm64"] = "x86_64"
    """Architecture for Docker images (x86_64 or arm64)"""

    deployment: DeploymentConfig = Field(
        default_factory=lambda: DockerDeploymentConfig(image="python:3.11"),
    )
```

2. **Modified `from_swe_bench()` to accept and use arch parameter:**

```python
@classmethod
def from_swe_bench(cls, instance: dict[str, Any], arch: str = "x86_64") -> Self:
    """Convert instances from the classical SWE-bench dataset to the `SimpleBatchInstance` format."""
    iid = instance["instance_id"]
    image_name = instance.get("image_name", None)
    if image_name is None:
        id_docker_compatible = iid.replace("__", "_1776_")
        # Use arch parameter for image naming
        image_name = f"docker.io/swebench/sweb.eval.{arch}.{id_docker_compatible}:latest".lower()
```

3. **Modified `get_instance_configs()` to set platform based on arch:**

```python
def get_instance_configs(self) -> list[BatchInstance]:
    from datasets import load_dataset

    ds: list[dict[str, Any]] = load_dataset(self._get_dataset_path(), split=self.split)

    if isinstance(self.deployment, DockerDeploymentConfig):
        # Set platform based on architecture
        self.deployment.platform = "linux/arm64" if self.arch == "arm64" else "linux/amd64"

    instances = [
        SimpleBatchInstance.from_swe_bench(instance, arch=self.arch).to_full_batch_instance(self.deployment)
        for instance in ds
    ]
```

## Building ARM64 Images

### Prerequisites

1. ARM64 system (NVIDIA Grace, Apple M-series, AWS Graviton, etc.)
2. Docker installed and configured
3. Python 3.12+ environment
4. Git for cloning repositories

### Build Process

#### 1. Clone ARM64-Patched Repositories

**Critical:** You must use the ARM64-patched forks, not the upstream repositories!

```bash
# Clone this repository
git clone https://github.com/SailorJoe6/swe-bench-next.git $PROJECT_ROOT

# Clone ARM64-patched SWE-bench (branch: arm64-support)
git clone -b arm64-support https://github.com/SailorJoe6/SWE-bench.git $SWE_BENCH_ROOT

# Clone ARM64-patched SWE-agent (branch: arm64-support)
git clone -b arm64-support https://github.com/SailorJoe6/SWE-agent.git $SWE_AGENT_ROOT
```

#### 2. Set Up Python Environment

```bash
cd $PROJECT_ROOT
python3 -m venv venv
source venv/bin/activate

# Install both forks in editable mode
pip install -e $SWE_BENCH_ROOT
pip install -e $SWE_AGENT_ROOT
```

#### 3. Build Base Images

Build the base images for all required languages and architectures:

```bash
cd $SWE_BENCH_ROOT
source $PROJECT_ROOT/venv/bin/activate

# Build ARM64 base images
python -m swebench.harness.prepare_images \
    --dataset_name multilingual \
    --split test \
    --arch arm64 \
    --num_workers 4
```

**What this does:**
- Downloads the SWE-bench Multilingual dataset from HuggingFace
- Identifies all unique repository/version combinations
- Builds base Docker images for each language (Python, JavaScript, Java, Go, Rust, Ruby, PHP, C)
- Tags images with architecture prefix (e.g., `sweb.base.js.arm64.*`)

#### 4. Build Instance Images

Build instance-specific images for all 300 test instances:

```bash
# The script automatically builds all instances
# Output logs go to logs/build_images/instances/
```

**Image naming convention:**
- ARM64: `sweb.eval.arm64.apache__druid-13704:latest`
- x86_64: `sweb.eval.x86_64.apache__druid-13704:latest`

#### 5. Tag Images for SWE-agent

SWE-agent expects images with the Docker registry format. Tag them:

```bash
cd $PROJECT_ROOT

# Tag all ARM64 images automatically
bash scripts/tag-arm64-images.sh

# Or manually tag a single instance:
# docker tag sweb.eval.arm64.apache__druid-13704:latest \
#     docker.io/swebench/sweb.eval.arm64.apache_1776_druid-13704:latest
```

### Build Artifacts

After successful build:
- **Base images**: ~15 images (one per language/version combo)
- **Instance images**: 300 images (one per test instance)
- **Build logs**: `logs/build_images/instances/*/build_image.log`
- **Total size**: ~200-300 GB (depending on projects)

## Running Evaluations

### Configuration

Create or update your SWE-agent config file with ARM64 defaults:

```yaml
# config/qwen3-vllm.yaml

instances:
  type: swe_bench
  subset: multilingual
  split: test
  arch: arm64              # ← ARM64 architecture
  deployment:
    pull: never            # ← Use local images

agent:
  type: default
  templates:
    system_template: |-
      You are a helpful assistant that can interact with a computer to solve tasks.
    instance_template: |-
      # ... your instance template ...
  tools:
    execution_timeout: 300
    bundles:
      - path: tools/multilingual_setup  # ← Required for multilingual dataset
      - path: tools/registry
      - path: tools/edit_anthropic
      - path: tools/review_on_submit_m
      - path: tools/diff_state
    enable_bash_tool: true
    parse_function:
      type: function_calling
  history_processors:
    - type: cache_control
      last_n_messages: 2
  model:
    name: "openai/Qwen/Qwen3-Coder-Next-FP8"
    api_base: "http://localhost:8888/v1"
    api_key: "dummy"
    temperature: 1.0
    top_p: 0.95
    per_instance_cost_limit: 10.0
    total_cost_limit: 100.0
```

### Running Single Instance Test

Test with a single instance first:

```bash
source venv/bin/activate

sweagent run-batch \
  --config config/qwen3-vllm.yaml \
  --instances.slice :1 \
  --output_dir results/phase3/test-single
```

**Expected output:**
- Container starts with ARM64 image
- Standalone Python gets installed
- Agent executes and generates trajectory
- Patch is saved to `results/phase3/test-single/preds.json`

### Running Full Evaluation

Run on all 300 instances:

```bash
sweagent run-batch \
  --config config/qwen3-vllm.yaml \
  --output_dir results/phase3/full-run
```

**Optional parameters:**
- `--instances.slice 0:100` - Run first 100 instances
- `--instances.filter "django.*"` - Filter by instance ID regex
- `--num_workers 4` - Parallel workers (use with caution)

### Output Files

For each instance, SWE-agent generates:

```
results/phase3/full-run/           # Phase 3 = SWE-Agent evaluation
├── instance_id/
│   ├── instance_id.config.yaml     # Instance configuration
│   ├── instance_id.traj            # Full trajectory (all model interactions)
│   ├── instance_id.debug.log       # Debug-level logs
│   ├── instance_id.info.log        # Info-level logs
│   └── instance_id.trace.log       # Trace-level logs
├── preds.json                      # Merged predictions for all instances
├── run_batch.config.yaml           # Run configuration
├── run_batch.log                   # Overall run log
└── run_batch_exit_statuses.yaml   # Exit status for each instance
```

## Troubleshooting

### Image Not Found

**Error:**
```
DockerPullError: Failed to pull image docker.io/swebench/sweb.eval.arm64.apache_1776_druid-13704:latest
```

**Solution:**
1. Verify image exists locally: `docker images | grep apache_1776_druid-13704`
2. If image has double underscores, tag it correctly:
   ```bash
   docker tag sweb.eval.arm64.apache__druid-13704:latest \
       docker.io/swebench/sweb.eval.arm64.apache_1776_druid-13704:latest
   ```
3. Ensure `deployment.pull: never` is set in config

### Chromium/Chrome Issues

**Error:**
```
ChromeDriver not found
```

**Solution:**
Check that ARM64 images are using Chromium:
```bash
docker run --rm sweb.eval.arm64.preactjs__preact-2757:latest \
    which chromium-browser
```

Should return `/usr/bin/chromium-browser`

### Platform Mismatch

**Error:**
```
WARNING: The requested image's platform (linux/amd64) does not match the detected host platform
```

**Solution:**
1. Verify `arch: arm64` is set in config
2. Check that platform is set correctly:
   ```bash
   docker inspect sweb.eval.arm64.apache__druid-13704:latest | grep Architecture
   ```
   Should show `"Architecture": "arm64"`

### Python Not Found in Container

**Error:**
```
python: not found
```

**Solution:**
This is expected for non-Python projects (Java, Go, etc.). SWE-agent automatically builds a layer with standalone Python at `/root/python3.11/`. This happens automatically - do not disable `python_standalone_dir`.

### mvnd: Cannot Execute Binary File (Java/Druid/Gson)

**Error:**
```
/usr/local/mvnd/bin/mvnd: cannot execute binary file: Exec format error
```

**Cause:** Apache Maven Daemon (mvnd) has no Linux ARM64 releases. The x86_64 binary cannot run on ARM64.

**Solution:** This is already fixed in the ARM64-patched SWE-bench fork. The fix creates a `mvnd` -> `mvn` symlink on ARM64. See [mvnd-fix.md](mvnd-fix.md) for details.

### Maven Resource Bundle SNAPSHOT Error (Java/Druid)

**Error:**
```
[ERROR] Failed to execute goal org.apache.maven.plugins:maven-remote-resources-plugin:1.5:process
The following artifacts could not be resolved:
org.apache.apache.resources:apache-jar-resource-bundle:jar:1.5-SNAPSHOT
```

**Cause:** Fresh ARM64 Docker images lack cached Maven artifacts. Druid's `pom.xml` references a SNAPSHOT version that can't be resolved from public repos.

**Solution:** This is already fixed in the ARM64-patched SWE-bench fork. The fix adds a `sed` command to Druid install specs that replaces `1.5-SNAPSHOT` with the released `1.5` version. See [mvnd-fix.md](mvnd-fix.md#related-fix-maven-resource-bundle-snapshot) for details.

**Note:** This only affects Druid instances. Lucene uses Gradle (not Maven) and is unaffected.

### Build Failures

If specific instances fail to build:

1. Check individual build logs:
   ```bash
   cat logs/build_images/instances/sweb.eval.arm64.instance-name__latest/build_image.log
   ```

2. Common issues:
   - **Package unavailable for ARM64**: Some packages in apt/npm/pip may not have ARM64 versions
   - **Hardcoded architecture**: Project may have hardcoded x86_64 assumptions
   - **Memory issues**: Large builds may need more RAM

3. Create an issue list:
   ```bash
   grep -l "BuildImageError" logs/build_images/instances/*/build_image.log > missing_instances.txt
   ```

## Performance Notes

### Build Times

- **Base images**: ~30-60 minutes total
- **Instance images**: ~8-12 hours for all 300 instances (4 workers)
- **Disk space**: ~200-300 GB

### Evaluation Times

- **Single instance**: 10-20 minutes average
- **Full 300 instances**: 50-100 hours (sequential)
- **With 4 workers**: 15-30 hours (use with caution, may overload model server)

## Next Steps

1. **Upstream contributions**: Consider submitting PRs to SWE-bench and SWE-agent
2. **CI/CD integration**: Automate ARM64 image builds
3. **Image registry**: Push images to a private registry for team use
4. **Performance optimization**: Profile and optimize slow-building instances
