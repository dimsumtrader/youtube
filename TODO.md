# YouTube Channel Monitor - TODO

## Completed ✅

### Foundation
- [x] Project structure (state/, logs/, transcripts/)
- [x] Configuration file template (config.env)
- [x] Channel list (channels.txt)
- [x] .gitignore (state and transcripts now tracked)
- [x] README with setup instructions

### Core Components
- [x] `youtube_monitor.sh` - Main orchestration script
- [x] `summarize.py` - Transcript download + AI summarization
- [x] `add_channel.sh` - Add new channel, pre-populate recent videos

### State Management
- [x] Simplified to single state file (`seen_videos.json`)
- [x] Removed `summarized.json` (redundant)
- [x] `seen_videos.json` tracks processed videos
- [x] Videos added to state after successful summarization
- [x] Metadata tracked: video_id, title, channel_id, channel_name, duration, view_count

### Video Discovery
- [x] yt-dlp integration for video discovery
- [x] Fetch ~50 videos per channel (actual ~100 due to yt-dlp behavior)
- [x] Skip already processed videos
- [x] Filter out Shorts (< 60 seconds)

### Transcript Download
- [x] supadata.ai API integration (primary)
- [x] yt-dlp fallback (requires cookies)
- [x] VTT parsing with deduplication
- [x] Transcript caching to disk
- [x] Metadata stored in cache (title, channel, url, published, duration)

### AI Summarization
- [x] GLM (Zhipu AI) integration
- [x] Prompt template for timestamped summaries
- [x] Structured output (Key Takeaways, Detailed Summary with Timestamps)
- [x] Exponential backoff retry logic
- [x] Max retries configuration

### Telegram Integration
- [x] Telegram bot notifications
- [x] Message formatting with HTML
- [x] Long message splitting (>4096 chars)
- [x] Configurable (USE_TELEGRAM flag)

### Error Handling
- [x] Network timeouts
- [x] Missing transcripts
- [x] API rate limits
- [x] Invalid video IDs
- [x] State file corruption handling

## Maintenance Tasks

### Regular
- [ ] Monitor GLM API usage/credits
- [ ] Monitor supadata.ai credit balance
- [ ] Re-export browser cookies if yt-dlp fails

### On Adding New Channel
- [ ] Run `./add_channel.sh <channel_id>` to pre-populate recent videos
- [ ] Optionally adjust `--limit` to control how many historical videos are tracked

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| yt-dlp requires valid cookies | ⚠️ Maintenance | Re-export when needed |
| supadata.ai rate limits | ⚠️ Maintenance | Auto-falls back to yt-dlp |
| Cookies expire periodically | ⚠️ Maintenance | Re-export from browser |
| Publish date not available without cookies | ℹ️ Info | Flat-playlist doesn't provide dates |

## Optional Enhancements

### Potential Features
- [ ] Web dashboard for viewing summaries
- [ ] Database backend for search/filter
- [ ] Multiple language support
- [ ] Video embedding in summaries
- [ ] Custom summary templates per channel
- [ ] Statistics/analytics dashboard
- [ ] API health monitoring
