# Saymark public accuracy corpus

`saymark-english-v1.json` is the checked-in, immutable recipe for Saymark's
first public English accuracy corpus. It references ten complete utterances
from [LibriSpeech ASR](https://huggingface.co/datasets/openslr/librispeech_asr)
at revision `71cacbfb7e2354c4226d01e70d77d5fca3d04ba1`: five `test.clean`
utterances and five `test.other` utterances from ten different speakers.

LibriSpeech is licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The corpus is
credited to Vassil Panayotov, Guoguo Chen, Daniel Povey, and Sanjeev Khudanpur:
“LibriSpeech: An ASR Corpus Based on Public Domain Audio Books” (ICASSP 2015).
The [OpenSLR source page](https://www.openslr.org/12/) provides the upstream
corpus and attribution.
Saymark modifies the selected recordings by normalizing their audio format and,
for derived cases, adding deterministic noise or combining complete utterances
with silence. The original authors do not endorse Saymark or these
modifications.

No audio is committed. `make prepare-corpus`:

1. verifies the dataset revision;
2. checks each row's path and reference transcript;
3. checks the downloaded source WAV's SHA-256;
4. normalizes it to 16 kHz mono PCM;
5. creates deterministic pink-noise cases and 30/45/60/90/120-second
   composites; and
6. writes the ignored local corpus to `Benchmarks/Corpus/local/`.

Long-form construction consumes unique utterances before any repetition. The
60-second case uses all ten sources once; 90- and 120-second cases use all ten
before a separately ordered second cycle. This prevents artificial
near-adjacent repetition from being collapsed by an ASR decoder.

Preparation requires Node.js 18 or newer plus `ffmpeg` and `ffprobe` on `PATH`.

The resulting `corpus.json` records the exact generated-audio hashes and
references consumed by the opt-in XCTest accuracy runner. To compare a model
against an accepted prior result, set `SAYMARK_CORPUS_BASELINE` to that result
JSON before running a corpus target.

This revision covers ten speakers, LibriSpeech clean and other conditions,
deterministic noise, and long-form stability. It does not yet contain
spoken-number or punctuation-command fixtures, so it is a foundation rather
than the complete product corpus.
