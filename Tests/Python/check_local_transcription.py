"""Optional real inference check; pass the installed whisper tools root as argv[1]."""
from pathlib import Path
import sys

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Sources/ShelfCore/Tools'))
from shelf_studio import transcribe_local


def main():
    if len(sys.argv)!=2: raise SystemExit('Usage: python3 Tests/Python/check_local_transcription.py /path/to/whisper-tools')
    root=Path(sys.argv[1])
    parts=transcribe_local(root/'samples/jfk.wav',str(root/'bin/whisper-cli'),root/'models/ggml-tiny.en.bin')
    transcript=' '.join(x['text'] for x in parts).casefold()
    if not parts or parts[-1]['end']<=0 or 'country' not in transcript or 'fellow americans' not in transcript:
        raise SystemExit('Local transcription did not recognize the known public sample with valid timestamps')
    print(f'PASS: real ffmpeg + whisper.cpp inference, {len(parts)} timestamped segments')

if __name__=='__main__':main()
