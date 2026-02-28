# YouTube Channel Monitor with AI Summaries

An automated system that monitors YouTube channels for new videos, downloads their transcripts, and produces detailed AI-powered summaries with timestamps and highlights using GLM (Zhipu AI).

## Features

- **Automatic Monitoring**: Checks YouTube channels for new content via RSS feeds
- **Transcript Download**: Fetches video transcripts using supadata.ai API or yt-dlp with cookies
- **No Bot Detection**: supadata.ai and yt-dlp with browser cookies bypass YouTube's bot detection
- **AI Summarization**: Generates detailed summaries with timestamps using GLM-4
- **State Tracking**: Only processes each video once - tracks seen and summarized videos
- **Formatted Output**: Beautiful text output suitable for terminal reading or piping to other tools

## Output Format

```
========================================
📺 NEW VIDEO SUMMARY
========================================

Channel: TechLead
Video: "How I Built a $100M Company"
URL: https://youtube.com/watch?v=abc123
Published: 2 hours ago

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 OVERVIEW
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
The video chronicles the journey of building a tech startup from garage to IPO...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎯 KEY TOPICS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Initial product validation and market research
• Early team building and equity distribution
• Product-market fit and scaling challenges
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⏱️ DETAILED SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[00:00 - 03:45] The Beginning
Started with a simple problem I faced at Google...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💡 HIGHLIGHTS & QUOTES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• [05:23] "The best product is one that sells itself through word-of-mouth"
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ KEY TAKEAWAYS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Validate with real customers before building anything
2. B2B monetizes faster and more reliably than B2C
...
========================================
```

## Prerequisites

### System Requirements
- Linux/Unix system (bash, curl, jq)
- Python 3.8 or higher
- pip3

### Install System Dependencies
```bash
# Debian/Ubuntu
sudo apt-get install curl jq python3-pip

# RHEL/CentOS/Fedora
sudo dnf install curl jq python3-pip
```

### Install Python Dependencies
```bash
pip3 install zhipuai yt-dlp
```

## Setup

1. **Get a GLM API Key:**
   - Visit https://open.bigmodel.cn/
   - Sign up and get your API key

2. **Configure your API key:**
   ```bash
   # Edit config.env and add your API key
   nano config.env

   # Set: GLM_API_KEY="your-api-key-here"
   ```

3. **Add channels to monitor:**
   ```bash
   # Edit channels.txt and add one channel ID per line
   nano channels.txt
   ```

   To find a channel ID:
   - Go to the channel's YouTube page
   - View page source and search for `channelId`
   - Or use: https://commentpicker.com/youtube-channel-id/

4. **Verify setup:**
   ```bash
   ./youtube_monitor.sh
   ```

## Usage

### Manual Run
```bash
# Run the monitor manually
./youtube_monitor.sh

# Or from any directory
/root/youtube/youtube_monitor.sh
```

### Process a Single Video
```bash
# Summarize a specific video
python3 summarize.py VIDEO_ID

# With metadata
python3 summarize.py VIDEO_ID --title "Video Title" --channel "Channel Name"
```

### Schedule with Cron
```bash
# Edit crontab
crontab -e

# Add to run every 4 hours
0 */4 * * * /root/youtube/youtube_monitor.sh >> /root/youtube/logs/output.log 2>&1
```

## Configuration

Edit `config.env` to customize:

| Setting | Description | Default |
|---------|-------------|---------|
| `GLM_API_KEY` | Your Zhipu AI API key | *required* |
| `GLM_MODEL` | Model to use for summaries | `glm-4.7` |
| `MAX_VIDEOS_PER_RUN` | Max videos to process per run | `3` |
| `TRANSCRIPT_CACHE_DIR` | Directory to cache transcripts | `./transcripts` |
| `STATE_DIR` | Directory for state files | `./state` |
| `LOG_DIR` | Directory for logs | `./logs` |
| `API_CALL_DELAY` | Seconds to wait between API calls | `2` |

### Available GLM Models

| Model | Description |
|-------|-------------|
| `glm-4.7` | Latest high-performance model (recommended) |
| `glm-4-flash` | Fast, cost-effective |
| `glm-4` | Standard model |
| `glm-4-plus` | More capable model |
| `glm-4-air` | Balanced model |

### yt-dlp with Browser Cookies (Recommended)

The most reliable way to fetch transcripts - uses real browser authentication cookies to bypass bot detection.

**Cookie Export (One-Time Setup):**

1. Install a browser extension to export cookies:
   - **Chrome/Edge**: [Get cookies.txt LOCALLY](https://chrome.google.com/webstore/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbdanldgppc)
   - **Firefox**: [Get cookies.txt](https://addons.mozilla.org/en-US/firefox/addon/get-cookiestxt/)

2. Go to [youtube.com](https://youtube.com) and make sure you're logged in

3. Click the extension icon, then click "Export" and save the file as `youtube_cookies.txt`

4. Upload the file to your server:
   ```bash
   scp youtube_cookies.txt user@server:/root/youtube/
   ```

**Configure:**

```bash
# Edit config.env - the path to your cookies file
YOUTUBE_COOKIES_FILE="/root/youtube/youtube_cookies.txt"
USE_YTDLP="true"
```

**Alternative: Use Browser Directly**

If running on a machine with a browser (e.g., your local machine), yt-dlp can read cookies directly:

```bash
# Edit config.env
USE_BROWSER_COOKIES="true"
BROWSER_TYPE="chrome"  # or firefox, edge, safari, brave, opera
```

**Maintenance:**

- Cookies expire periodically (every few weeks)
- When cookies expire, simply re-export and replace the file
- You can automate cookie refresh with a scheduled task if needed

## Project Structure

```
/root/youtube/
├── youtube_monitor.sh      # Main bash script
├── summarize.py            # Python transcript + summarization script
├── config.env              # Configuration file (API keys)
├── channels.txt            # List of channel IDs to monitor
├── state/
│   ├── seen_videos.json    # All videos we've seen
│   └── summarized.json     # Videos we've fully summarized
├── transcripts/            # Cache downloaded transcripts
├── logs/                   # Script logs
└── README.md              # This file
```

## Troubleshooting

### No transcript available
- Some videos don't have transcripts enabled
- Livestreams often don't have transcripts
- Private/members-only videos can't be accessed
- Supadata.ai or yt-dlp may have temporary issues

### Supadata.ai errors
- Check your API key is valid from https://dash.supadata.ai/
- Verify you have available credits
- Check for rate limiting (consider upgrading your plan)

### yt-dlp errors
- Cookies may have expired - re-export from your browser
- Node.js may not be installed (required for YouTube's n-challenge)
- Check yt-dlp is up to date: `pip3 install --upgrade yt-dlp`

### GLM API errors
- Verify your API key is valid from https://open.bigmodel.cn/
- Check you have available quota
- The script uses exponential backoff for rate limits

### State file corruption
- Delete `state/seen_videos.json` and `state/summarized.json`
- The scripts will recreate them as empty objects

### Large videos
- Videos over 1 hour may hit token limits
- Edit `MAX_VIDEO_LENGTH_SECONDS` in config.env to skip long videos

## License

MIT
