#!/bin/bash
#
# Add a new channel and pre-populate seen_videos.json with recent videos
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-/root/youtube/state}"
SEEN_VIDEOS_FILE="${STATE_DIR}/seen_videos.json"
CHANNELS_FILE="${SCRIPT_DIR}/channels.txt"

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

usage() {
    cat << EOF
Usage: $0 <channel_id> [options]

Add a new channel and pre-populate seen_videos.json with recent videos.

Arguments:
  channel_id    YouTube channel ID

Options:
  --limit N     Number of recent videos to track (default: 50)
  --dry-run     Show what would be done without making changes

Examples:
  $0 UCxxx                     # Track last 50 videos
  $0 UCxxx --limit 100         # Track last 100 videos
EOF
    exit 1
}

channel_id="$1"
shift

limit=50
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit) limit="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$channel_id" ]]; then
    usage
fi

if [[ "$dry_run" == "true" ]]; then
    log_info "DRY RUN MODE (last $limit videos)"
fi

mkdir -p "$STATE_DIR"
if [[ ! -f "$SEEN_VIDEOS_FILE" ]]; then
    echo "{}" > "$SEEN_VIDEOS_FILE"
fi

log_info "Fetching videos from channel: $channel_id (last $limit videos)"

# Fetch videos with limit
videos_json=$(yt-dlp --dump-json --flat-playlist --playlist-end "$limit" --no-warnings \
    "https://www.youtube.com/channel/$channel_id" 2>/dev/null | \
    jq -s '.')

if [[ -z "$videos_json" ]] || [[ "$videos_json" == "[]" ]]; then
    log_error "No videos found for channel: $channel_id"
    exit 1
fi

channel_name=$(echo "$videos_json" | jq -r '.[0].channel // "Unknown"')
video_count=$(echo "$videos_json" | jq 'length')
log_info "Found $video_count videos from \"$channel_name\""
echo ""

added=0
skipped=0
timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

for ((i = 0; i < video_count; i++)); do
    vid_data=$(echo "$videos_json" | jq ".[$i]")
    video_id=$(echo "$vid_data" | jq -r '.id')
    title=$(echo "$vid_data" | jq -r '.title')

    # Check if already exists
    if jq -e --arg vid "$video_id" '.[$vid]' "$SEEN_VIDEOS_FILE" >/dev/null 2>&1; then
        ((skipped++))
        continue
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo "  Would add: $video_id"
        ((added++))
        continue
    fi

    # Build entry - merge everything into one operation to avoid file corruption
    jq --arg vid "$video_id" \
        --arg title "$title" \
        --arg cid "$channel_id" \
        --arg cname "$channel_name" \
        --arg ts "$timestamp" \
        '. + {($vid): {video_id: $vid, title: $title, channel_id: $cid, channel_name: $cname, processed_at: $ts}}' \
        "$SEEN_VIDEOS_FILE" > "${SEEN_VIDEOS_FILE}.new"

    # Try to add duration if present
    dur_output=$(echo "$vid_data" | jq -e '.duration' 2>/dev/null) && \
    jq --arg vid "$video_id" --argjson dur "$dur_output" '.[$vid].duration = $dur' \
        "${SEEN_VIDEOS_FILE}.new" > "${SEEN_VIDEOS_FILE}.tmp" && \
    mv "${SEEN_VIDEOS_FILE}.tmp" "${SEEN_VIDEOS_FILE}.new"

    # Try to add view_count if present
    vc_output=$(echo "$vid_data" | jq -e '.view_count' 2>/dev/null) && \
    jq --arg vid "$video_id" --argjson vc "$vc_output" '.[$vid].view_count = $vc' \
        "${SEEN_VIDEOS_FILE}.new" > "${SEEN_VIDEOS_FILE}.tmp" && \
    mv "${SEEN_VIDEOS_FILE}.tmp" "${SEEN_VIDEOS_FILE}.new"

    mv "${SEEN_VIDEOS_FILE}.new" "$SEEN_VIDEOS_FILE"
    ((added++))
done

echo ""
log_info "Summary:"
echo "  Channel: $channel_name ($channel_id)"
echo "  Total videos: $video_count"
echo "  Added: $added"
echo "  Skipped: $skipped"
echo ""

if [[ "$dry_run" == "true" ]]; then
    log_info "DRY RUN COMPLETE"
else
    # Add to channels.txt if not there
    if ! grep -q "^$channel_id$" "$CHANNELS_FILE" 2>/dev/null; then
        echo "" >> "$CHANNELS_FILE"
        echo "# $channel_name" >> "$CHANNELS_FILE"
        echo "$channel_id" >> "$CHANNELS_FILE"
        log_info "Added channel to channels.txt"
    fi

    log_info "Done! Monitor will skip these and process only new videos."
fi
