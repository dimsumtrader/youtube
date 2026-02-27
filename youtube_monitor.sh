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

# Fetch RSS feed for a channel
fetch_rss() {
    local channel_id="$1"
    local rss_url="https://www.youtube.com/feeds/videos.xml?channel_id=${channel_id}"

    local response
    response=$(curl -sSL --max-time 30 --fail "$rss_url" 2>&1) || {
        log_warn "Failed to fetch RSS feed for channel $channel_id"
        return 1
    }

    echo "$response"
}

# Parse RSS feed and extract video data
parse_rss() {
    local rss_xml="$1"
    local channel_id="$2"

    # Extract channel name
    local channel_name
    channel_name=$(echo "$rss_xml" | grep -oP '<author><name>\K[^<]+' || echo "Unknown Channel")

    # Extract video entries using xmlstarlet or grep
    # Each entry has: <yt:videoId>...</yt:videoId>, <title>...</title>, <published>...</published>
    local video_ids
    local titles
    local published_dates

    video_ids=$(echo "$rss_xml" | grep -oP '<yt:videoId>\K[^<]+' || true)
    titles=$(echo "$rss_xml" | grep -oP '<media:title>\\s*\K[^<]+' || echo "$rss_xml" | grep -oP '<title>\K[^<]+' | tail -n +2 || true)
    published_dates=$(echo "$rss_xml" | grep -oP '<published>\K[^<]+' || true)

    # Return as JSON array
    local videos_json="["
    local first=true

    local vid_array
    mapfile -t vid_array <<< "$video_ids"

    local title_array
    mapfile -t title_array <<< "$titles"

    local pub_array
    mapfile -t pub_array <<< "$published_dates"

    local i=0
    for vid in "${vid_array[@]}"; do
        if [[ -n "$vid" ]]; then
            local title="${title_array[$i]:-Unknown Title}"
            local published="${pub_array[$i]:-unknown}"

            # Escape title for JSON
            title=$(echo "$title" | sed 's/"/\\"/g')

            if [[ "$first" == "true" ]]; then
                first=false
            else
                videos_json+=","
            fi

            videos_json+="{\"video_id\":\"$vid\",\"title\":\"$title\",\"channel_id\":\"$channel_id\",\"channel_name\":\"$channel_name\",\"url\":\"https://youtube.com/watch?v=$vid\",\"published\":\"$published\"}"
        fi
        ((i++)) || true
    done

    videos_json+="]"
    echo "$videos_json"
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

# Process a single video
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
    local max_videos=$MAX_VIDEOS_PER_RUN

    mkdir -p "$LOG_DIR"

    log_info "=========================================="
    log_info "YouTube Channel Monitor - Starting"
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

    # Collect all new videos
    local all_new_videos="[]"

    for channel_id in "${channels[@]}"; do
        log_info "Checking channel: $channel_id"

        local rss_xml
        if rss_xml=$(fetch_rss "$channel_id"); then
            local videos_json
            videos_json=$(parse_rss "$rss_xml" "$channel_id")

            # Filter out already seen videos
            local new_videos
            new_videos=$(echo "$videos_json" | jq --argjson seen "$SEEN_VIDEOS" '[.[] | select(.video_id as $vid | $seen | has($vid) | not)]')

            local new_count
            new_count=$(echo "$new_videos" | jq 'length')

            if [[ "$new_count" -gt 0 ]]; then
                log_info "Found $new_count new videos from $channel_id"
                all_new_videos=$(echo "$all_new_videos" | jq --argjson new "$new_videos" '. + $new')
            else
                log_info "No new videos from $channel_id"
            fi
        fi

        # Save state after each channel
        local tmp_file
        tmp_file=$(mktemp)
        echo "$SEEN_VIDEOS" > "$tmp_file"
        mv "$tmp_file" "$SEEN_VIDEOS_FILE"
    done

    # Get count of new videos
    local new_video_count
    new_video_count=$(echo "$all_new_videos" | jq 'length')
    total_new=$new_video_count

    log_info "Total new videos: $new_video_count"

    if [[ "$new_video_count" -eq 0 ]]; then
        log_info "No new videos to process"
        echo ""
        echo "=========================================="
        echo "📺 YouTube Monitor - No New Videos"
        echo "=========================================="
        echo "Checked ${#channels[@]} channels, no new videos found."
        echo "Last check: $(date '+%Y-%m-%d %H:%M:%S UTC')"
        echo "=========================================="
        exit 0
    fi

    # Limit videos to process
    if [[ "$new_video_count" -gt "$max_videos" ]]; then
        log_info "Limiting to $max_videos videos (found $new_video_count)"
        all_new_videos=$(echo "$all_new_videos" | jq ".[0:$max_videos]")
        new_video_count=$max_videos
    fi

    # Process each new video
    echo ""
    echo "=========================================="
    echo "📺 Processing $new_video_count new video(s)"
    echo "=========================================="
    echo ""

    for ((i = 0; i < new_video_count; i++)); do
        local video_data
        video_data=$(echo "$all_new_videos" | jq ".[$i]")

        local video_id
        video_id=$(echo "$video_data" | jq -r '.video_id')
        local channel_id
        channel_id=$(echo "$video_data" | jq -r '.channel_id')
        local title
        title=$(echo "$video_data" | jq -r '.title')

        # Check if already summarized
        if is_summarized "$video_id"; then
            log_info "Video $video_id already summarized, skipping"
            add_seen_video "$video_id" "$title" "$channel_id"
            continue
        fi

        if process_video "$video_data"; then
            ((total_summarized++)) || true
        fi

        # Always mark as seen after processing attempt
        add_seen_video "$video_id" "$title" "$channel_id"
    done

    # Summary
    log_info "=========================================="
    log_info "Run complete: $total_new new, $total_summarized summarized"
    log_info "=========================================="

    echo ""
    echo "=========================================="
    echo "📊 Summary"
    echo "=========================================="
    echo "New videos found: $total_new"
    echo "Summaries generated: $total_summarized"
    echo "Completed at: $(date '+%Y-%m-%d %H:%M:%S UTC')"
    echo "=========================================="
}

# Run main function
main "$@"
