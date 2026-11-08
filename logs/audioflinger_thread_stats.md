# dumpsys media.audio_flinger excerpts, deep-buffer output thread (AudioOut_1D), FiiO M33 R2R fw 1.0.2

## stock libfiioaudio, Shorts swipe 0
  Sample rate: 384000 Hz
  HAL format: 0x3 (AUDIO_FORMAT_PCM_32_BIT)
  Timestamp stats: n=507 disc=1 cold=2 nRdy=0 err=0 rate=1.00375 
  Threadloop write latency stats: ave=88.0013 std=19.6653 min=48.3395 max=1030.69

## stock, after 3 Shorts
  Sample rate: 384000 Hz
  HAL format: 0x3 (AUDIO_FORMAT_PCM_32_BIT)
  Timestamp stats: n=1468 disc=10 cold=2 nRdy=0 err=0 rate=1.00122 
  Threadloop write latency stats: ave=227.51 std=2.57964 min=177.754 max=228.236

## stock, after 6 Shorts
  Sample rate: 384000 Hz
  HAL format: 0x3 (AUDIO_FORMAT_PCM_32_BIT)
  Timestamp stats: n=2429 disc=16 cold=2 nRdy=0 err=0 rate=1.00141 
  Threadloop write latency stats: ave=327.627 std=1.60655 min=259.395 max=328.583

## stock, after 10 Shorts
  Sample rate: 352800 Hz
  HAL format: 0x3 (AUDIO_FORMAT_PCM_32_BIT)
  Timestamp stats: n=3706 disc=25 cold=2 nRdy=0 err=0 rate=1.00681 
  Threadloop write latency stats: ave=521.112 std=3.73498 min=483.031 max=547.988

## patched, swipe 0
  Sample rate: 384000 Hz
  HAL format: 0x3 (AUDIO_FORMAT_PCM_32_BIT)
  Timestamp stats: n=3803 disc=29 cold=2 nRdy=0 err=0 rate=1.0055 
  Threadloop write latency stats: ave=87.6098 std=1.21785 min=69.4307 max=135.99

## patched, after 10 Shorts
  Sample rate: 384000 Hz
  HAL format: 0x3 (AUDIO_FORMAT_PCM_32_BIT)
  Timestamp stats: n=7003 disc=57 cold=2 nRdy=0 err=0 rate=1.00054 
  Threadloop write latency stats: ave=87.6384 std=0.606725 min=74.0427 max=88.6977

## NOS 44.1k, before HAL patch
  Sample rate: 48000 Hz
  HAL format: 0x1 (AUDIO_FORMAT_PCM_16_BIT)
  Timestamp stats: n=25718 disc=124 cold=2 nRdy=0 err=0 rate=2.04208 
  Threadloop write latency stats: ave=-3.82701e+06 std=1128.89 min=-3.82879e+06 max=-3.82489e+06

## NOS 44.1k, v1.2
  Sample rate: 44100 Hz
  HAL format: 0x1 (AUDIO_FORMAT_PCM_16_BIT)
  Timestamp stats: n=485 disc=3 cold=1 nRdy=0 err=0 rate=1.01247 
  Threadloop write latency stats: ave=158.73 std=6.60168 min=116.685 max=174.042

## OS 48k, v1.2
  Sample rate: 384000 Hz
  HAL format: 0x3 (AUDIO_FORMAT_PCM_32_BIT)
  Timestamp stats: n=3646 disc=14 cold=1 nRdy=0 err=0 rate=1.01026 
  Threadloop write latency stats: ave=87.6418 std=2.08898 min=69.2829 max=119.577
