# Studio: Notion, OCR, podcast transcription, and highlight chat

Studio adds four optional workflows. They are off until you choose an operation;
there are no automatic AI calls or Notion writes. Local annotations remain usable
without any service account.

## OCR

On macOS, choose **Studio → Choose image or PDF**. Apple Vision recognizes the
text locally. Studio stores recognized pages as a capture. Select a page, correct
recognition mistakes, and save a passage to Highlights with a note, tags, and an
optional linked book. Use Export full text to keep all recognized text.

Studio settings controls recognition languages and the maximum PDF pages (1–50,
default 10). Multiple languages can be selected. Images are downsampled to 2400
pixels for recognition; PDF pages are rendered at a bounded size. PDFs with more
pages than the configured limit show a partial-processing notice. Locked PDFs,
unsupported languages, or unreadable images fail without uploading the file.

This is OCR of user-selected files; it does not bypass DRM or scan folders in the
background. A Tesseract helper is also available for Linux tests, but the macOS
application uses Apple Vision and does not require Tesseract.

## Podcast transcription

Choose a downloaded audio file in Studio. Local mode converts it to mono 16 kHz
WAV with ffmpeg, then runs a user-selected whisper.cpp executable and GGML model.
Arguments are passed directly, without a shell. Temporary WAV/JSON outputs are
removed after processing. Local processing can be cancelled; child processes are
terminated together. A one-hour processing timeout prevents a stuck job.

On a Mac, install whisper.cpp and ffmpeg from a trusted source, obtain a model
from the [official whisper.cpp model collection](https://github.com/ggml-org/whisper.cpp/tree/master/models),
verify the published checksum, then select the executable, model, and ffmpeg in
Studio. Shelf does not silently install or execute a downloaded program. An
English-only `.en` model recognizes English; choose a multilingual model for
Japanese and other languages. Audio language accepts `auto` or a code such as
`en` or `ja`. The selected language is for recognition, not translation.

The optional OpenAI provider uploads the selected audio only after the per-request
consent checkbox is checked. It uses the fixed OpenAI audio transcription endpoint
and `whisper-1`, with a 24 MB input limit. Local paths and personal filenames are
not sent. Network requests can fail or finish after the connection is interrupted;
local cancellation does not revoke a cloud upload or prevent its billing.

You can also import existing UTF-8 TXT, SRT, or VTT transcripts without a model or
an account. Timestamped transcripts keep cue times. Review a segment, correct the
text, and save an excerpt to Highlights. The excerpt retains a timestamp such as
`00:05:12`. Full transcripts stay in Captures and can be exported to text. Deleting
a capture does not delete excerpts already saved to Highlights.

Supported cloud audio file extensions include WAV, MP3, M4A, MP4, OGG, FLAC, and
WebM. Actual provider support still determines whether a particular encoding can
be decoded. Local ffmpeg supports additional formats. No podcast feeds or remote
URLs are fetched automatically.

## Chat with your highlights

Choose a question and an evidence scope: matching highlights across the library,
the current Highlights filters, or a saved collection. Preview matching passages
before calling a model. Archived highlights are excluded. Retrieval searches book
metadata, passages, personal notes, and tags; Japanese/Chinese character pairs
support queries without spaces. The context count is configurable from 1 to 20.
Only bounded excerpts are supplied, not ebooks or the full library.

Local chat uses an existing [Ollama](https://ollama.com/) server on this Mac at
`127.0.0.1:11434`. Install Ollama and download a model separately, then enter that
model's name in Studio settings. The default name is `llama3.2:3b`; Shelf does not
auto-download or start it. Loopback requests stay on the Mac and do not use a
remote HTTP proxy.

The optional OpenAI provider uses the fixed OpenAI chat-completions endpoint.
Enter a supported model name (for example, `gpt-4.1-mini`) and save a verified API
key. Every cloud question requires explicit permission to send the question and
matching passages, including personal notes. Settings never transfer a library in
the background. A provider may retain/process uploaded content under its own
terms, and API usage may incur costs.

Answers show highlight labels such as `[H1]`, supporting passages, and source
buttons. Unknown citation labels are rejected. Answers without usable citations
fall back to the evidence instead of presenting an unverified answer. Citations
identify supplied passages; they cannot prove the model's interpretation or every
claim is correct. No model response can execute a tool, edit a file, or send a
message. Each question retrieves fresh evidence; history is a local record, not
an instruction to upload all prior conversations.

Chat history is stored locally and can be cleared in Studio.

## Notion export

Create a Notion integration, share a destination parent page with it, and save its
token under Studio's service keys. Set the parent page ID or page link in Studio
settings. Verification uses Notion's read-only identity endpoint; the parent page
must separately permit the integration to create children.

Choose filters in Highlights, then **Preview current view for Notion**. Review the
highlight count and example passages, confirm the export, and explicitly submit.
The export sends passages, personal notes, tags, and book/source metadata. It
creates new snapshot pages under the selected parent; it does not overwrite your
existing pages or change Shelf's library. This is a direct internal-integration
API connection, not an OAuth account-linking flow or continuous bidirectional sync.

Up to 500 highlights can be exported per view. Blocks and rich text are split into
bounded requests that respect Notion limits. Larger views must be narrowed before
export. If the selection changes after preview, export stops and requests a new
preview. Confirmed snapshot receipts prevent the same payload being exported
again. Lost responses remain unconfirmed: inspect Notion before explicitly
retrying, since the original request might already have created a page. A retry
can create a duplicate. API access errors and rate limits are shown without
exposing remote error bodies.

## Credentials, storage, and backup

Notion and OpenAI keys use Shelf's existing owner-only local credential file. They
are never stored in browser localStorage, the annotation database, command-line
arguments, exports, or backups. Verification contacts only the chosen service's
identity/model endpoint; it does not send highlights or audio. Disconnect removes
the saved local key, while preserving local captures and annotations.

The annotation backup now includes Studio captures, local chat history, Studio
preferences, and confirmed Notion receipts. It excludes keys, local executable
paths, audio/image originals, and pending uploads. Restores merge existing data
and roll back together if validation fails. Portable backups are limited to 20 MB;
export large captures individually if the complete library exceeds that limit.
Review a backup before sharing it: it contains your passages, notes, and questions.

## Validation and platform limits

Automated tests cover consent, snapshot receipts, API request shapes, bounded
context, citation validation, transcript import, capture persistence, cancellation,
and portable restore. Chromium exercises the Studio forms against the real local
SQLite store with fixture model/Notion responses. No private user data or live
accounts are used in these tests.

The Linux environment also ran real Tesseract OCR on a synthetic image and real
ffmpeg + whisper.cpp inference on the upstream public JFK speech sample. The
whisper.cpp binary is built from v1.7.6 commit
`a8d002cfd879315632a579e73f0148d06959de36`; the tiny English model is checked against
SHA-256 `921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f` from
the official model repository's LFS metadata.

Apple Vision, native file panels, and full AppKit/WebKit compilation still require
macOS/Xcode testing. Live Notion, OpenAI, and local Ollama behavior require the
user's accounts or installed model and have not been verified here. The Linux
whisper binary is a development validation tool, not a macOS binary to bundle.
