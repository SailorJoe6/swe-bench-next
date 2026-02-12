# mvnd ARM64 Binary Fix and Rebuild Guide

## Problem Description

Apache Maven Daemon (`mvnd`) has no Linux ARM64 releases. The SWE-bench Java Dockerfile templates hardcoded `linux-amd64` mvnd download URLs, causing all Java containers (Apache Druid and Google Gson instances) to fail with:

```
/usr/local/mvnd/bin/mvnd: cannot execute binary file: Exec format error
```

This error occurred because the x86_64 mvnd binary was incompatible with ARM64 (aarch64) architecture.

## Affected Instances

**Total: 14 instances**

### Apache Druid (5 instances)
- `apache__druid-13704`
- `apache__druid-14092`
- `apache__druid-14136`
- `apache__druid-15402`
- `apache__druid-16875`

### Google Gson (9 instances)
- `google__gson-1014`
- `google__gson-1093`
- `google__gson-1100`
- `google__gson-2024`
- `google__gson-2061`
- `google__gson-2134`
- `google__gson-2158`
- `google__gson-2311`
- `google__gson-2479`

## Fix Implementation

The mvnd fix was implemented in the [SWE-bench fork](https://github.com/SailorJoe6/SWE-bench) at commit `e6e3f93` on branch `arm64-support`.

### Changes Made

**File: `swebench/harness/dockerfiles/java.py`**

Added architecture-aware mvnd installation:
- `_MVND_INSTALL_AMD64` - Downloads native linux-amd64 binary from Apache Maven releases
- `_MVND_INSTALL_ARM64` - Creates `mvnd` → `mvn` symlink (mvn is pure Java, already in base image)

**File: `swebench/harness/dockerfiles/__init__.py`**

Added architecture selection logic for Java language.

### Rationale

Since `mvnd` has no Linux ARM64 releases but `mvn` is pure Java and runs on any architecture, the fix creates a symlink. This allows build scripts that call `mvnd` to work correctly.

## Verification

### Command to Verify
```bash
docker run --rm sweb.eval.arm64.<instance>:latest ls -la /usr/local/mvnd/bin/mvnd
```

### Expected Output
```
lrwxrwxrwx 1 root root ... /usr/local/mvnd/bin/mvnd -> /usr/bin/mvn
```

### Verified Instances (All 14)
✅ **All 14 instances verified with correct symlink:**
- All 5 Apache Druid instances: `mvnd -> /usr/bin/mvn`
- All 9 Google Gson instances: `mvnd -> /usr/bin/mvn`

## Rebuild Procedure (Future Reference)

If you need to rebuild these images in the future:

### Step 1: Rebuild Apache Druid Instances
```bash
python -m swebench.harness.prepare_images \
  --dataset_name "swe-bench/SWE-bench_Multilingual" \
  --split test \
  --arch arm64 \
  --tag latest \
  --env_image_tag latest \
  --instance_ids apache__druid-13704 \
  apache__druid-14092 \
  apache__druid-14136 \
  apache__druid-15402 \
  apache__druid-16875
```

### Step 2: Rebuild Google Gson Instances
```bash
python -m swebench.harness.prepare_images \
  --dataset_name "swe-bench/SWE-bench_Multilingual" \
  --split test \
  --arch arm64 \
  --tag latest \
  --env_image_tag latest \
  --instance_ids google__gson-1014 \
  google__gson-1093 \
  google__gson-1100 \
  google__gson-2024 \
  google__gson-2061 \
  google__gson-2134 \
  google__gson-2158 \
  google__gson-2311 \
  google__gson-2479
```

### Step 3: Tag Images for SWE-agent
```bash
./scripts/tag-arm64-images.sh
```

## Related Fix: Maven Resource Bundle SNAPSHOT

A separate issue also affects all 5 Druid instances on ARM64. Apache Druid's root `pom.xml` references `org.apache.apache.resources:apache-jar-resource-bundle:1.5-SNAPSHOT`. Original x86_64 Docker images had this artifact cached locally, but fresh ARM64 rebuilds don't.

**Error:**
```
[ERROR] Failed to execute goal org.apache.maven.plugins:maven-remote-resources-plugin:1.5:process
Resources archive cannot be found.: The following artifacts could not be resolved:
org.apache.apache.resources:apache-jar-resource-bundle:jar:1.5-SNAPSHOT
```

**Fix:** Added `sed` install command to all 5 Druid specs in `swebench/harness/constants/java.py` (commit `b97b4a3`):

```python
"install": [
    r"sed -i 's/<resourceBundle>org.apache.apache.resources:apache-jar-resource-bundle:1.5-SNAPSHOT<\/resourceBundle>/<resourceBundle>org.apache.apache.resources:apache-jar-resource-bundle:1.5<\/resourceBundle>/' pom.xml",
    "mvn clean install -B -pl processing -DskipTests -am",
],
```

This runs during Docker image build, replacing the SNAPSHOT reference with the released `1.5` version before `mvn clean install`.

**Note:** This fix only affects Druid instances. Lucene (which uses Gradle, not Maven) is unaffected.

## Unaffected Instances

- **Lucene instances** - use Gradle, not Maven; no `pom.xml` at repo root
- **JavaScript instances** - use Chrome/Chromium fix, not mvnd
- **Python, Ruby, and other language instances** - do not use mvnd
- **JavaParser instances** - use `./mvnw` wrapper script, not mvnd
