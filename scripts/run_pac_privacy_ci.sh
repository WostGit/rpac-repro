#!/usr/bin/env bash
set -Eeuo pipefail

EXPERIMENT_INPUT="${1:-Iris_s.py}"
EXPERIMENT="$EXPERIMENT_INPUT"
if [[ "$EXPERIMENT" != "Iris_s.py" && "$EXPERIMENT" != "MNIST_s.py" ]]; then
  echo "Invalid experiment '$EXPERIMENT'; defaulting to Iris_s.py"
  EXPERIMENT="Iris_s.py"
fi

VENV_DIR="${VENV_DIR:-.venv}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/ztao10086/Residual-PAC-Privacy.git}"
RESULTS_DIR="${RESULTS_DIR:-artifacts}"
MAX_INSTALL_RETRIES="${MAX_INSTALL_RETRIES:-10}"

mkdir -p "$RESULTS_DIR"
LOG_FILE="$RESULTS_DIR/run.log"
METRICS_FILE="$RESULTS_DIR/metrics.json"
TIME_FILE="$RESULTS_DIR/time.txt"
DIAG_FILE="$RESULTS_DIR/diagnostics.txt"
: > "$LOG_FILE"

rm -rf upstream_repo
git clone --depth 1 "$UPSTREAM_REPO" upstream_repo >> "$LOG_FILE" 2>&1
cd upstream_repo

failure_diagnostics() {
  {
    echo "==== FAILURE DIAGNOSTICS ===="
    echo "Date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "Python executable: $(command -v python || true)"
    python --version || true
    echo
    echo "---- pip freeze ----"
    pip freeze || true
    echo
    echo "---- tail -n 200 run.log ----"
    tail -n 200 "../$LOG_FILE" || true
  } > "../$DIAG_FILE"
}
trap 'failure_diagnostics' ERR

recreate_venv() {
  rm -rf "$VENV_DIR"
  python -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip setuptools wheel >> "../$LOG_FILE" 2>&1
}

validate_venv_health() {
  [[ -x "$VENV_DIR/bin/python" ]] || return 1
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python - <<'PY'
import importlib
for m in ("pip", "setuptools", "wheel"):
    importlib.import_module(m)
print("venv-health-ok")
PY
}

install_from_readme_with_retries() {
  local attempt=1
  local backoff=2
  while (( attempt <= MAX_INSTALL_RETRIES )); do
    echo "Install attempt ${attempt}/${MAX_INSTALL_RETRIES}" | tee -a "../$LOG_FILE"
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"

    set +e
    python - <<'PY' >> "../$LOG_FILE" 2>&1
import pathlib
import subprocess
import sys

readme = pathlib.Path("README.md")
if not readme.exists():
    print("README.md not found", file=sys.stderr)
    sys.exit(10)

commands = []
for line in readme.read_text(encoding="utf-8", errors="ignore").splitlines():
    s = line.strip()
    if s.startswith("pip install") or s.startswith("python -m pip install"):
        commands.append(s)

if not commands and pathlib.Path("requirements.txt").exists():
    commands = ["python -m pip install -r requirements.txt"]

if not commands:
    print("No dependency installation commands found in README.md/requirements.txt", file=sys.stderr)
    sys.exit(11)

for c in commands:
    print(f"Running: {c}")
    if subprocess.run(c, shell=True).returncode != 0:
      print(f"Failed command: {c}", file=sys.stderr)
      sys.exit(12)
PY
    rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
      echo "Dependency installation succeeded." | tee -a "../$LOG_FILE"
      return 0
    fi

    echo "Dependency installation failed on attempt ${attempt}." | tee -a "../$LOG_FILE"
    if (( attempt == MAX_INSTALL_RETRIES )); then
      return 1
    fi
    sleep "$backoff"
    backoff=$((backoff * 2))
    attempt=$((attempt + 1))
  done
}

validate_required_imports() {
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python - "$1" <<'PY'
import pathlib
import re
import sys

pkg_to_import = {
  "scikit-learn": "sklearn",
  "pillow": "PIL",
  "pyyaml": "yaml",
  "opencv-python": "cv2",
}
mods = {"numpy", "scipy"}
readme = pathlib.Path("README.md")
if readme.exists():
  for line in readme.read_text(encoding="utf-8", errors="ignore").splitlines():
    s = line.strip()
    if s.startswith("pip install") or s.startswith("python -m pip install"):
      for p in s.split():
        if p.startswith("-") or p in {"pip", "install", "python", "-m"} or p.startswith("http"):
          continue
        base = re.split(r"[<>=\[]", p)[0].strip().lower()
        if base:
          mods.add(pkg_to_import.get(base, base.replace('-', '_')))

experiment = pathlib.Path(sys.argv[1])
if experiment.exists():
  txt = experiment.read_text(encoding="utf-8", errors="ignore")
  for m in re.findall(r"^\s*import\s+([A-Za-z0-9_\.]+)", txt, re.M):
    mods.add(m.split('.')[0])
  for m in re.findall(r"^\s*from\s+([A-Za-z0-9_\.]+)\s+import\s+", txt, re.M):
    mods.add(m.split('.')[0])

skip = {"os","sys","math","time","json","typing","pathlib","random","itertools","collections","argparse"}
for mod in sorted(m for m in mods if m and m not in skip):
  __import__(mod)
print("import-validation-ok")
PY
}

if ! validate_venv_health; then
  echo "Venv missing/corrupt. Recreating." | tee -a "../$LOG_FILE"
  recreate_venv
fi

if ! install_from_readme_with_retries; then
  echo "ERROR: dependency installation failed after retries." | tee -a "../$LOG_FILE"
  exit 41
fi

if ! validate_required_imports "$EXPERIMENT"; then
  echo "Import validation failed. Rebuilding venv and reinstalling once." | tee -a "../$LOG_FILE"
  recreate_venv
  install_from_readme_with_retries
  validate_required_imports "$EXPERIMENT"
fi

EXTRA_ARGS=()
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
set +e
HELP_TEXT=$(python "$EXPERIMENT" --help 2>&1)
HELP_RC=$?
set -e
if [[ $HELP_RC -eq 0 || "$HELP_TEXT" == *"usage"* ]]; then
  [[ "$HELP_TEXT" == *"--batch-size"* ]] && EXTRA_ARGS+=("--batch-size" "1")
  [[ "$HELP_TEXT" == *"--epochs"* ]] && EXTRA_ARGS+=("--epochs" "1")
  [[ "$HELP_TEXT" == *"--repeat"* ]] && EXTRA_ARGS+=("--repeat" "1")
  [[ "$HELP_TEXT" == *"--repeats"* ]] && EXTRA_ARGS+=("--repeats" "1")
  [[ "$HELP_TEXT" == *"--trials"* ]] && EXTRA_ARGS+=("--trials" "1")
  [[ "$HELP_TEXT" == *"--samples"* ]] && EXTRA_ARGS+=("--samples" "16")
  [[ "$HELP_TEXT" == *"--subset"* ]] && EXTRA_ARGS+=("--subset" "16")
  [[ "$HELP_TEXT" == *"--shard"* ]] && EXTRA_ARGS+=("--shard" "1")
  [[ "$HELP_TEXT" == *"--seed"* ]] && EXTRA_ARGS+=("--seed" "0")
fi

echo "Running $EXPERIMENT with args: ${EXTRA_ARGS[*]:-(none)}" | tee -a "../$LOG_FILE"
set +e
timeout 20m /usr/bin/time -v -o "../$TIME_FILE" python "$EXPERIMENT" "${EXTRA_ARGS[@]}" >> "../$LOG_FILE" 2>&1
RUN_RC=$?
set -e

if [[ $RUN_RC -eq 124 ]]; then
  echo "ERROR: experiment exceeded time limit." | tee -a "../$LOG_FILE"
  exit 51
elif [[ $RUN_RC -ne 0 ]]; then
  echo "ERROR: experiment crashed with exit code $RUN_RC." | tee -a "../$LOG_FILE"
  exit 52
fi

python - <<'PY'
import json
import math
import pathlib
import re
import sys

log_path = pathlib.Path("../artifacts/run.log")
time_path = pathlib.Path("../artifacts/time.txt")
metrics_path = pathlib.Path("../artifacts/metrics.json")

text = log_path.read_text(encoding="utf-8", errors="ignore")
if re.search(r"\b(nan|inf)\b", text, flags=re.I):
  print("Found NaN/inf in output", file=sys.stderr)
  sys.exit(61)

candidates = []
patterns = [
  r"(?:PAC[^\n]{0,60}?bound[^\n]{0,20}?[:=]\s*)([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)",
  r"(?:privacy[^\n]{0,60}?bound[^\n]{0,20}?[:=]\s*)([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)",
  r"(?:epsilon[^\n]{0,20}?[:=]\s*)([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)",
  r"(?:bound[^\n]{0,20}?[:=]\s*)([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)",
]
for p in patterns:
  for m in re.finditer(p, text, flags=re.I):
    try:
      v = float(m.group(1))
      if math.isfinite(v):
        candidates.append(v)
    except Exception:
      pass

if not candidates:
  print("No valid PAC-style privacy bound found in output", file=sys.stderr)
  sys.exit(62)
bound = candidates[-1]

runtime_sec = None
peak_kb = None
if time_path.exists():
  ttxt = time_path.read_text(encoding="utf-8", errors="ignore")
  m1 = re.search(r"Elapsed \(wall clock\) time .*?:\s*(\d+):(\d+\.?\d*)", ttxt)
  if m1:
    runtime_sec = int(m1.group(1)) * 60 + float(m1.group(2))
  m2 = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", ttxt)
  if m2:
    peak_kb = int(m2.group(1))

metrics_path.write_text(json.dumps({
  "pac_privacy_bound": bound,
  "runtime_seconds": runtime_sec,
  "peak_memory_kb": peak_kb,
}, indent=2), encoding="utf-8")
PY
