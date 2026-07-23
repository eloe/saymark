# Third-party notices

Saymark contains or uses third-party software and machine-learning models. Each
component remains subject to its own license terms. The notices and license
texts listed here are provided for attribution and do not change those terms.

## Murmur

Saymark is derived from the MIT-licensed
[Murmur](https://github.com/bshk-app/murmur) project by Aleksandr Beshkenadze.
The complete original copyright and permission notice is preserved in
[`LICENSE`](LICENSE) and is included in distributed application bundles.

## Software dependencies

The checked-in [`ThirdPartyLicenses`](ThirdPartyLicenses) directory contains
the license and notice files shipped with the pinned Swift packages, including
their bundled native components. It is copied into every Saymark application
bundle.

Direct runtime dependencies include:

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — MIT
- [PostHog Apple SDK](https://github.com/PostHog/posthog-ios) — MIT, with
  separately licensed PLCrashReporter and libwebp components
- [mlx-audio-swift](https://github.com/beshkenadze/mlx-audio-swift) — MIT
- [MLX Swift](https://github.com/ml-explore/mlx-swift) — MIT, with separately
  licensed bundled components
- [swift-huggingface](https://github.com/huggingface/swift-huggingface) — Apache-2.0

The directory also includes notices for transitive packages recorded in the
repository's resolved Swift package manifest. `Scripts/check-legal-notices.sh`
must pass before a distributable build is published.

## Models downloaded at runtime

Model files are not part of the Saymark source code or application bundle.
Saymark downloads the selected files directly from their publishers on
Hugging Face and stores them locally. Use and redistribution of those files are
governed by their own terms:

- [Nemotron 3.5 ASR Streaming 0.6B, MLX 8-bit conversion](https://huggingface.co/mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit)
  is converted from NVIDIA's model and is offered under the
  [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/).
  The model card states: “Original model © NVIDIA Corporation.” If you
  redistribute the model, NVIDIA requires a copy of that agreement and the
  notice: “Licensed by NVIDIA Corporation under the NVIDIA Open Model License”.
- [Parakeet TDT 0.6B v3, MLX conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3)
  is converted from NVIDIA's model and is offered under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Redistribution or
  adaptation requires attribution and an indication of changes under that
  license.
- [Silero VAD, MLX conversion](https://huggingface.co/mlx-community/silero-vad)
  is converted from Silero VAD. The conversion's model card does not currently
  declare an SPDX license. The
  [upstream Silero VAD project](https://github.com/snakers4/silero-vad) is MIT
  licensed. Confirm the conversion publisher's terms before redistributing its
  weights.

Saymark does not grant rights to these model files and does not use the NVIDIA,
Parakeet, Silero, MLX, Hugging Face, PostHog, or other third-party names to
suggest endorsement.

## Scope

This file records the components known from the checked-in dependency manifests
and the models selected by the application as of July 22, 2026. Maintainers
must review notices when dependencies or default models change. This inventory
is a compliance aid, not legal advice.
