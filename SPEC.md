# YouTube Channel Monitor - Specification

## Overview
An automated system that monitors YouTube channels for new videos, downloads their transcripts, and produces detailed AI-powered summaries. Sends summaries to Telegram and outputs to stdout.

## Goals
- Automatically check YouTube channels for new content
- Download video transcripts
- Generate detailed, timestamped summaries using GLM (Zhipu AI)
- Send summaries to Telegram bot
- Only process each video once
- Pre-populate state to skip channel backlogs

## Non-Goals
- Video downloading (transcripts only)
- Web interface or dashboard

---

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Cron      │────▶│   Bash      │────▶│   Python    │────▶│    GLM      │────▶│  Telegram   │
│  Scheduler  │     │   Monitor   │     │  Summarizer │     │    API      │     │     Bot     │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
                           │                    │                    │
                           ▼                    ▼                    ▼
                    ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
                    │   State     │     │   yt-dlp    │     │  supadata   │
                    │   Files     │     │  (videos)   │     │    API      │
                    └─────────────┘     └─────────────┘     └─────────────┘
```

## Components

| Component | Language | Purpose |
|-----------|----------|---------|
| `youtube_monitor.sh` | Bash | Main orchestration, video discovery |
| `summarize.py` | Python | Transcript download + AI summarization |
| `add_channel.sh` | Bash | Add new channel, pre-populate recent videos |
| `config.env` | - | Configuration and API keys |
| `channels.txt` | - | List of channel IDs to monitor |
| `state/seen_videos.json` | JSON | Track processed videos |
| `transcripts/` | JSON | Cached video transcripts |

## Dependencies

**System:**
- `yt-dlp` - YouTube video discovery
- `jq` - JSON parsing
- `python3` - Python runtime

**Python:**
- `zhipuai` - GLM API client

**External APIs:**
- `supadata.ai` - Transcript API (primary method)
- GLM API (Zhipu AI) - AI summarization
- Telegram Bot API - Notifications

---

## State Management (Simplified)

**Single State File:** `state/seen_videos.json`

Tracks all videos that have been processed. Videos in this file are skipped on subsequent runs.

### Video Entry Structure
```json
{
  "video_id": {
    "video_id": "abc123",
    "title": "Video Title",
    "channel_id": "UCxxx",
    "channel_name": "Channel Name",
    "processed_at": "2026-02-28T12:00:00Z",
    "duration": 2920,
    "view_count": 25000
  }
}
```

### Adding New Channels
```bash
./add_channel.sh UCxxxxxx
```

This pre-populates the last ~50 videos from a channel into `seen_videos.json`, so the monitor won't try to summarize the entire backlog.

---

## How It Works

### Monitor Flow
1. **Discovery** - Fetch latest ~50 videos per channel using yt-dlp
2. **Filter** - Skip videos already in `seen_videos.json` and Shorts (< 60s)
3. **Process** - For each new video:
   - Download transcript (supadata.ai primary, yt-dlp fallback)
   - Generate AI summary via GLM
   - Send to Telegram
   - Add to `seen_videos.json`
4. **Rate Limit** - Process max `MAX_VIDEOS_PER_RUN` videos per run

### Output Format
```
========================================
📺 NEW VIDEO SUMMARY
========================================

Channel: My First Million
Video: "Why the Self-Help Industry Is Built on Lies"
URL: https://youtube.com/watch?v=abc123

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Key Takeaways
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Insight 1
• Insight 2
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⏱️ Detailed Summary with Timestamps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[00:00 - 03:30] Introduction
Summary of the introduction...

...

========================================
Processed: February 28, 2026 @ 12:00 UTC
========================================
```

---

## Configuration

`config.env`:
```bash
# GLM API (Zhipu AI)
GLM_API_KEY="..."
GLM_MODEL="glm-4.7"

# Supadata.ai Configuration (transcripts)
SUPADATA_API_KEY="..."
USE_SUPADATA="true"

# Telegram Notifications
TELEGRAM_BOT_TOKEN="..."
TELEGRAM_CHAT_ID="..."
USE_TELEGRAM="true"

# Processing
MAX_VIDEOS_PER_RUN=3
API_CALL_DELAY=2
MIN_VIDEO_LENGTH_SECONDS=60
TRANSCRIPT_CACHE_DIR="./transcripts"
STATE_DIR="./state"
LOG_DIR="./logs"
```

`channels.txt`:
```bash
# My First Million
UCyaN6mg5u8Cjy2ZI4ikWaug

# All In Podcast
UCESLZhusAkFfsNsApnjF_Cg
```

---

## Usage

### Running the Monitor
```bash
# Normal run
./youtube_monitor.sh

# Fetch transcripts only (no summarization)
FETCH_ONLY=true ./youtube_monitor.sh
```

### Adding a New Channel
```bash
# Pre-populate last ~50 videos (won't be summarized)
./add_channel.sh UCxxxxxx

# Custom limit
./add_channel.sh UCxxxxxx --limit 100

# Dry run
./add_channel.sh UCxxxxxx --dry-run
```

### Summarizing a Single Video
```bash
./summarize.py abc123 \
  --title "Video Title" \
  --channel "Channel Name" \
  --url "https://youtube.com/watch?v=abc123"
```

---

## Error Handling

| Error Type | Handling |
|------------|----------|
| No transcript available | Log warning, skip video |
| GLM API error | Log error, retry with exponential backoff |
| Telegram send failure | Log warning, continue |
| Missing config | Exit with error message |
| State file corruption | Recreate from scratch |
| Cookies expired | Fall back to supadata.ai |

---

## Data Structures

### Transcript Segment
```json
{
  "text": "Hello world",
  "start": 0.0,
  "duration": 1.5
}
```

### Transcript Cache Entry
```json
{
  "video_id": "abc123",
  "language": "en",
  "segments": [...],
  "cached_at": "2026-02-28T12:00:00Z",
  "title": "Video Title",
  "channel_name": "Channel Name",
  "url": "https://youtube.com/watch?v=abc123",
  "published": "2026-02-27T10:00:00Z",
  "duration": 2920
}
```

---

## Current Status

**Channels Monitored:** 9
- My First Million
- All In
- Diary of a CEO
- Lenny's
- Colin and Samir
- Created Jon Youshaei
- Monetary Matters
- 1000x
- MacroVoices

**Videos Tracked:** ~874 (pre-populated, will be skipped)

**Only NEW videos will be summarized going forward.**
