#!/usr/bin/env bash
set -euo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_tmp="$(mktemp -d /tmp/laixin-kickoff-skillopt.XXXXXX)"
trap 'rm -rf -- "$probe_tmp"' EXIT

/Users/pingxia/projects/SkillOpt/.venv/bin/python \
  /Users/pingxia/projects/SkillOpt/outputs/skill_probe_template/run_static_benchmark.py \
  --config "$skill_dir/probes/skillopt-config.json" \
  --tasks "$skill_dir/probes/skillopt-tasks.json" \
  --out "$probe_tmp/static-report.json"
