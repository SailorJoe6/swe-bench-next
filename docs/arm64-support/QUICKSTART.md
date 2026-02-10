# ARM64 Quick Start Guide

**Environment Variables:** This guide uses `$PROJECT_ROOT`, `$SWE_BENCH_ROOT`, and `$SWE_AGENT_ROOT`. Set them to your repository paths:
```bash
export PROJECT_ROOT=~/swebench-eval-next
export SWE_BENCH_ROOT=~/SWE-bench
export SWE_AGENT_ROOT=~/SWE-agent
```

## Initial Setup

**You must use the ARM64-patched forks, not the upstream repositories!**

```bash
# Clone this repository
git clone https://github.com/SailorJoe6/swe-bench-next.git $PROJECT_ROOT
cd $PROJECT_ROOT

# Clone ARM64-patched SWE-bench fork
git clone -b arm64-support https://github.com/SailorJoe6/SWE-bench.git $SWE_BENCH_ROOT

# Clone ARM64-patched SWE-agent fork
git clone -b arm64-support https://github.com/SailorJoe6/SWE-agent.git $SWE_AGENT_ROOT

# Create virtual environment and install
python3 -m venv venv
source venv/bin/activate
pip install -e $SWE_BENCH_ROOT
pip install -e $SWE_AGENT_ROOT
```

## TL;DR

```bash
# 1. Build images (one time, 8-12 hours)
cd $SWE_BENCH_ROOT
source $PROJECT_ROOT/venv/bin/activate
python -m swebench.harness.prepare_images \
    --dataset_name multilingual \
    --split test \
    --arch arm64 \
    --num_workers 4

# 2. Tag images for SWE-agent (one time)
cd $PROJECT_ROOT
bash scripts/tag-arm64-images.sh

# 3. Run evaluation
sweagent run-batch \
  --config config/qwen3-vllm.yaml \
  --output_dir results/phase3/my-run  # Use results/phase3/ for SWE-Agent runs
```

## Prerequisites Checklist

- [ ] ARM64 system (aarch64 architecture)
- [ ] Docker installed
- [ ] Python 3.12+ environment
- [ ] SWE-bench repo at `$SWE_BENCH_ROOT` with ARM64 patches
- [ ] SWE-agent repo at `$SWE_AGENT_ROOT` with ARM64 patches
- [ ] vLLM server running (optional, for model inference)

## Modified Repositories

**Important:** You need the patched versions of:

1. **SWE-bench fork**: `git@github.com:SailorJoe6/SWE-bench.git` (branch: `arm64-support`)
2. **SWE-agent fork**: `git@github.com:SailorJoe6/SWE-agent.git` (branch: `arm64-support`)

Clone these instead of upstream if starting fresh.

## File Changes Summary

### SWE-bench Repository

```
swebench/harness/dockerfiles/
├── __init__.py          # Added chrome_install and pnpm_arch logic
└── javascript.py        # Added {chrome_install} and {pnpm_arch} placeholders
```

### SWE-agent Repository

```
sweagent/run/
└── batch_instances.py   # Added arch parameter to SWEBenchInstances
```

### This Repository (swebench-eval-next)

```
config/
└── qwen3-vllm.yaml      # ARM64-aware config

docs/arm64-support/
├── README.md            # Full documentation
├── QUICKSTART.md        # This file
└── CHANGES.md           # Detailed code changes

scripts/
└── tag-arm64-images.sh  # Tag images for SWE-agent
```

## Common Commands

### Check Architecture

```bash
# System architecture
uname -m                 # Should show: aarch64

# Docker default platform
docker version --format '{{.Server.Arch}}'  # Should show: arm64

# Check specific image architecture
docker inspect sweb.eval.arm64.apache__druid-13704:latest \
    --format '{{.Architecture}}'  # Should show: arm64
```

### List Built Images

```bash
# All ARM64 base images
docker images | grep "sweb.base.*arm64"

# All ARM64 instance images
docker images | grep "sweb.eval.arm64"

# Count instances
docker images | grep "sweb.eval.arm64" | wc -l  # Should be ~300
```

### Monitor Evaluation

```bash
# Watch log file (using Phase 3 output directory)
tail -f results/phase3/my-run/run_batch.log

# Check progress
watch -n 5 'ls -1 results/phase3/my-run/*/instance_id.traj | wc -l'

# View trajectory
tail -100 results/phase3/my-run/instance-name/instance-name.traj
```

### Clean Up

```bash
# Remove all ARM64 images (WARNING: will need to rebuild!)
docker rmi $(docker images -q 'sweb.*.arm64.*')

# Remove only instance images (keep base images)
docker rmi $(docker images -q 'sweb.eval.arm64.*')

# Clean build logs
rm -rf logs/build_images/instances/
```

## Validation

After building, validate a few images:

```bash
# Test Python project (has Python)
docker run --rm sweb.eval.arm64.django__django-11179:latest python --version

# Test Java project (no Python - this should fail, it's expected)
docker run --rm sweb.eval.arm64.apache__druid-13704:latest python --version
# Should error - Java projects don't have Python (SWE-agent installs it)

# Test JavaScript project (should have Node and Chromium)
docker run --rm sweb.eval.arm64.preactjs__preact-2757:latest node --version
docker run --rm sweb.eval.arm64.preactjs__preact-2757:latest chromium-browser --version
```

## Troubleshooting Quick Fixes

### "Image not found"
```bash
# Check if image exists with different name
docker images | grep instance-name

# Tag it correctly
docker tag actual-name:tag expected-name:tag
```

### "Platform mismatch"
```bash
# Rebuild with explicit platform
docker build --platform linux/arm64 ...
```

### "Out of disk space"
```bash
# Check disk usage
docker system df

# Clean up
docker system prune -a
```

## What Gets Generated

### During Build (~200-300 GB)

```
Docker Images:
├── sweb.base.py.arm64.*         # Python base images
├── sweb.base.js.arm64.*         # JavaScript base images
├── sweb.base.java.arm64.*       # Java base images
├── sweb.base.go.arm64.*         # Go base images
├── sweb.base.rs.arm64.*         # Rust base images
├── sweb.base.rb.arm64.*         # Ruby base images
├── sweb.base.php.arm64.*        # PHP base images
├── sweb.base.c.arm64.*          # C base images
└── sweb.eval.arm64.*            # 300 instance images

Build Logs:
└── logs/build_images/instances/sweb.eval.arm64.*/build_image.log
```

### During Evaluation

```
results/phase3/my-run/          # Phase 3 = SWE-Agent evaluation
├── instance-1/
│   ├── instance-1.traj          # Full agent trajectory (~5-10 MB)
│   ├── instance-1.debug.log     # Debug logs
│   ├── instance-1.info.log      # Info logs
│   └── instance-1.trace.log     # Trace logs
├── instance-2/
│   └── ...
├── preds.json                   # All predictions/patches
└── run_batch.log                # Overall log
```

## Success Criteria

✅ **Build successful if:**
- ~300 ARM64 instance images created
- No BuildImageError in logs
- Sample images run successfully

✅ **Evaluation successful if:**
- Agent starts ARM64 container
- Standalone Python installs
- Model generates responses
- Trajectories are saved
- Patches are generated

## Performance Expectations

| Task | Duration | Resources |
|------|----------|-----------|
| Build base images | 30-60 min | 4 CPU, 8 GB RAM |
| Build instance images | 8-12 hours | 4 CPU, 8 GB RAM, 300 GB disk |
| Single evaluation | 10-20 min | 2 CPU, 4 GB RAM |
| Full 300 evaluations | 50-100 hours | Sequential |

## Support

For issues:
1. Check [README.md](README.md) for detailed troubleshooting
2. Review build logs in `logs/build_images/instances/`
3. Verify image architectures with `docker inspect`
4. Test individual containers with `docker run`
