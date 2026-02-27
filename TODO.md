# YouTube Channel Monitor - TODO

## Phase 1: Foundation ✅ COMPLETED

- [x] Create project directory structure
  - [x] `state/` directory for state files
  - [x] `logs/` directory for logs
  - [x] `transcripts/` directory for cached transcripts (optional)
- [x] Create `config.env` template file
  - [x] GLM_API_KEY placeholder
  - [x] GLM_MODEL setting
  - [x] MAX_VIDEOS_PER_RUN setting
  - [x] Directory paths (TRANSCRIPT_CACHE_DIR, STATE_DIR, LOG_DIR)
- [x] Create `channels.txt` template file
  - [x] Include instructions/comments
  - [x] Add example channel IDs
- [x] Create `.gitignore` file
  - [x] Ignore `config.env`
  - [x] Ignore `state/`
  - [x] Ignore `transcripts/`
  - [x] Ignore `logs/`
  - [x] Ignore `__pycache__/`, `*.pyc`
- [x] Create `README.md` with setup instructions
  - [x] Prerequisites (curl, jq, python3, pip)
  - [x] Python dependencies install command
  - [x] Configuration steps
  - [x] Usage examples

## Phase 2: RSS Feed Monitor ✅ COMPLETED

- [x] Create `youtube_monitor.sh` script header
  - [x] Shebang (#!/bin/bash)
  - [x] Set strict mode (`set -euo pipefail`)
  - [x] Script constants and paths
- [x] Add configuration loading function
  - [x] Source `config.env` if exists
  - [x] Validate required variables
  - [x] Set defaults for optional variables
- [x] Add channel list loading function
  - [x] Read `channels.txt`
  - [x] Filter out comments and empty lines
  - [x] Validate channel ID format
- [x] Add RSS feed fetching function
  - [x] `fetch_rss(channel_id)` using curl
  - [x] Handle network errors
  - [x] Timeout handling
- [x] Add RSS parsing function
  - [x] Extract video IDs from XML
  - [x] Extract titles
  - [x] Extract publication dates
  - [x] Extract channel name
  - [x] Build video data structure
- [x] Add main loop skeleton
  - [x] Iterate through channels
  - [x] Call fetch and parse functions
  - [x] Collect new videos
  - [x] Output video count

## Phase 3: State Management ✅ COMPLETED

- [x] Create `state/seen_videos.json` structure
  - [x] Initialize empty JSON object if doesn't exist
  - [x] Define schema in comments
- [x] Create `state/summarized.json` structure
  - [x] Initialize empty JSON object if doesn't exist
  - [x] Define schema in comments
- [x] Add state loading functions to bash script
  - [x] `load_seen_videos()` - read and parse JSON
  - [x] `load_summarized()` - read and parse JSON
  - [x] Handle missing/corrupt files gracefully
- [x] Add state update functions to bash script
  - [x] `add_seen_video(video_id, data)` - append to seen_videos.json
  - [x] `is_seen(video_id)` - check if video in seen_videos
  - [x] `is_summarized(video_id)` - check if video in summarized
  - [x] `mark_summarized(video_id)` - add to summarized.json
- [x] Add state persistence
  - [x] Atomic file writes (write to temp, then mv)
  - [x] Handle write failures
- [x] Integrate state into main loop
  - [x] Filter out seen videos from RSS results
  - [x] Add new videos to seen_videos
  - [x] Save state after each channel

## Phase 4: Transcript Download (Python) ✅ COMPLETED

- [x] Create `summarize.py` script
  - [x] Shebang and encoding
  - [x] argparse for command line arguments
  - [x] Logging setup
- [x] Add configuration loading
  - [x] Load from `config.env` or environment
  - [x] Validate GLM_API_KEY
- [x] Add transcript fetching function
  - [x] Install/import `youtube_transcript_api`
  - [x] `get_transcript(video_id)` function
  - [x] Handle multiple languages (prefer English)
  - [x] Fallback to auto-generated if manual not available
- [x] Add transcript formatting
  - [x] Convert segments to readable format
  - [x] Include timestamps
  - [x] Clean up text (remove [Music], etc.)
- [x] Add error handling
  - [x] Transcript not available
  - [x] Private video
  - [x] Geoblocked content
  - [x] Network errors
- [x] Add CLI interface
  - [x] Accept video_id as argument
  - [x] Output summary to stdout
  - [x] `--force` flag to re-process
  - [x] `--debug` flag for verbose output

## Phase 5: GLM Integration ✅ COMPLETED

- [x] Add GLM client setup
  - [x] Install/import `zhipuai` package
  - [x] Initialize client with API key
  - [x] Configure model (glm-4-flash, glm-4, glm-4-plus)
- [x] Create prompt template
  - [x] Load prompt template from constant
  - [x] Format transcript data for prompt
- [x] Add summarization function
  - [x] `summarize_with_glm(transcript_data, video_info)`
  - [x] Call GLM API with prompt
  - [x] Handle response
  - [x] Parse and return formatted summary
- [x] Add output formatting
  - [x] Wrap GLM response in header/footer
  - [x] Include video metadata (title, URL, etc.)
  - [x] Add processing timestamp
- [x] Add error handling
  - [x] API rate limits - retry with exponential backoff
  - [x] Invalid API key
  - [x] Insufficient quota
  - [x] Timeout handling
- [x] Add token counting and limits
  - [x] Truncate transcript if too long
  - [x] Configurable max length

## Phase 6: Integration & Output ✅ COMPLETED

- [x] Wire bash script to Python summarizer
  - [x] Call `summarize.py` for each new video
  - [x] Capture stdout output
  - [x] Pass video metadata to Python
- [x] Implement full processing flow
  - [x] Fetch RSS → Parse → Filter (seen/summarized)
  - [x] For each new video: get transcript → summarize → output
  - [x] Mark as summarized after success
  - [x] Mark as seen (even if transcript fails)
- [x] Add video metadata output
  - [x] Channel name
  - [x] Video title
  - [x] URL
  - [x] Publish time (relative format)
- [x] Implement summary separator
  - [x] Visual separator between videos
  - [x] Summary of run (X new videos, Y summarized)
- [x] Add progress indicators
  - [x] Show which channel is being processed
  - [x] Show which video is being summarized
- [x] Handle "no new videos" case
  - [x] Print friendly message
  - [x] Still exit 0

## Phase 7: Scheduling & Reliability ✅ COMPLETED

- [x] Create cron configuration example
  - [x] Add to README
  - [x] Show scheduling options
- [x] Add retry logic
  - [x] Retry failed GLM API calls
  - [x] Exponential backoff
- [x] Add rate limiting
  - [x] Respect MAX_VIDEOS_PER_RUN
  - [x] Sleep between API calls (API_CALL_DELAY)
- [x] Add run statistics
  - [x] Log start/end time
  - [x] Log success/failure counts
- [x] Add health check function
  - [x] Verify config file exists
  - [x] Verify API key is set
  - [x] Verify channels.txt has entries

## Testing & Polish ⚠️ PENDING USER TESTING

- [ ] Manual testing
  - [ ] Test with real channel (has new videos)
  - [ ] Test with channel that has no new videos
  - [ ] Test with video without transcript
  - [ ] Test state persistence (run twice)
  - [ ] Test error conditions (bad API key, etc.)
- [x] Add debug mode
  - [x] `--debug` flag
  - [x] Verbose logging
- [ ] Add dry-run mode (OPTIONAL)
  - [ ] `--dry-run` flag
  - [ ] Show what would be done
  - [ ] Don't call APIs
  - [ ] Don't update state
- [x] Code cleanup
  - [x] Add comments to complex sections
  - [x] Consistent error messages
- [x] Documentation
  - [x] Update README with actual usage
  - [x] Add troubleshooting section
  - [x] Add example output

## Future Enhancements (Out of Scope)

- [ ] Support for YouTube Data API (for community posts, etc.)
- [ ] Multi-language transcript support
- [ ] Chunking for very long transcripts
- [ ] Summarization in parallel (multiple videos at once)
- [ ] Web dashboard
- [ ] Configurable output formats (JSON, markdown, etc.)
- [ ] Notification integrations (built-in Telegram, email)
