/// Extra information about voices that a model file does not carry.
class SherpaVoiceCatalog {
  /// Quality grades from the Kokoro model card, which rates every voice from
  /// A to F based on how much speech it was trained on.
  ///
  /// Source: https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md
  /// Useful when picking from Kokoro's 54 voices: the Chinese ones are all
  /// D, the best American English ones are af_heart (A) and af_bella (A-).
  /// Voices the card leaves ungraded are absent here.
  static const Map<String, String> kokoroGrades = {
    // American English
    'af_heart': 'A',
    'af_alloy': 'C',
    'af_aoede': 'C+',
    'af_bella': 'A-',
    'af_jessica': 'D',
    'af_kore': 'C+',
    'af_nicole': 'B-',
    'af_nova': 'C',
    'af_river': 'D',
    'af_sarah': 'C+',
    'af_sky': 'C-',
    'am_adam': 'F+',
    'am_echo': 'D',
    'am_eric': 'D',
    'am_fenrir': 'C+',
    'am_liam': 'D',
    'am_michael': 'C+',
    'am_onyx': 'D',
    'am_puck': 'C+',
    'am_santa': 'D-',
    // British English
    'bf_alice': 'D',
    'bf_emma': 'B-',
    'bf_isabella': 'C',
    'bf_lily': 'D',
    'bm_daniel': 'D',
    'bm_fable': 'C',
    'bm_george': 'C',
    'bm_lewis': 'D+',
    // Mandarin Chinese
    'zf_xiaobei': 'D',
    'zf_xiaoni': 'D',
    'zf_xiaoxiao': 'D',
    'zf_xiaoyi': 'D',
    'zm_yunjian': 'D',
    'zm_yunxi': 'D',
    'zm_yunxia': 'D',
    'zm_yunyang': 'D',
    // Japanese
    'jf_alpha': 'C+',
    'jf_gongitsune': 'C',
    'jf_nezumi': 'C-',
    'jf_tebukuro': 'C',
    'jm_kumo': 'C-',
    // French
    'ff_siwis': 'B-',
    // Hindi
    'hf_alpha': 'C',
    'hf_beta': 'C',
    'hm_omega': 'C',
    'hm_psi': 'C',
    // Italian
    'if_sara': 'C',
    'im_nicola': 'C',
  };

  static String? grade(String voiceName) => kokoroGrades[voiceName];
}
