#!/usr/bin/env bash
# ec2-tag-enforcer.sh
# Audits all EC2 instances for required tags. Applies defaults with --fix.
# Usage: ./ec2-tag-enforcer.sh           (audit only — read-only)
#        ./ec2-tag-enforcer.sh --fix     (apply missing tags)

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# --- Required tags from IRD-05 tag enforcement policy ---
REQUIRED_TAGS=("Project" "Environment" "Owner" "CostCenter")

# Default values applied when --fix is used
DEFAULT_PROJECT="proops2026-taskmanager"
DEFAULT_ENV="dev"
DEFAULT_OWNER="chau_tv"
DEFAULT_COSTCENTER="training"

FIX_MODE=0
REGION=""

# Proper arg parser — supports both flags in any order:
#   --fix              apply defaults to missing tags
#   --region <name>    audit a specific region without editing the file
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)
            FIX_MODE=1
            shift
            ;;
        --region)
            [[ -z "${2:-}" ]] && { printf 'ERROR: --region requires a value\n' >&2; exit 2; }
            REGION="$2"
            shift 2
            ;;
        *)
            printf 'ERROR: unknown argument: %s\n' "$1" >&2
            printf 'Usage: %s [--fix] [--region <region>]\n' "$0" >&2
            exit 2
            ;;
    esac
done

# Exporting AWS_DEFAULT_REGION makes every subsequent aws call target that region
# without needing to pass --region to each one individually.
[[ -n "$REGION" ]] && export AWS_DEFAULT_REGION="$REGION"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
MISSING_COUNT=0

printf '\n=== EC2 Tag Audit  %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Region : %s\n' "${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo default)}"
[[ $FIX_MODE -eq 0 ]] && printf '(read-only — use --fix to apply missing tags)\n'
printf '\n'

# Get all non-terminated instance IDs in one API call.
# --filters excludes terminated instances (they can't be re-tagged and just add noise).
# mapfile requires bash 4+; macOS ships bash 3.2, so use a while-read loop instead.
# grep -v: drop empty lines and the literal "None" AWS CLI emits when result is null.
INSTANCE_IDS=()
while IFS= read -r iid; do
    [[ -n "$iid" ]] && INSTANCE_IDS+=("$iid")
done < <(
    aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text | tr '\t' '\n' | grep -v -e '^$' -e '^None$'
)

if [[ ${#INSTANCE_IDS[@]} -eq 0 ]]; then
    printf 'No non-terminated instances found — nothing to audit.\n\n'
    exit 0
fi

for instance_id in "${INSTANCE_IDS[@]}"; do
    # Fetch only the tag keys for this instance (values not needed for the check)
    existing_keys=$(
        aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --query 'Reservations[0].Instances[0].Tags[].Key' \
            --output text
    )

    missing=()     # bash array — starts empty each iteration

    # Check each required tag against what's present
    for tag in "${REQUIRED_TAGS[@]}"; do
        # grep -w matches whole words — safe because tag keys never contain spaces
        if ! grep -qw "$tag" <<< "$existing_keys"; then
            missing+=("$tag")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        printf "${GREEN}[OK  ]${NC} %s — all tags present\n" "$instance_id"
    else
        printf "${YELLOW}[MISS]${NC} %s — missing: %s\n" \
            "$instance_id" "${missing[*]}"
        MISSING_COUNT=$(( MISSING_COUNT + 1 ))

        if [[ $FIX_MODE -eq 1 ]]; then
            # Build the tag list from ONLY the missing tags — never overwrite existing ones
            tag_args=()
            for tag in "${missing[@]}"; do
                case "$tag" in
                    Project)     tag_args+=("Key=Project,Value=${DEFAULT_PROJECT}") ;;
                    Environment) tag_args+=("Key=Environment,Value=${DEFAULT_ENV}") ;;
                    Owner)       tag_args+=("Key=Owner,Value=${DEFAULT_OWNER}") ;;
                    CostCenter)  tag_args+=("Key=CostCenter,Value=${DEFAULT_COSTCENTER}") ;;
                esac
            done
            aws ec2 create-tags --resources "$instance_id" --tags "${tag_args[@]}"
            printf '         → applied: %s\n' "${missing[*]}"
        fi
    fi
done

printf '\n--- %d instance(s) had missing tags ---\n\n' "$MISSING_COUNT"
# In --fix mode we applied defaults — exit 0 so callers know the run succeeded.
# In audit mode a non-zero count means action is required — exit 1 to signal that.
if [[ $FIX_MODE -eq 1 ]]; then
    exit 0
else
    [[ $MISSING_COUNT -eq 0 ]] || exit 1
fi
