#!/bin/bash
#
# YouTube Channel Monitor
# Fetches new videos from configured channels and generates AI summaries
#

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-/root/youtube/state}"
LOG_DIR="${LOG_DIR:-/root/youtube/logs}"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
CHANNELS_FILE="${SCRIPT_DIR}/channels.txt"
SEEN_VIDEOS_FILE="${STATE_DIR}/seen_videos.json"
SUMMARIZE_PY="${SCRIPT_DIR}/summarize.py"

# Default values (can be overridden by config.env)
MAX_VIDEOS_PER_RUN=${MAX_VIDEOS_PER_RUN:-3}
API_CALL_DELAY=${API_CALL_DELAY:-2}
MIN_VIDEO_LENGTH_SECONDS=${MIN_VIDEO_LENGTH_SECONDS:-60}

# Logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "${LOG_DIR}/monitor.log"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "${LOG_DIR}/monitor.log" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" | tee -a "${LOG_DIR}/monitor.log"
}

# Load configuration file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "Loaded configuration from $CONFIG_FILE"
    else
        log_error "Configuration file not found: $CONFIG_FILE"
        log_error "Please create config.env with your GLM API key"
        exit 1
    fi

    if [[ -z "${GLM_API_KEY:-}" ]] || [[ "$GLM_API_KEY" == "your_glm_api_key_here" ]]; then
        log_error "GLM_API_KEY not set in config.env"
        exit 1
    fi
}

# Initialize state files
init_state() {
    mkdir -p "$STATE_DIR"

    if [[ ! -f "$SEEN_VIDEOS_FILE" ]]; then
        echo "{}" > "$SEEN_VIDEOS_FILE"
        log_info "Created seen_videos.json"
    fi
}

# Load state file
load_seen_videos() {
    if [[ -f "$SEEN_VIDEOS_FILE" ]]; then
        SEEN_VIDEOS=$(cat "$SEEN_VIDEOS_FILE")
    else
        SEEN_VIDEOS="{}"
    fi
}

# Check if video has been processed
is_processed() {
    local video_id="$1"
    echo "$SEEN_VIDEOS" | jq -e ".[\"$video_id\"]" >/dev/null 2>&1
}

# Add video to processed list (after successful summarization)
add_processed_video() {
    local video_id="$1"
    local title="$2"
    local channel_id="$3"
    local channel_name="${4:-}"
    local duration="${5:-}"
    local view_count="${6:-}"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local jq_args="--arg vid $video_id --arg title $title --arg cid $channel_id --arg ts $timestamp"
    local jq_obj='{"video_id": $vid, "title": $title, "channel_id": $cid, "processed_at": $ts'

    if [[ -n "$channel_name" ]]; then
        jq_args="$jq_args --arg cname $channel_name"
        jq_obj="$jq_obj, \"channel_name\": \$cname"
    fi

    if [[ -n "$duration" ]]; then
        jq_args="$jq_args --argjson duration $duration"
        jq_obj="$jq_obj, \"duration\": \$duration"
    fi

    if [[ -n "$view_count" ]]; then
        jq_args="$jq_args --argjson view_count $view_count"
        jq_obj="$jq_obj, \"view_count\": \$view_count"
    fi

    jq_obj="$jq_obj}"

    SEEN_VIDEOS=$(eval echo "$SEEN_VIDEOS" | jq $jq_args ". + {(\$vid): $jq_obj}")

    # Atomic write
    local tmp_file
    tmp_file=$(mktemp)
    echo "$SEEN_VIDEOS" > "$tmp_file"
    mv "$tmp_file" "$SEEN_VIDEOS_FILE"
}

# Load channels from channels.txt
load_channels() {
    if [[ ! -f "$CHANNELS_FILE" ]]; then
        log_error "Channels file not found: $CHANNELS_FILE"
        exit 1
    fi

    grep -v '^[[:space:]]*#' "$CHANNELS_FILE" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

# Fetch videos from channel using yt-dlp
fetch_channel_videos() {
    local channel_id="$1"
    local max_videos="${2:-50}"

    yt-dlp --dump-json --flat-playlist --playlist-end "$max_videos" \
        --no-warnings "https://www.youtube.com/channel/$channel_id" 2>/dev/null | \
        jq -c --arg cid "$channel_id" \
            '{
                video_id: .id,
                title: .title,
                channel_id: $cid,
                channel_name: (.channel // "Unknown"),
                url: "https://youtube.com/watch?v=\(.id)",
                published: (if .upload_date and (.upload_date | length) >= 8 then "\(.upload_date[0:4])-\(.upload_date[4:6])-\(.upload_date[6:8])T00:00:00Z" else "" end),
                duration: (.duration // 0),
                view_count: (.view_count // 0)
            }' | \
        jq -s .
}

# Process a single video (summarize)
process_video() {
    local video_data="$1"

    local video_id
    video_id=$(echo "$video_data" | jq -r '.video_id')
    local title
    title=$(echo "$video_data" | jq -r '.title')
    local channel_name
    channel_name=$(echo "$video_data" | jq -r '.channel_name')
    local url
    url=$(echo "$video_data" | jq -r '.url')
    local published
    published=$(echo "$video_data" | jq -r '.published')
    local channel_id
    channel_id=$(echo "$video_data" | jq -r '.channel_id')
    local duration
    duration=$(echo "$video_data" | jq -r '.duration')
    local view_count
    view_count=$(echo "$video_data" | jq -r '.view_count')

    log_info "Processing video: $title ($video_id)"

    # Call summarize.py
    if result=$(python3 "$SUMMARIZE_PY" "$video_id" \
        --title "$title" \
        --channel "$channel_name" \
        --url "$url" \
        --published "$published" 2>&1); then

        # Print summary to stdout
        echo "$result"
        echo ""

        # Mark as processed
        add_processed_video "$video_id" "$title" "$channel_id" "$channel_name" "$duration" "$view_count"
        log_info "Successfully summarized: $title"

        # Sleep to respect API rate limits
        sleep "$API_CALL_DELAY"
        return 0
    else
        log_warn "Failed to summarize $video_id: $result"
        return 1
    fi
}

# Main execution
main() {
    local total_summarized=0
    local max_videos=$MAX_VIDEOS_PER_RUN
    local fetch_only_mode="${FETCH_ONLY:-false}"

    mkdir -p "$LOG_DIR"

    log_info "=========================================="
    if [[ "$fetch_only_mode" == "true" ]]; then
        log_info "YouTube Channel Monitor - Fetch Only Mode"
    else
        log_info "YouTube Channel Monitor - Starting"
    fi
    log_info "=========================================="

    # Load configuration
    load_config

    # Initialize state
    init_state
    load_seen_videos

    # Load channels
    local channels
    mapfile -t channels < <(load_channels)

    if [[ ${#channels[@]} -eq 0 ]]; then
        log_error "No channels found in $CHANNELS_FILE"
        exit 1
    fi

    log_info "Monitoring ${#channels[@]} channels"

    # Collect all unprocessed videos
    local all_unprocessed_videos="[]"

    # Create temp file for state
    local seen_tmp
    seen_tmp=$(mktemp)
    echo "$SEEN_VIDEOS" > "$seen_tmp"

    for channel_id in "${channels[@]}"; do
        log_info "Checking channel: $channel_id"

        local videos_json
        if videos_json=$(fetch_channel_videos "$channel_id" 50); then
            # Filter out already processed videos and Shorts
            local min_sec="${MIN_VIDEO_LENGTH_SECONDS:-60}"
            local unprocessed_videos
            unprocessed_videos=$(jq --slurpfile seen "$seen_tmp" \
                --argjson min_sec "$min_sec" \
                '[.[] | select(.video_id as $vid | $seen[0] | has($vid) | not) | select(.duration >= $min_sec)]' <<< "$videos_json")

            local unprocessed_count
            unprocessed_count=$(echo "$unprocessed_videos" | jq 'length')

            # Calculate how many were filtered as Shorts
            local short_count
            short_count=$(jq --slurpfile seen "$seen_tmp" \
                --argjson min_sec "$min_sec" \
                '[.[] | select(.video_id as $vid | $seen[0] | has($vid) | not) | select(.duration < $min_sec)] | length' <<< "$videos_json")

            # Calculate how many were already processed
            local processed_count
            processed_count=$(jq --slurpfile seen "$seen_tmp" \
                '[.[] | select(.video_id as $vid | $seen[0] | has($vid))] | length' <<< "$videos_json")

            if [[ "$processed_count" -gt 0 ]]; then
                log_info "Skipped $processed_count already processed video(s)"
            fi

            if [[ "$short_count" -gt 0 ]]; then
                log_info "Filtered out $short_count YouTube Shorts"
            fi

            if [[ "$unprocessed_count" -gt 0 ]]; then
                log_info "Found $unprocessed_count video(s) to summarize"
                all_unprocessed_videos=$(jq --argjson new "$unprocessed_videos" '. + $new' <<< "$all_unprocessed_videos")
            else
                log_info "No videos to summarize from $channel_id"
            fi
        fi

        # Save state after each channel
        local tmp_file
        tmp_file=$(mktemp)
        echo "$SEEN_VIDEOS" > "$tmp_file"
        mv "$tmp_file" "$SEEN_VIDEOS_FILE"
    done

    # Clean up temp file
    rm -f "$seen_tmp"

    # Get count of unprocessed videos
    local unprocessed_video_count
    unprocessed_video_count=$(echo "$all_unprocessed_videos" | jq 'length')

    log_info "Total videos to summarize: $unprocessed_video_count"

    if [[ "$unprocessed_video_count" -eq 0 ]]; then
        log_info "No new videos to process"
        echo ""
        echo "=========================================="
        echo "📺 YouTube Monitor - All Caught Up"
        echo "=========================================="
        echo "Checked ${#channels[@]} channels, all videos already processed."
        echo "Last check: $(date '+%Y-%m-%d %H:%M:%S UTC')"
        echo "=========================================="
        exit 0
    fi

    # Limit videos to process
    if [[ "$unprocessed_video_count" -gt "$max_videos" ]]; then
        log_info "Limiting to $max_videos videos (found $unprocessed_video_count)"
        all_unprocessed_videos=$(echo "$all_unprocessed_videos" | jq ".[0:$max_videos]")
        unprocessed_video_count=$max_videos
    fi

    # Process each unprocessed video
    echo ""
    echo "=========================================="
    echo "📺 Processing $unprocessed_video_count video(s)"
    echo "=========================================="
    echo ""

    for ((i = 0; i < unprocessed_video_count; i++)); do
        local video_data
        video_data=$(echo "$all_unprocessed_videos" | jq ".[$i]")

        local video_id
        video_id=$(echo "$video_data" | jq -r '.video_id')
        local title
        title=$(echo "$video_data" | jq -r '.title')

        log_info "Summarizing: $title ($video_id)"
        if process_video "$video_data"; then
            ((total_summarized++)) || true
        else
            log_warn "Failed to summarize $video_id - will retry on next run"
        fi
    done

    # Summary
    log_info "=========================================="
    log_info "Run complete: $total_summarized summarized"
    log_info "=========================================="

    echo ""
    echo "=========================================="
    echo "📊 Summary"
    echo "=========================================="
    echo "Summaries generated: $total_summarized"
    echo "Completed at: $(date '+%Y-%m-%d %H:%M:%S UTC')"
    echo "=========================================="
}

# Run main function
main "$@"
