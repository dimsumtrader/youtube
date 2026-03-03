#!/usr/bin/env python3
"""
YouTube Video Transcript Downloader and Summarizer

Downloads video transcripts and generates AI-powered summaries with timestamps.
Uses GLM (Zhipu AI) for summarization.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

try:
    from zhipuai import ZhipuAI
except ImportError:
    print("Error: zhipuai package not installed", file=sys.stderr)
    print("Install with: pip3 install zhipuai", file=sys.stderr)
    sys.exit(1)


# Configuration defaults for GLM
DEFAULT_MODEL = "glm-4.7"  # Latest GLM model
# Alternative models:
# "glm-4" - Standard model
# "glm-4-plus" - More capable
# "glm-4-flash" - Fast and cost-effective
# "glm-4.7" - Latest high-performance model
DEFAULT_MAX_RETRIES = 2
DEFAULT_RETRY_DELAY = 5


def load_config() -> Dict[str, str]:
    """Load configuration from config.env file."""
    config = {}

    config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.env")
    if not os.path.exists(config_path):
        return config

    with open(config_path, 'r') as f:
        for line in f:
            line = line.strip()
            # Skip comments and empty lines
            if not line or line.startswith('#'):
                continue
            # Parse KEY=VALUE format
            if '=' in line:
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                config[key] = value

    return config


def format_timestamp(seconds: float) -> str:
    """Convert seconds to MM:SS format."""
    minutes = int(seconds // 60)
    secs = int(seconds % 60)
    return f"{minutes:02d}:{secs:02d}"


def format_time_range(start: float, end: float) -> str:
    """Convert a time range to MM:SS - MM:SS format."""
    return f"{format_timestamp(start)} - {format_timestamp(end)}"


def format_relative_time(published: str) -> str:
    """Format a published date as relative time."""
    try:
        pub_date = datetime.fromisoformat(published.replace('Z', '+00:00'))
        now = datetime.now(timezone.utc)
        diff = (now - pub_date).total_seconds()

        if diff < 3600:
            return f"{int(diff // 60)} minutes ago"
        elif diff < 86400:
            return f"{int(diff // 3600)} hours ago"
        elif diff < 604800:
            return f"{int(diff // 86400)} days ago"
        else:
            return pub_date.strftime("%Y-%m-%d")
    except:
        return published


def clean_text(text: str) -> str:
    """Clean transcript text by removing common artifacts."""
    # Remove [Music], [Applause], etc.
    text = re.sub(r'\[(Music|Applause|Laughter|Silence)\]', '', text)
    # Remove extra whitespace
    text = ' '.join(text.split())
    return text


def parse_vtt_file(vtt_path: str) -> List[Dict]:
    """Parse VTT subtitle file into segments, filtering out short intermediate captions."""
    segments = []

    with open(vtt_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Parse VTT format
    lines = content.split('\n')
    i = 0

    while i < len(lines):
        line = lines[i].strip()

        # Look for timestamp pattern: 00:00:00.000 --> 00:00:02.500
        if '-->' in line:
            # Parse both start and end times
            time_pattern = r'(\d+):(\d+):(\d+)\.(\d+)\s*-->\s*(\d+):(\d+):(\d+)\.(\d+)'
            time_match = re.search(time_pattern, line)
            if time_match:
                h1, m1, s1, ms1, h2, m2, s2, ms2 = map(int, time_match.groups())
                start = h1 * 3600 + m1 * 60 + s1 + ms1 / 1000
                end = h2 * 3600 + m2 * 60 + s2 + ms2 / 1000
                duration = end - start

                # Get text (next non-empty lines)
                i += 1
                text_lines = []
                while i < len(lines) and lines[i].strip() and '-->' not in lines[i]:
                    # Remove VTT formatting tags
                    text = re.sub(r'<[^>]+>', '', lines[i].strip())
                    # Remove positioning tags like {\an8}
                    text = re.sub(r'\{[^}]+\}', '', text)
                    # Remove common artifacts
                    text = re.sub(r'\[(Music|Applause|Laughter|Silence)\]', '', text)
                    if text:
                        text_lines.append(text)
                    i += 1

                if text_lines:
                    # Filter out very short segments (< 0.3s) - these are intermediate display states
                    if duration >= 0.3:
                        segments.append({
                            'text': ' '.join(text_lines),
                            'start': start,
                            'duration': duration
                        })

        i += 1

    return segments


def get_transcript_supadata(video_id: str, config: Dict = None) -> Tuple[Optional[List[Dict]], Optional[str]]:
    """
    Download transcript using supadata.ai API.

    Args:
        video_id: YouTube video ID
        config: Configuration dictionary

    Returns:
        Tuple of (transcript_segments, language_code)
        Returns (None, None) if transcript not available
    """
    import urllib.request
    import urllib.error

    api_key = config.get('SUPADATA_API_KEY', '') if config else ''
    if not api_key:
        api_key = os.environ.get('SUPADATA_API_KEY', '')

    if not api_key:
        print("[supadata] No SUPADATA_API_KEY configured", file=sys.stderr)
        return None, None

    url = f"https://www.youtube.com/watch?v={video_id}"
    api_url = "https://api.supadata.ai/v1/transcript"

    # Build request with URL parameter
    try:
        import urllib.parse
        params = urllib.parse.urlencode({'url': url, 'text': 'false', 'mode': 'native'})
        full_url = f"{api_url}?{params}"

        req = urllib.request.Request(full_url)
        req.add_header('x-api-key', api_key)
        req.add_header('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')

        print(f"[supadata] Fetching transcript for video {video_id}", file=sys.stderr)

        with urllib.request.urlopen(req, timeout=60) as response:
            data = json.loads(response.read().decode('utf-8'))

            # Check for async response (job ID)
            if 'jobId' in data:
                job_id = data['jobId']
                print(f"[supadata] Async job started: {job_id}, polling...", file=sys.stderr)

                # Poll for completion
                max_polls = 30
                poll_interval = 2
                for i in range(max_polls):
                    time.sleep(poll_interval)
                    status_url = f"{api_url.replace('/transcript', '')}/web/crawl/{job_id}"
                    req = urllib.request.Request(status_url)
                    req.add_header('x-api-key', api_key)

                    with urllib.request.urlopen(req, timeout=30) as status_response:
                        status_data = json.loads(status_response.read().decode('utf-8'))
                        status = status_data.get('status', '')

                        if status == 'completed':
                            data = status_data
                            break
                        elif status == 'failed':
                            print(f"[supadata] Job failed: {status_data}", file=sys.stderr)
                            return None, None

                if 'content' not in data:
                    print(f"[supadata] Job timeout or incomplete", file=sys.stderr)
                    return None, None

            # Parse response
            if 'content' not in data:
                print(f"[supadata] No content in response", file=sys.stderr)
                return None, None

            content = data['content']
            lang = data.get('lang', 'en')

            # Convert supadata format to internal format
            # supadata: offset (ms), duration (ms)
            # internal: start (seconds), duration (seconds)
            segments = []
            for item in content:
                segments.append({
                    'text': item.get('text', ''),
                    'start': item.get('offset', 0) / 1000,  # Convert ms to seconds
                    'duration': item.get('duration', 0) / 1000  # Convert ms to seconds
                })

            if segments:
                print(f"[supadata] Got transcript with {len(segments)} segments (lang: {lang})", file=sys.stderr)
                return segments, lang

            return None, None

    except urllib.error.HTTPError as e:
        # Read error response body for more details
        error_body = ""
        try:
            if e.fp:
                error_body = e.fp.read().decode('utf-8')
        except:
            pass

        if e.code == 401:
            print(f"[supadata] Authentication failed. Check your API key.", file=sys.stderr)
        elif e.code == 429:
            print(f"[supadata] Rate limit exceeded.", file=sys.stderr)
        elif e.code == 404:
            print(f"[supodata] Transcript not found for video {video_id}", file=sys.stderr)
        else:
            print(f"[supadata] HTTP error: {e.code} - {e.reason}", file=sys.stderr)
            if error_body:
                print(f"[supadata] Error response: {error_body[:500]}", file=sys.stderr)
        return None, None
    except urllib.error.URLError as e:
        print(f"[supadata] Network error: {e.reason}", file=sys.stderr)
        return None, None
    except Exception as e:
        print(f"[supadata] Error: {e}", file=sys.stderr)
        return None, None


def get_transcript_ytdlp(video_id: str, config: Dict = None) -> Tuple[Optional[List[Dict]], Optional[str]]:
    """
    Download transcript using yt-dlp with browser cookies.

    Args:
        video_id: YouTube video ID
        config: Configuration dictionary

    Returns:
        Tuple of (transcript_segments, language_code)
        Returns (None, None) if transcript not available
    """
    cookies_file = config.get('YOUTUBE_COOKIES_FILE', '') if config else ''
    use_browser_cookies = config.get('USE_BROWSER_COOKIES', 'false').lower() == 'true' if config else False

    if not cookies_file and not use_browser_cookies:
        return None, None

    # Check if yt-dlp is available
    try:
        subprocess.run(['yt-dlp', '--version'], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("[yt-dlp] yt-dlp not found. Install with: pip3 install yt-dlp", file=sys.stderr)
        return None, None

    # Build yt-dlp command - use subs-only mode with JS challenge solver
    node_path = '/root/.nvm/versions/node/v24.13.0/bin/node'
    cmd = [
        'yt-dlp',
        '--js-runtimes', f'node:{node_path}',
        '--remote-components', 'ejs:github',
        '--write-auto-subs',
        '--sub-langs', 'en',
        '--sub-format', 'vtt',
        '--no-warnings'
    ]

    # Add cookies
    if cookies_file and os.path.exists(cookies_file):
        cmd.extend(['--cookies', cookies_file])
        print(f"[yt-dlp] Using cookies file: {cookies_file}", file=sys.stderr)
    elif use_browser_cookies:
        browser = config.get('BROWSER_TYPE', 'chrome') if config else 'chrome'
        cmd.extend(['--cookies-from-browser', browser])
        print(f"[yt-dlp] Using cookies from browser: {browser}", file=sys.stderr)
    else:
        print("[yt-dlp] No cookies configured", file=sys.stderr)
        return None, None

    # Output to temp file (use .vtt extension to ensure proper naming)
    with tempfile.TemporaryDirectory() as temp_dir:
        output_path = os.path.join(temp_dir, 'subtitles')
        cmd.extend(['-o', output_path, f'https://www.youtube.com/watch?v={video_id}'])

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)

            # Check for errors in stderr
            if result.stderr and 'WARNING: video has no subtitles' in result.stderr:
                print(f"[yt-dlp] No subtitles available for video {video_id}", file=sys.stderr)
                return None, None

            # Find downloaded subtitle file (look for any .vtt file)
            vtt_files = []
            for file in os.listdir(temp_dir):
                if file.endswith('.vtt') or file.endswith('.en.vtt'):
                    vtt_files.append(os.path.join(temp_dir, file))

            # Also check if yt-dlp wrote to the exact output path
            if os.path.exists(output_path + '.en.vtt'):
                vtt_files.append(output_path + '.en.vtt')
            elif os.path.exists(output_path + '.vtt'):
                vtt_files.append(output_path + '.vtt')

            if not vtt_files:
                print(f"[yt-dlp] No subtitle file downloaded for video {video_id}", file=sys.stderr)
                if result.stderr:
                    print(f"[yt-dlp] stderr: {result.stderr[:500]}", file=sys.stderr)
                return None, None

            # Use the first VTT file found
            vtt_path = vtt_files[0]
            segments = parse_vtt_file(vtt_path)

            if segments:
                print(f"[yt-dlp] Got transcript with {len(segments)} segments", file=sys.stderr)
                return segments, 'en'

            return None, None

        except subprocess.TimeoutExpired:
            print(f"[yt-dlp] Timeout fetching transcript for video {video_id}", file=sys.stderr)
            return None, None
        except Exception as e:
            print(f"[yt-dlp] Error: {e}", file=sys.stderr)
            return None, None


def get_cached_transcript(video_id: str, config: Dict = None) -> Optional[Tuple[List[Dict], str]]:
    """
    Check if transcript is cached on disk.

    Args:
        video_id: YouTube video ID
        config: Configuration dictionary

    Returns:
        Tuple of (segments, language) if cached, None otherwise
    """
    cache_dir = config.get('TRANSCRIPT_CACHE_DIR', './transcripts') if config else './transcripts'
    cache_file = os.path.join(cache_dir, f"{video_id}.json")

    if os.path.exists(cache_file):
        try:
            with open(cache_file, 'r') as f:
                cached = json.load(f)
            print(f"[Cache] Using cached transcript for {video_id}", file=sys.stderr)
            return cached['segments'], cached.get('language', 'en')
        except Exception as e:
            print(f"[Cache] Error reading cache: {e}", file=sys.stderr)
    return None


def save_transcript_cache(video_id: str, segments: List[Dict], language: str, config: Dict = None, metadata: Dict = None) -> bool:
    """
    Save transcript to disk cache.

    Args:
        video_id: YouTube video ID
        segments: Transcript segments
        language: Language code
        config: Configuration dictionary
        metadata: Optional dict with video info (title, channel, url, published, duration)

    Returns:
        True if saved successfully, False otherwise
    """
    cache_dir = config.get('TRANSCRIPT_CACHE_DIR', './transcripts') if config else './transcripts'
    os.makedirs(cache_dir, exist_ok=True)
    cache_file = os.path.join(cache_dir, f"{video_id}.json")

    try:
        cache_data = {
            'video_id': video_id,
            'language': language,
            'segments': segments,
            'cached_at': datetime.now(timezone.utc).isoformat()
        }

        # Add metadata if provided
        if metadata:
            if 'title' in metadata and metadata['title']:
                cache_data['title'] = metadata['title']
            if 'channel_name' in metadata and metadata['channel_name']:
                cache_data['channel_name'] = metadata['channel_name']
            if 'url' in metadata and metadata['url']:
                cache_data['url'] = metadata['url']
            if 'published' in metadata and metadata['published']:
                cache_data['published'] = metadata['published']
            if 'duration' in metadata and metadata['duration']:
                cache_data['duration'] = metadata['duration']

        with open(cache_file, 'w') as f:
            json.dump(cache_data, f, indent=2)
        print(f"[Cache] Saved transcript to {cache_file}", file=sys.stderr)
        return True
    except Exception as e:
        print(f"[Cache] Error saving transcript: {e}", file=sys.stderr)
        return False


def get_transcript(video_id: str, config: Dict = None, use_cache: bool = True, metadata: Dict = None) -> Tuple[Optional[List[Dict]], Optional[str]]:
    """
    Download transcript for a YouTube video.

    Tries supadata.ai API first, then falls back to yt-dlp.

    Args:
        video_id: YouTube video ID
        config: Configuration dictionary (optional)
        use_cache: Whether to check/use cache (default: True)

    Returns:
        Tuple of (transcript_segments, language_code)
        Returns (None, None) if transcript not available
    """
    # Check cache first
    if use_cache:
        cached = get_cached_transcript(video_id, config)
        if cached:
            return cached

    segments, lang = None, None

    # Try supadata.ai API first (if API key is configured)
    use_supadata = config.get('USE_SUPADATA', 'true').lower() == 'true' if config else True
    if use_supadata:
        print("[Transcript] Trying supadata.ai...", file=sys.stderr)
        segments, lang = get_transcript_supadata(video_id, config)

    # Fall back to yt-dlp with cookies
    if not segments:
        use_ytdlp = config.get('USE_YTDLP', 'true').lower() == 'true' if config else True
        if use_ytdlp:
            print("[Transcript] Trying yt-dlp...", file=sys.stderr)
            segments, lang = get_transcript_ytdlp(video_id, config)

    # Save to cache if we got a transcript
    if segments and lang:
        save_transcript_cache(video_id, segments, lang, config, metadata)

    return segments, lang


def format_transcript_for_prompt(segments: List[Dict], max_length: int = 50000) -> str:
    """
    Format transcript segments for the AI prompt.

    Groups consecutive segments and formats with timestamps.
    """
    if not segments:
        return ""

    formatted_lines = []
    current_segment = []
    segment_start = segments[0]['start']
    last_end = segments[0]['start']

    for seg in segments:
        text = clean_text(seg['text'])
        start = seg['start']
        duration = seg.get('duration', 0)
        end = start + duration

        # If there's a gap longer than 10 seconds, start a new segment
        if start - last_end > 10 and current_segment:
            # Flush current segment
            if current_segment:
                segment_text = ' '.join(current_segment)
                formatted_lines.append(f"[{format_timestamp(segment_start)}] {segment_text}")
            current_segment = [text]
            segment_start = start
        else:
            current_segment.append(text)

        last_end = end

    # Flush last segment
    if current_segment:
        segment_text = ' '.join(current_segment)
        formatted_lines.append(f"[{format_timestamp(segment_start)}] {segment_text}")

    result = '\n'.join(formatted_lines)

    # Truncate if too long (rough estimate: 1 char ≈ 0.3 tokens)
    if len(result) > max_length:
        result = result[:max_length] + "\n[Transcript truncated due to length...]"

    return result


def create_summary_prompt(transcript: str) -> str:
    """Create the prompt for summarization."""
    return f"""You are analyzing a YouTube video transcript. Create a concise summary.

Transcript with timestamps:
{transcript}

Please provide these 2 sections (keep total output under 2500 characters):

1. Key Takeaways - 4-5 brief insights as bullet points (start each line with "•")

2. Detailed Summary with Timestamps - Break into 6-8 even sections covering the ENTIRE video:
   - Distribute sections evenly across the full video timeline
   - Each section should cover approximately 1/6 to 1/8 of the video
   - Include ALL major topics from beginning to end
   - Time range (start - end)
   - Section title
   - 2-3 sentences summary

Be concise. Do NOT use asterisks or bold markers in your output.

Section headers must be exactly:
Key Takeaways
Detailed Summary with Timestamps"""


def summarize_with_glm(transcript: str, video_info: Dict, config: Dict) -> Optional[str]:
    """
    Send transcript to GLM (Zhipu AI) for summarization.

    Args:
        transcript: Formatted transcript text
        video_info: Video metadata dictionary
        config: Configuration dictionary

    Returns:
        Summary text or None if failed
    """
    api_key = config.get('GLM_API_KEY', os.environ.get('GLM_API_KEY'))
    if not api_key:
        # Try legacy OPENAI_API_KEY for compatibility
        api_key = config.get('OPENAI_API_KEY', os.environ.get('OPENAI_API_KEY'))
        if not api_key:
            print("Error: GLM_API_KEY not set in config.env", file=sys.stderr)
            print("Get your API key from: https://z.ai/", file=sys.stderr)
            return None

    model = config.get('GLM_MODEL', os.environ.get('GLM_MODEL', DEFAULT_MODEL))

    try:
        client = ZhipuAI(api_key=api_key, base_url='https://api.z.ai/api/coding/paas/v4')
    except Exception as e:
        print(f"Error initializing GLM client: {e}", file=sys.stderr)
        return None

    prompt = create_summary_prompt(transcript)

    max_retries = int(config.get('MAX_RETRIES', DEFAULT_MAX_RETRIES))
    retry_delay = int(config.get('RETRY_DELAY', DEFAULT_RETRY_DELAY))

    for attempt in range(max_retries + 1):
        try:
            print(f"Calling GLM API (model: {model})...", file=sys.stderr)
            response = client.chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": "You are a helpful assistant that creates detailed, well-structured summaries of YouTube video transcripts."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.7,
                max_tokens=4000,
            )

            return response.choices[0].message.content

        except Exception as e:
            print(f"Warning: GLM API error: {e}", file=sys.stderr)
            if attempt < max_retries:
                wait_time = retry_delay * (2 ** attempt)  # Exponential backoff
                print(f"Retrying in {wait_time} seconds...", file=sys.stderr)
                time.sleep(wait_time)
            else:
                return None

    return None


def format_output(summary: str, video_info: Dict) -> str:
    """Format the final output with headers and metadata."""
    separator = "=" * 40
    section_sep = "━" * 40

    # Build URL separately to avoid nested f-string issues
    video_id = video_info.get('video_id', '')
    url = video_info.get('url', '')
    if not url and video_id:
        url = f'https://youtube.com/watch?v={video_id}'

    # Get metadata with fallbacks
    channel = video_info.get('channel_name', 'Unknown')
    title = video_info.get('title', 'Unknown Title')
    published = video_info.get('published', '')

    output = [
        f"<b>Channel:</b> {channel}",
        f"<b>Video:</b> \"{title}\"",
        f"<b>URL:</b> {url}",
    ]

    if published:
        output.append(f"<b>Published:</b> {format_relative_time(published)}")

    # Add bold tags and emojis to section headers in summary
    summary_bolded = summary.replace("Key Takeaways", "<b>✅ Key Takeaways</b>")
    summary_bolded = summary_bolded.replace("Detailed Summary with Timestamps", "<b>⏱️ Detailed Summary with Timestamps</b>")

    # Add italic tags to timestamp section headers only (not descriptions)
    lines = summary_bolded.split('\n')
    formatted_lines = []
    for line in lines:
        # Check if line looks like a timestamp header (e.g., "00:00 - 03:30" or "00:00 - 09:30: Title")
        # Only italicize the line if it starts with a timestamp pattern
        if re.match(r'^\d{2}:\d{2}\s*-\s*(\d{2}:\d{2}|End)', line):
            formatted_lines.append(f"<i>{line}</i>")
        else:
            formatted_lines.append(line)
    summary_bolded = '\n'.join(formatted_lines)

    output.extend([
        "",
        section_sep,
        summary_bolded,
        "",
        section_sep,
        f"<i>Processed: {datetime.now(timezone.utc).strftime('%B %d, %Y @ %H:%M UTC')}</i>",
        separator,
    ])

    return '\n'.join(output)


def send_to_telegram(message: str, config: Dict = None) -> bool:
    """Send message to Telegram bot."""
    use_telegram = config.get('USE_TELEGRAM', 'false').lower() == 'true' if config else False
    if not use_telegram:
        return False

    bot_token = config.get('TELEGRAM_BOT_TOKEN', '') if config else ''
    chat_id = config.get('TELEGRAM_CHAT_ID', '') if config else ''

    if not bot_token or not chat_id:
        print("[Telegram] TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not configured", file=sys.stderr)
        return False

    try:
        import urllib.request
        import urllib.parse

        max_length = 4096
        messages = []
        if len(message) <= max_length:
            messages.append(message)
        else:
            paragraphs = message.split('\n\n')
            current = ""
            for para in paragraphs:
                if len(current) + len(para) + 2 <= max_length:
                    current += para + "\n\n"
                else:
                    if current:
                        messages.append(current.strip())
                    current = para + "\n\n"
            if current:
                messages.append(current.strip())

        url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
        for msg in messages:
            data = urllib.parse.urlencode({
                'chat_id': chat_id,
                'text': msg,
                'parse_mode': 'HTML'
            }).encode('utf-8')

            req = urllib.request.Request(url, data=data, method='POST')
            with urllib.request.urlopen(req, timeout=30) as response:
                result = json.loads(response.read().decode('utf-8'))
                if not result.get('ok'):
                    print(f"[Telegram] Error: {result}", file=sys.stderr)
                    return False

        print(f"[Telegram] Sent {len(messages)} message(s)", file=sys.stderr)
        return True

    except Exception as e:
        print(f"[Telegram] Error sending message: {e}", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(
        description='Download YouTube video transcript and generate AI summary using GLM'
    )
    parser.add_argument('video_id', help='YouTube video ID')
    parser.add_argument('--title', default='', help='Video title')
    parser.add_argument('--channel', default='', help='Channel name')
    parser.add_argument('--url', default='', help='Video URL')
    parser.add_argument('--published', default='', help='Publication date')
    parser.add_argument('--force', action='store_true', help='Force re-processing even if already summarized')
    parser.add_argument('--debug', action='store_true', help='Enable debug output')
    parser.add_argument('--fetch-only', action='store_true', help='Only fetch and cache transcript, skip summarization')
    parser.add_argument('--summarize-only', action='store_true', help='Only summarize using cached transcript (skip fetch)')

    args = parser.parse_args()

    # Load configuration
    config = load_config()

    # Build video info
    video_info = {
        'video_id': args.video_id,
        'title': args.title,
        'channel_name': args.channel,
        'url': args.url or f'https://youtube.com/watch?v={args.video_id}',
        'published': args.published,
    }

    # Check if already summarized (unless --force)
    if not args.force:
        state_dir = config.get('STATE_DIR', os.path.join(os.path.dirname(__file__), 'state'))
        summarized_file = os.path.join(state_dir, 'summarized.json')
        if os.path.exists(summarized_file):
            try:
                with open(summarized_file, 'r') as f:
                    summarized = json.load(f)
                    if args.video_id in summarized and not args.summarize_only:
                        print(f"Video {args.video_id} already summarized. Use --force to re-process.", file=sys.stderr)
                        sys.exit(0)
            except:
                pass

    # Fetch-only mode: just get and cache the transcript
    if args.fetch_only:
        print(f"[Fetch-only] Getting transcript for {args.video_id}", file=sys.stderr)

        # Build metadata dict from args
        metadata = {
            'title': args.title,
            'channel_name': args.channel,
            'url': args.url,
            'published': args.published
        }

        segments, lang = get_transcript(args.video_id, config, use_cache=False, metadata=metadata)

        if not segments:
            print(f"Error: No transcript available for video {args.video_id}", file=sys.stderr)
            sys.exit(1)

        print(f"[Fetch-only] Successfully cached {len(segments)} segments", file=sys.stderr)
        print(f"[Fetch-only] Cached to: {config.get('TRANSCRIPT_CACHE_DIR', './transcripts')}/{args.video_id}.json")
        return 0

    # Summarize-only mode: use cached transcript
    if args.summarize_only:
        print(f"[Summarize-only] Using cached transcript for {args.video_id}", file=sys.stderr)

        # Load cached data to get metadata
        cache_dir = config.get('TRANSCRIPT_CACHE_DIR', './transcripts')
        cache_file = os.path.join(cache_dir, f"{args.video_id}.json")
        cached_data = None
        if os.path.exists(cache_file):
            try:
                with open(cache_file, 'r') as f:
                    cached_data = json.load(f)
            except Exception as e:
                print(f"[Summarize-only] Error loading cache: {e}", file=sys.stderr)

        if not cached_data:
            print(f"Error: No cached transcript found for {args.video_id}", file=sys.stderr)
            sys.exit(1)

        segments = cached_data.get('segments', [])
        lang = cached_data.get('language', 'en')

        # Update video_info from cached metadata if available
        if 'title' in cached_data:
            video_info['title'] = cached_data['title']
        if 'channel_name' in cached_data:
            video_info['channel_name'] = cached_data['channel_name']
        if 'url' in cached_data:
            video_info['url'] = cached_data['url']
        if 'published' in cached_data:
            video_info['published'] = cached_data['published']

        print(f"[Summarize-only] Loaded {len(segments)} segments from cache", file=sys.stderr)
    else:
        # Normal mode: fetch transcript (with cache enabled)
        if args.debug:
            print(f"Fetching transcript for video: {args.video_id}", file=sys.stderr)

        # Build metadata for cache
        metadata = {
            'title': args.title,
            'channel_name': args.channel,
            'url': args.url or f'https://youtube.com/watch?v={args.video_id}',
            'published': args.published
        }

        segments, lang = get_transcript(args.video_id, config, metadata=metadata)

        if not segments:
            print(f"Error: No transcript available for video {args.video_id}", file=sys.stderr)
            sys.exit(1)

        if args.debug:
            print(f"Got transcript with {len(segments)} segments (language: {lang})", file=sys.stderr)

    # Format transcript
    transcript_text = format_transcript_for_prompt(segments)

    if not transcript_text:
        print("Error: Failed to format transcript", file=sys.stderr)
        sys.exit(1)

    # Get summary from GLM
    summary = summarize_with_glm(transcript_text, video_info, config)

    if not summary:
        print("Error: Failed to generate summary", file=sys.stderr)
        sys.exit(1)

    # Format and print output
    output = format_output(summary, video_info)
    print(output)

    # Send to Telegram if enabled
    if config:
        send_to_telegram(output, config)

    return 0


if __name__ == '__main__':
    sys.exit(main())
