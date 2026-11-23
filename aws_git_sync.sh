#!/usr/bin/env bash
# Git fast-forward synchronization for Raft-oF EC2 fleet.
# Controller-only. Never reset, clean, stash, or overwrite local changes.
set -euo pipefail
cd "$(dirname "$0")"
source ./aws_topology.conf
usage() { echo 'Usage: ./aws_git_sync.sh [--plan|--apply] [--branch ec2] [--client-ip IP] [--active-only]'; }
ACTION=plan; BRANCH=ec2; CLIENT_IP=; ACTIVE_ONLY=0
while (($#)); do
  case "$1" in
    --plan) ACTION=plan; shift ;;
    --apply) ACTION=apply; shift ;;
    --branch) BRANCH="${2:?}"; shift 2 ;;
    --client-ip) CLIENT_IP="${2:?}"; shift 2 ;;
    --active-only) ACTIVE_ONLY=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$BRANCH" != -* && "$BRANCH" != *..* ]] || { echo 'Invalid branch' >&2; exit 2; }
SSH_USER="${SSH_USER:-ubuntu}"
REMOTE_REPO="${REMOTE_REPO:-/home/$SSH_USER/Raft-oF_DICL}"
[[ "$REMOTE_REPO" =~ ^/[A-Za-z0-9_./-]+$ ]] || exit 2
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
ips=()
if (( ACTIVE_ONLY )); then
  declare -A owners=()
  for id in $NODES; do
    ips+=("${RAFT_IP[$id]}")
    slot="${VOLUME_DISK[$id]}"; owners["${slot%%:*}"]=1
  done
  for s in "${!owners[@]}"; do ips+=("${STORAGE_IP[$s]}"); done
else
  for id in 11 12 13 14 15 16 17 18 19; do ips+=("${RAFT_IP[$id]}"); done
  for s in s1 s2 s3; do ips+=("${STORAGE_IP[$s]}"); done
fi
[[ -z "$CLIENT_IP" ]] || ips+=("$CLIENT_IP")
mapfile -t ips < <(printf '%s\n' "${ips[@]}" | sed '/^$/d' | sort -u)
[[ "${#ips[@]}" -gt 0 ]] || { echo 'No hosts'; exit 2; }
# Pass branch and action as positional arguments to bash; do not interpolate into remote shell commands.
remote_check() {
  local ip="$1" action="$2"
  ssh "${ssh_opts[@]}" "$SSH_USER@$ip" "cd '$REMOTE_REPO' && bash -s -- '$BRANCH' '$action'" <<'REMOTE'
set -euo pipefail
branch="$1"; action="$2"
[[ -d .git ]] || { echo 'FAIL: not a git checkout'; exit 1; }
[[ "$(git branch --show-current)" == "$branch" ]] || { echo "FAIL: current branch is $(git branch --show-current), expected $branch"; exit 1; }
# Fail on tracked modifications, staged changes, and untracked files; do not overwrite custom scripts/config.
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || { echo 'FAIL: working tree is not clean'; git status --short; exit 1; }
if [[ "$action" == apply ]]; then
  git fetch --prune origin "$branch"
  git merge-base --is-ancestor HEAD FETCH_HEAD || { echo 'FAIL: cannot fast-forward (diverged or remote behind)'; exit 1; }
  git merge --ff-only FETCH_HEAD
else
  echo "READY branch=$branch HEAD=$(git rev-parse --short HEAD)"
fi
REMOTE
}
echo "Git sync: action=$ACTION branch=$BRANCH hosts=${#ips[@]}"
failed=0
# Two-phase: verify ALL hosts before updating ANY host.
if [[ "$ACTION" == apply ]]; then
  echo '[preflight] checking all working trees'
  for ip in "${ips[@]}"; do
    printf '%s: ' "$ip"
    if ! remote_check "$ip" plan; then failed=$((failed+1)); fi
  done
  (( failed == 0 )) || { echo "ABORT: $failed preflight failures; no updates started" >&2; exit 1; }
fi
failed=0
for ip in "${ips[@]}"; do
  printf '%s: ' "$ip"
  if ! remote_check "$ip" "$ACTION"; then failed=$((failed+1)); fi
done
(( failed == 0 )) || { echo "FAIL: $failed hosts failed; inspect per-host results" >&2; exit 1; }
echo "SUCCESS: all ${#ips[@]} hosts ${ACTION}"
