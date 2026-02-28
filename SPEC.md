# YouTube Channel Monitor - Specification

## Overview
An automated system that monitors YouTube channels for new videos, downloads their transcripts, and produces detailed AI-powered summaries with timestamps and highlights. Outputs summaries to stdout for integration with other tools.

## Goals
- Automatically check YouTube channels for new content
- Download video transcripts
- Generate detailed, timestamped summaries using GLM (Zhipu AI)
- Only process each video once
- Output to stdout for pipelining
- Bypass YouTube's cloud IP blocks using proxies or official API

## Non-Goals
- Video downloading (transcripts only)
- Built-in Telegram/delivery integration (stdout only)
- Web interface or dashboard

---

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Cron      │────▶│   Bash      │────▶│   Python    │────▶│    GLM      │────▶ stdout
│  Scheduler  │     │   Monitor   │     │  Summarizer │     │    API      │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
                           │                    │
                           ▼                    ▼
                    ┌─────────────┐     ┌─────────────┐
                    │   State     │     │   Proxy /   │
                    │   Files     │     │  YouTube    │
                    └─────────────┘     │    API      │
                                        └─────────────┘
```

## Components

| Component | Language | Purpose |
|-----------|----------|---------|
| `youtube_monitor.sh` | Bash | Main orchestration, RSS fetching |
| `summarize.py` | Python | Transcript download + AI summarization |
| `config.env` | - | Configuration and API keys |
| `channels.txt` | - | List of channel IDs to monitor |
| `state/seen_videos.json` | JSON | Track all seen videos |
| `state/summarized.json` | JSON | Track fully summarized videos |

## Dependencies

**System:**
- `curl` - HTTP requests
- `jq` - JSON parsing
- `python3` - Python runtime

**Python:**
- `zhipuai` - GLM API client

**External Tools:**
- `supadata.ai` - Transcript API (primary method)
- `yt-dlp` - Video metadata and transcript fetching (fallback)
- `node` (v24+) - JavaScript runtime for YouTube's n-challenge (yt-dlp)

---

## Development Phases

### Phase 1: Foundation ✅ COMPLETED
**Goal:** Set up project structure and configuration

Deliverables:
- Project directory structure
- Configuration file template
- Channel list file
- README with setup instructions

**Success Criteria:** Empty project structure ready for development

---

### Phase 2: RSS Feed Monitor ✅ COMPLETED
**Goal:** Bash script to fetch and parse YouTube RSS feeds

Deliverables:
- `youtube_monitor.sh` - main script skeleton
- RSS feed fetching function
- XML parsing for video data (ID, title, URL, published date)
- Channel list loader
- Basic logging

**API Used:** YouTube RSS feeds (`youtube.com/feeds/videos.xml?channel_id=XXX`)

**Success Criteria:** Script can list new videos from configured channels

---

### Phase 3: State Management ✅ COMPLETED
**Goal:** Track seen and summarized videos

Deliverables:
- `state/seen_videos.json` structure and I/O
- `state/summarized.json` structure and I/O
- State update functions
- State loading on startup

**Success Criteria:** Scripts can persist and restore state between runs

---

### Phase 4: Transcript Download ✅ COMPLETED
**Goal:** Python script to fetch video transcripts

Deliverables:
- `summarize.py` - Python script
- Transcript fetching using supadata.ai (primary) and yt-dlp (fallback)
- Timestamp and segment extraction
- Error handling for missing/unavailable transcripts

**Success Criteria:** Can download transcript for any video ID

---

### Phase 5: GLM Integration ✅ COMPLETED
**Goal:** Send transcripts to GLM (Zhipu AI) for summarization

Deliverables:
- GLM API client setup
- Prompt template for timestamped summaries
- Response parsing and formatting
- Error handling for API failures

**Success Criteria:** Generates detailed summaries with timestamps and highlights

---

### Phase 6: Integration & Output ✅ COMPLETED
**Goal:** Connect all components and produce final output

Deliverables:
- Full bash + python integration
- Formatted stdout output
- State synchronization
- Comprehensive error handling

**Success Criteria:** End-to-end flow produces complete summaries

---

### Phase 7: Scheduling & Reliability ✅ COMPLETED
**Goal:** Production-ready automation

Deliverables:
- Cron job configuration
- Log rotation setup
- Retry logic
- Rate limiting

**Success Criteria:** System runs reliably via cron

---

### Phase 8: Cloud IP Bypass ✅ COMPLETED
**Goal:** Bypass YouTube's cloud IP blocks

**Issue:** YouTube blocks requests from cloud provider IPs (AWS, GCP, Azure)

**Solutions Implemented:**

1. **Supadata.ai API** ✅ IMPLEMENTED (PRIMARY)
   - Professional transcript API service
   - No authentication/IP issues
   - Supports YouTube, TikTok, Instagram, X, Facebook
   - Config: `SUPADATA_API_KEY`, `USE_SUPADATA`

2. **yt-dlp with Browser Cookies** ✅ IMPLEMENTED (FALLBACK)
   - Uses yt-dlp with exported browser cookies
   - Node.js runtime for YouTube's n-challenge solving
   - Config: `YOUTUBE_COOKIES_FILE`, `USE_YTDLP`

3. **Transcript Deduplication** ✅ IMPLEMENTED
   - Filters out short intermediate caption segments (< 0.3s)
   - Eliminates duplicate text from progressive captioning
   - Cleaner transcripts for AI summarization

---

## Data Structures

### Video Data
```json
{
  "video_id": "abc123",
  "title": "Video Title",
  "channel_id": "UCxxx",
  "channel_name": "Channel Name",
  "url": "https://youtube.com/watch?v=abc123",
  "published": "2026-02-27T10:00:00Z",
  "duration": 725
}
```

### Transcript Segment
```json
{
  "text": "Hello world",
  "start": 0.0,
  "duration": 1.5
}
```

### Seen Video Entry
```json
{
  "abc123": {
    "video_id": "abc123",
    "title": "Video Title",
    "first_seen": "2026-02-27T14:30:00Z",
    "channel_id": "UCxxx"
  }
}
```

### Summarized Entry
```json
{
  "abc123": {
    "video_id": "abc123",
    "summarized_at": "2026-02-27T14:32:00Z",
    "has_transcript": true
  }
}
```

---

## Output Format

```
========================================
📺 NEW VIDEO SUMMARY
========================================

Channel: {channel_name}
Video: "{video_title}"
URL: {video_url}
Duration: {MM:SS}
Published: {relative_time}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 OVERVIEW
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{2-3 sentence overview}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎯 KEY TOPICS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• {topic 1}
• {topic 2}
• ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⏱️ DETAILED SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[MM:SS - MM:SS] {Section Title}
{Summary of segment}

...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💡 HIGHLIGHTS & QUOTES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• [MM:SS] "{quote}"
• [MM:SS] "{quote}"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ KEY TAKEAWAYS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. {takeaway 1}
2. {takeaway 2}
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Processed: {timestamp}
========================================
```

---

## GLM Prompt Template

```
You are analyzing a YouTube video transcript. Create a detailed summary with timestamps and highlights.

Transcript with timestamps:
${TRANSCRIPT_DATA}

Please provide:

1. **Overview** - What is this video about? (2-3 sentences)

2. **Key Topics Covered** - Bullet points of main topics (3-5 items)

3. **Detailed Summary with Timestamps**
   Break down the video into logical sections. For each section:
   - Provide time range (start - end)
   - Give the section a descriptive title
   - Summarize what's covered in 2-3 sentences

4. **Highlights & Quotes** - Notable insights or memorable quotes with timestamps (3-5 items)

5. **Takeaways** - 3-5 key actionable points or conclusions

Format the output cleanly in plain text. Use emojis as section markers:
📋 for Overview
🎯 for Key Topics
⏱️ for Detailed Summary
💡 for Highlights & Quotes
✅ for Key Takeaways
```

---

## Error Handling

| Error Type | Handling |
|------------|----------|
| Network timeout | Retry once, then skip |
| RSS parse error | Log warning, continue to next channel |
| No transcript available | Log warning, mark as seen, skip |
| Transcript API rate limit | Exponential backoff |
| GLM API error | Log error, skip video, retry next run |
| Invalid video ID | Skip and continue |
| Missing config | Exit with error message |
| State file corruption | Recreate from scratch |
| Cookies expired | Re-export cookies from browser |

---

## Configuration

`config.env`:
```bash
# GLM API (Zhipu AI)
GLM_API_KEY="..."
GLM_MODEL="glm-4.7"

# Supadata.ai Configuration (primary transcript method)
SUPADATA_API_KEY="..."
USE_SUPADATA="true"

# yt-dlp Configuration (fallback transcript method)
YOUTUBE_COOKIES_FILE="/path/to/youtube_cookies.txt"
USE_YTDLP="true"

# Processing
MAX_VIDEOS_PER_RUN=3
TRANSCRIPT_CACHE_DIR="./transcripts"

# State
STATE_DIR="./state"
LOG_DIR="./logs"
```

`channels.txt`:
```
# One channel ID per line
UCBJycsmduvYEL83R_U4JriQ
UC8butISFpTf7lLu4Pso3EKg
```

---

## Testing Strategy

### Unit Testing
- Transcript fetch function
- State file I/O
- GLM prompt formatting

### Integration Testing
- Full RSS → transcript → summary flow
- State persistence across runs
- Error recovery

### Manual Testing
1. Add test channel ID
2. Run script manually
3. Verify output format
4. Run again (verify no duplicates)
5. Add new video to channel
6. Run again (verify new video processed)

---

## Known Issues

| Issue | Status | Solution |
|-------|--------|----------|
| YouTube blocks cloud IPs | ✅ SOLVED | Supadata.ai API (primary) + yt-dlp fallback |
| Supadata.ai rate limits | ⚠️ MAINTENANCE | Falls back to yt-dlp automatically |
| Cookies may expire periodically | ⚠️ MAINTENANCE | Re-export cookies when needed |
| yt-dlp requires Node.js for n-challenge | ✅ DOCUMENTED | Node.js v24+ recommended |
