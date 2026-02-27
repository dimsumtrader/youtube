# YouTube Channel Monitor - Specification

## Overview
An automated system that monitors YouTube channels for new videos, downloads their transcripts, and produces detailed AI-powered summaries with timestamps and highlights. Outputs summaries to stdout for integration with other tools.

## Goals
- Automatically check YouTube channels for new content
- Download video transcripts
- Generate detailed, timestamped summaries using OpenAI
- Only process each video once
- Output to stdout for pipelining

## Non-Goals
- Video downloading (transcripts only)
- Built-in Telegram/delivery integration (stdout only)
- Web interface or dashboard

---

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Cron      │────▶│   Bash      │────▶│   Python    │────▶│   OpenAI    │────▶ stdout
│   Scheduler │     │   Monitor   │     │   Summarizer│     │   API       │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │   State     │
                    │   Files     │
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
- `youtube-transcript-api` - Transcript fetching
- `openai` - OpenAI API client
- `requests` - HTTP library

---

## Development Phases

### Phase 1: Foundation
**Goal:** Set up project structure and configuration

Deliverables:
- Project directory structure
- Configuration file template
- Channel list file
- README with setup instructions

**Success Criteria:** Empty project structure ready for development

---

### Phase 2: RSS Feed Monitor
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

### Phase 3: State Management
**Goal:** Track seen and summarized videos

Deliverables:
- `state/seen_videos.json` structure and I/O
- `state/summarized.json` structure and I/O
- State update functions
- State loading on startup

**Success Criteria:** Scripts can persist and restore state between runs

---

### Phase 4: Transcript Download
**Goal:** Python script to fetch video transcripts

Deliverables:
- `summarize.py` - Python script
- Transcript fetching using `youtube-transcript-api`
- Timestamp and segment extraction
- Error handling for missing/unavailable transcripts
- Fallback mechanisms

**Success Criteria:** Can download transcript for any video ID

---

### Phase 5: OpenAI Integration
**Goal:** Send transcripts to OpenAI for summarization

Deliverables:
- OpenAI API client setup
- Prompt template for timestamped summaries
- Response parsing and formatting
- Error handling for API failures

**Success Criteria:** Generates detailed summaries with timestamps and highlights

---

### Phase 6: Integration & Output
**Goal:** Connect all components and produce final output

Deliverables:
- Full bash + python integration
- Formatted stdout output
- State synchronization
- Comprehensive error handling

**Success Criteria:** End-to-end flow produces complete summaries

---

### Phase 7: Scheduling & Reliability
**Goal:** Production-ready automation

Deliverables:
- Cron job configuration
- Log rotation setup
- Retry logic
- Rate limiting

**Success Criteria:** System runs reliably via cron

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

## OpenAI Prompt Template

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

Format the output cleanly in plain text. Use emojis as section markers.
```

---

## Error Handling

| Error Type | Handling |
|------------|----------|
| Network timeout | Retry once, then skip |
| RSS parse error | Log warning, continue to next channel |
| No transcript available | Log warning, mark as seen, skip |
| Transcript API rate limit | Exponential backoff |
| OpenAI API error | Log error, skip video, retry next run |
| Invalid video ID | Skip and continue |
| Missing config | Exit with error message |
| State file corruption | Recreate from scratch |

---

## Configuration

`config.env`:
```bash
# OpenAI API
OPENAI_API_KEY="sk-..."
OPENAI_MODEL="gpt-4o"

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
- OpenAI prompt formatting

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
