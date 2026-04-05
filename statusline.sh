#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract fields
cwd=$(echo "$input" | jq -r '.workspace.current_dir // ""')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
tokens=$(echo "$input" | jq -r '(.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0)')
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

# --- Fetch real usage limits from Anthropic API (cached) ---
USAGE_CACHE="/tmp/claude-statusline-usage.json"
USAGE_CACHE_AGE=60  # refresh every 60 seconds

fetch_usage() {
  local creds token response
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
  token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken') || return 1
  [ -z "$token" ] || [ "$token" = "null" ] && return 1

  response=$(curl -s --max-time 3 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" 2>/dev/null) || return 1

  echo "$response" | jq -e '.five_hour' >/dev/null 2>&1 || return 1
  echo "$response" > "$USAGE_CACHE"
}

# Refresh cache if stale or missing
if [ ! -f "$USAGE_CACHE" ] || [ $(($(date +%s) - $(stat -f %m "$USAGE_CACHE" 2>/dev/null || echo 0))) -gt $USAGE_CACHE_AGE ]; then
  fetch_usage 2>/dev/null
fi

# Read cached usage data
usage_5h=""
usage_7d=""
resets_5h_label=""
resets_7d_label=""

if [ -f "$USAGE_CACHE" ]; then
  usage_5h=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)
  usage_7d=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)

  # Calculate reset time labels
  resets_5h=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  if [ -n "$resets_5h" ]; then
    reset_epoch=$(date -juf "%Y-%m-%dT%H:%M:%S" "$(echo "$resets_5h" | cut -d. -f1 | sed 's/+.*//')" +%s 2>/dev/null)
    [ -n "$reset_epoch" ] && resets_5h_label=$(date -r "$reset_epoch" '+%-l:%M%p' | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  fi

  resets_7d=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  if [ -n "$resets_7d" ]; then
    reset_epoch=$(date -juf "%Y-%m-%dT%H:%M:%S" "$(echo "$resets_7d" | cut -d. -f1 | sed 's/+.*//')" +%s 2>/dev/null)
    [ -n "$reset_epoch" ] && resets_7d_label=$(date -r "$reset_epoch" '+%a %-l%p' | tr '[:upper:]' '[:lower:]')
  fi
fi

# --- Progress bar renderer ---
bar() {
  local pct=$1 label=$2 w=${3:-12}
  local filled=$(( (pct * w + 50) / 100 ))
  [ "$filled" -gt "$w" ] && filled=$w
  local empty=$((w - filled))
  local b=""
  for ((i=0; i<filled; i++)); do b+="▓"; done
  for ((i=0; i<empty; i++)); do b+="░"; done

  local color
  if (( pct < 50 )); then color='\033[2m\033[32m'
  elif (( pct < 80 )); then color='\033[33m'
  else color='\033[91m'
  fi

  printf "${color}%s %s %d%%\033[0m" "$label" "$b" "$pct"
}

# --- Git status (cached) ---
GIT_CACHE="/tmp/claude-statusline-git.txt"
GIT_CACHE_AGE=5

git_info="\033[90m<no repo>\033[0m"
if [ -n "$cwd" ]; then
  if [ ! -f "$GIT_CACHE" ] || [ $(($(date +%s) - $(stat -f %m "$GIT_CACHE" 2>/dev/null || echo 0))) -gt $GIT_CACHE_AGE ]; then
    if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
      branch=$(git -C "$cwd" branch --show-current 2>/dev/null || echo "detached")
      gst=$(git -C "$cwd" status -s 2>/dev/null)
      staged=$(echo "$gst" | grep -c '^[MADRC]')
      modified=$(echo "$gst" | grep -c '^.[MD]')
      untracked=$(echo "$gst" | grep -c '^??')
      deleted=$(echo "$gst" | grep -c '^.D\|^D')
      renamed=$(echo "$gst" | grep -c '^R')
      echo "$branch|$staged|$modified|$untracked|$deleted|$renamed" > "$GIT_CACHE"
    else
      echo "|||||" > "$GIT_CACHE"
    fi
  fi

  IFS='|' read -r branch staged modified untracked deleted renamed < "$GIT_CACHE"
  if [ -n "$branch" ]; then
    git_info="\033[35m$branch\033[0m"
    parts=""
    (( staged > 0 ))    && parts="${parts} \033[32mS:${staged}\033[0m"
    (( modified > 0 ))  && parts="${parts} \033[33mM:${modified}\033[0m"
    (( deleted > 0 ))   && parts="${parts} \033[31mD:${deleted}\033[0m"
    (( renamed > 0 ))   && parts="${parts} \033[34mR:${renamed}\033[0m"
    (( untracked > 0 )) && parts="${parts} \033[31m??:${untracked}\033[0m"
    [ -n "$parts" ] && git_info="$git_info |$parts"
  fi
fi

# --- Output ---

# Format session tokens
tokens_fmt=$(awk -v t="$tokens" 'BEGIN{if(t>=1000000) printf "%.1fM",t/1000000; else if(t>=1000) printf "%.1fk",t/1000; else printf "%d",t}')
cost_fmt=$(printf '$%.1f' "$session_cost")

# Line 1: context bar | 5hr usage bar | weekly usage bar
line1="$(bar "$used_pct" "ctx" 10)"

if [ -n "$usage_5h" ]; then
  reset_label=""
  [ -n "$resets_5h_label" ] && reset_label=" \033[2m\033[37m@${resets_5h_label}\033[0m"
  line1="${line1} \033[2m|\033[0m $(bar "$usage_5h" "5hr" 10)${reset_label}"
fi

if [ -n "$usage_7d" ]; then
  reset_label=""
  [ -n "$resets_7d_label" ] && reset_label=" \033[2m\033[37m@${resets_7d_label}\033[0m"
  line1="${line1} \033[2m|\033[0m $(bar "$usage_7d" "wk" 10)${reset_label}"
fi

printf "%b\n" "$line1"

# Line 2: model | cost | tokens | cwd | git
printf "\033[2m\033[37m%s\033[0m \033[2m%s/%s tok\033[0m | \033[36m%s\033[0m | %b\n" \
  "$model" "$cost_fmt" "$tokens_fmt" "$(basename "$cwd")" "$git_info"
