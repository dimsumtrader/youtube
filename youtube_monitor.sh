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
SUMMARIZED_FILE="${STATE_DIR}/summarized.json"
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
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log_info "Loaded configuration from $CONFIG_FILE"
    else
        log_error "Configuration file not found: $CONFIG_FILE"
        log_error "Please create config.env with your GLM API key"
        exit 1
    fi

    # Validate required settings (check for GLM_API_KEY)
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

    if [[ ! -f "$SUMMARIZED_FILE" ]]; then
        echo "{}" > "$SUMMARIZED_FILE"
        log_info "Created summarized.json"
    fi
}

# Load state files
load_seen_videos() {
    if [[ -f "$SEEN_VIDEOS_FILE" ]]; then
        SEEN_VIDEOS=$(cat "$SEEN_VIDEOS_FILE")
    else
        SEEN_VIDEOS="{}"
    fi
}

load_summarized() {
    if [[ -f "$SUMMARIZED_FILE" ]]; then
        SUMMARIZED=$(cat "$SUMMARIZED_FILE")
    else
        SUMMARIZED="{}"
    fi
}

# Check if video has been seen
is_seen() {
    local video_id="$1"
    echo "$SEEN_VIDEOS" | jq -e ".[\"$video_id\"]" >/dev/null 2>&1
}

# Check if video has been summarized
is_summarized() {
    local video_id="$1"
    echo "$SUMMARIZED" | jq -e ".[\"$video_id\"]" >/dev/null 2>&1
}

# Add video to seen list
add_seen_video() {
    local video_id="$1"
    local title="$2"
    local channel_id="$3"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    SEEN_VIDEOS=$(echo "$SEEN_VIDEOS" | jq --arg vid "$video_id" \
        --arg title "$title" \
        --arg cid "$channel_id" \
        --arg ts "$timestamp" \
        '. + {($vid): {"video_id": $vid, "title": $title, "first_seen": $ts, "channel_id": $cid}}')

    # Atomic write
    local tmp_file
    tmp_file=$(mktemp)
    echo "$SEEN_VIDEOS" > "$tmp_file"
    mv "$tmp_file" "$SEEN_VIDEOS_FILE"
}

# Mark video as summarized
mark_summarized() {
    local video_id="$1"
    local has_transcript="${2:-true}"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    SUMMARIZED=$(echo "$SUMMARIZED" | jq --arg vid "$video_id" \
        --arg ht "$has_transcript" \
        --arg ts "$timestamp" \
        '. + {($vid): {"video_id": $vid, "summarized_at": $ts, "has_transcript": $ht | test("true")}}')

    # Atomic write
    local tmp_file
    tmp_file=$(mktemp)
    echo "$SUMMARIZED" > "$tmp_file"
    mv "$tmp_file" "$SUMMARIZED_FILE"
}

# Load channels from channels.txt
load_channels() {
    if [[ ! -f "$CHANNELS_FILE" ]]; then
        log_error "Channels file not found: $CHANNELS_FILE"
        exit 1
    fi

    # Filter out comments and empty lines, trim whitespace
    grep -v '^[[:space:]]*#' "$CHANNELS_FILE" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

# Fetch videos from channel using yt-dlp
fetch_channel_videos() {
    local channel_id="$1"
    local max_videos="${2:-50}"

    # Use yt-dlp to get channel videos and directly output formatted JSON
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
                duration: (.duration // 0)
            }' | \
        jq -s .
}

# Format relative time
format_relative_time() {
    local published="$1"
    local now
    now=$(date -u '+%s')
    local pub_ts
    pub_ts=$(date -u -d "$published" '+%s' 2>/dev/null || echo "$now")

    local diff=$((now - pub_ts))

    if [[ $diff -lt 3600 ]]; then
        echo "$((diff / 60)) minutes ago"
    elif [[ $diff -lt 86400 ]]; then
        echo "$((diff / 3600)) hours ago"
    elif [[ $diff -lt 604800 ]]; then
        echo "$((diff / 86400)) days ago"
    else
        date -d "$published" '+%Y-%m-%d' 2>/dev/null || echo "$published"
    fi
}

# Process a single video (fetch transcript only)
fetch_transcript_only() {
    local video_data="$1"

    local video_id
    video_id=$(echo "$video_data" | jq -r '.video_id')
    local title
    title=$(echo "$video_data" | jq -r '.title')

    log_info "Fetching transcript: $title ($video_id)"

    # Check if already cached
    local cache_dir="${TRANSCRIPT_CACHE_DIR:-./transcripts}"
    if [[ -f "$cache_dir/$video_id.json" ]]; then
        log_info "Transcript already cached: $video_id"
        return 0
    fi

    # Call summarize.py with --fetch-only (use -- to handle IDs starting with -)
    if python3 "$SUMMARIZE_PY" --fetch-only -- "$video_id" 2>&1; then
        log_info "Successfully cached transcript: $video_id"
        return 0
    else
        log_warn "Failed to fetch transcript: $video_id"
        return 1
    fi
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

        # Mark as summarized
        mark_summarized "$video_id" "true"
        log_info "Successfully summarized: $title"

        # Sleep to respect API rate limits
        sleep "$API_CALL_DELAY"
        return 0
    else
        log_warn "Failed to summarize $video_id: $result"
        # Still mark as seen so we don't retry indefinitely
        return 1
    fi
}

# Main execution
main() {
    local total_new=0
    local total_summarized=0
    local total_fetched=0
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
    load_summarized

    # Load channels
    local channels
    mapfile -t channels < <(load_channels)

    if [[ ${#channels[@]} -eq 0 ]]; then
        log_error "No channels found in $CHANNELS_FILE"
        exit 1
    fi

    log_info "Monitoring ${#channels[@]} channels"

    # Collect all unsummarized videos (including previously seen but not summarized)
    local all_unsummarized_videos="[]"

    # Create temp files for state (avoid argument length limits)
    local seen_tmp
    local summarized_tmp
    seen_tmp=$(mktemp)
    summarized_tmp=$(mktemp)
    echo "$SEEN_VIDEOS" > "$seen_tmp"
    echo "$SUMMARIZED" > "$summarized_tmp"

    for channel_id in "${channels[@]}"; do
        log_info "Checking channel: $channel_id"

        local videos_json
        if videos_json=$(fetch_channel_videos "$channel_id" 50); then
            # First, add any truly new videos to seen_videos (discovery phase)
            local truly_new_videos
            truly_new_videos=$(jq --slurpfile seen "$seen_tmp" \
                '[.[] | select(.video_id as $vid | $seen[0] | has($vid) | not)]' <<< "$videos_json")

            local truly_new_count
            truly_new_count=$(echo "$truly_new_videos" | jq 'length')

            if [[ "$truly_new_count" -gt 0 ]]; then
                log_info "Discovered $truly_new_count new video(s) from $channel_id"
                # Add each new video to seen_videos immediately
                for ((j = 0; j < truly_new_count; j++)); do
                    local new_vid_data
                    new_vid_data=$(echo "$truly_new_videos" | jq ".[$j]")
                    local new_vid_id
                    new_vid_id=$(echo "$new_vid_data" | jq -r '.video_id')
                    local new_vid_title
                    new_vid_title=$(echo "$new_vid_data" | jq -r '.title')
                    add_seen_video "$new_vid_id" "$new_vid_title" "$channel_id"
                    # Update temp file
                    echo "$SEEN_VIDEOS" > "$seen_tmp"
                done
            fi

            # Now collect unsummarized videos for processing (filter by duration and summarized status)
            local min_sec="${MIN_VIDEO_LENGTH_SECONDS:-60}"
            local unsummarized_videos
            unsummarized_videos=$(jq --slurpfile summarized "$summarized_tmp" \
                --argjson min_sec "$min_sec" \
                '[.[] | select(.video_id as $vid | $summarized[0] | has($vid) | not) | select(.duration >= $min_sec)]' <<< "$videos_json")

            local unsummarized_count
            unsummarized_count=$(echo "$unsummarized_videos" | jq 'length')

            # Calculate how many were filtered as Shorts
            local short_count
            short_count=$(jq --slurpfile summarized "$summarized_tmp" \
                --argjson min_sec "$min_sec" \
                '[.[] | select(.video_id as $vid | $summarized[0] | has($vid) | not) | select(.duration < $min_sec)] | length' <<< "$videos_json")

            if [[ "$short_count" -gt 0 ]]; then
                log_info "Filtered out $short_count YouTube Shorts from $channel_id"
            fi

            if [[ "$unsummarized_count" -gt 0 ]]; then
                log_info "Found $unsummarized_count video(s) to summarize from $channel_id"
                all_unsummarized_videos=$(jq --argjson new "$unsummarized_videos" '. + $new' <<< "$all_unsummarized_videos")
            else
                log_info "No videos to summarize from $channel_id (all already processed)"
            fi
        fi

        # Save state after each channel
        local tmp_file
        tmp_file=$(mktemp)
        echo "$SEEN_VIDEOS" > "$tmp_file"
        mv "$tmp_file" "$SEEN_VIDEOS_FILE"
    done

    # Clean up temp files
    rm -f "$seen_tmp" "$summarized_tmp"

    # Get count of unsummarized videos
    local unsummarized_video_count
    unsummarized_video_count=$(echo "$all_unsummarized_videos" | jq 'length')
    total_new=$unsummarized_video_count

    log_info "Total videos to summarize: $unsummarized_video_count"

    if [[ "$unsummarized_video_count" -eq 0 ]]; then
        log_info "No new videos to process"
        echo ""
        echo "=========================================="
        echo "📺 YouTube Monitor - All Caught Up"
        echo "=========================================="
        echo "Checked ${#channels[@]} channels, all videos already summarized."
        echo "Last check: $(date '+%Y-%m-%d %H:%M:%S UTC')"
        echo "=========================================="
        exit 0
    fi

    # Limit videos to process
    if [[ "$unsummarized_video_count" -gt "$max_videos" ]]; then
        log_info "Limiting to $max_videos videos (found $unsummarized_video_count)"
        all_unsummarized_videos=$(echo "$all_unsummarized_videos" | jq ".[0:$max_videos]")
        unsummarized_video_count=$max_videos
    fi

    # Process each unsummarized video
    echo ""
    echo "=========================================="
    if [[ "$fetch_only_mode" == "true" ]]; then
        echo "📥 Fetching $unsummarized_video_count transcript(s)"
    else
        echo "📺 Processing $unsummarized_video_count video(s)"
    fi
    echo "=========================================="
    echo ""

    for ((i = 0; i < unsummarized_video_count; i++)); do
        local video_data
        video_data=$(echo "$all_unsummarized_videos" | jq ".[$i]")

        local video_id
        video_id=$(echo "$video_data" | jq -r '.video_id')
        local title
        title=$(echo "$video_data" | jq -r '.title')

        if [[ "$fetch_only_mode" == "true" ]]; then
            log_info "Fetching transcript: $title ($video_id)"
            if fetch_transcript_only "$video_data"; then
                ((total_fetched++)) || true
            fi
        else
            log_info "Summarizing: $title ($video_id)"
            if process_video "$video_data"; then
                ((total_summarized++)) || true
            else
                log_warn "Failed to summarize $video_id - will retry on next run"
            fi
        fi
    done

    # Summary
    log_info "=========================================="
    if [[ "$fetch_only_mode" == "true" ]]; then
        log_info "Run complete: $total_new new, $total_fetched transcripts cached"
    else
        log_info "Run complete: $total_new new, $total_summarized summarized"
    fi
    log_info "=========================================="

    echo ""
    echo "=========================================="
    echo "📊 Summary"
    echo "=========================================="
    if [[ "$fetch_only_mode" == "true" ]]; then
        echo "Transcripts cached: $total_fetched"
    else
        echo "New videos found: $total_new"
        echo "Summaries generated: $total_summarized"
    fi
    echo "Completed at: $(date '+%Y-%m-%d %H:%M:%S UTC')"
    echo "=========================================="
}

# Run main function
main "$@"
