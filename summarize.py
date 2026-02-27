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
import sys
import time
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

try:
    from zhipuai import ZhipuAI
except ImportError:
    print("Error: zhipuai package not installed", file=sys.stderr)
    print("Install with: pip3 install zhipuai", file=sys.stderr)
    sys.exit(1)

try:
    from youtube_transcript_api import YouTubeTranscriptApi, NoTranscriptFound, TranscriptsDisabled, VideoUnavailable
except ImportError:
    print("Error: youtube-transcript-api not installed", file=sys.stderr)
    print("Install with: pip3 install youtube-transcript-api", file=sys.stderr)
    sys.exit(1)


# Configuration defaults for GLM
DEFAULT_MODEL = "glm-4-flash"  # Fast, cost-effective model
# Alternative models:
# "glm-4" - Standard model
# "glm-4-plus" - More capable
# "glm-4-flash" - Fast and cost-effective
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


def get_transcript(video_id: str) -> Tuple[Optional[List[Dict]], Optional[str]]:
    """
    Download transcript for a YouTube video.

    Returns:
        Tuple of (transcript_segments, language_code)
        Returns (None, None) if transcript not available
    """
    try:
        # Try to get transcript, preferring English
        transcript_list = YouTubeTranscriptApi.list_transcripts(video_id)

        # Try to find English transcript first
        try:
            transcript = transcript_list.find_transcript(['en', 'en-US', 'en-GB'])
            return transcript.fetch(), 'en'
        except NoTranscriptFound:
            # Fall back to auto-generated English
            try:
                transcript = transcript_list.find_manually_created_transcript(['en', 'en-US', 'en-GB'])
                return transcript.fetch(), 'en'
            except NoTranscriptFound:
                pass

        # No English, try any available transcript
        for transcript in transcript_list:
            return transcript.fetch(), transcript.language_code

        return None, None

    except (VideoUnavailable, TranscriptsDisabled) as e:
        print(f"Warning: Transcript not available for video {video_id}: {e}", file=sys.stderr)
        return None, None
    except Exception as e:
        print(f"Warning: Error fetching transcript: {e}", file=sys.stderr)
        return None, None


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
    return f"""You are analyzing a YouTube video transcript. Create a detailed summary with timestamps and highlights.

Transcript with timestamps:
{transcript}

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
✅ for Key Takeaways"""


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
            print("Get your API key from: https://open.bigmodel.cn/", file=sys.stderr)
            return None

    model = config.get('GLM_MODEL', os.environ.get('GLM_MODEL', DEFAULT_MODEL))

    try:
        client = ZhipuAI(api_key=api_key)
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

    output = [
        separator,
        "📺 NEW VIDEO SUMMARY",
        separator,
        "",
        f"Channel: {video_info.get('channel_name', 'Unknown')}",
        f"Video: \"{video_info.get('title', 'Unknown Title')}\"",
        f"URL: {video_info.get('url', f'https://youtube.com/watch?v={video_info.get(\"video_id\", \"\")}')}",
        f"Published: {format_relative_time(video_info.get('published', ''))}",
        "",
        section_sep,
        summary,
        "",
        section_sep,
        f"Processed: {datetime.now(timezone.utc).strftime('%B %d, %Y @ %H:%M UTC')}",
        separator,
    ]

    return '\n'.join(output)


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
                    if args.video_id in summarized:
                        print(f"Video {args.video_id} already summarized. Use --force to re-process.", file=sys.stderr)
                        sys.exit(0)
            except:
                pass

    # Download transcript
    if args.debug:
        print(f"Fetching transcript for video: {args.video_id}", file=sys.stderr)

    segments, lang = get_transcript(args.video_id)

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

    return 0


if __name__ == '__main__':
    sys.exit(main())
