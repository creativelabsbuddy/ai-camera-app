/// Compile-time + runtime AI enhance configuration.
///
/// Security:
/// - `OPENROUTER_API_KEY` must only be passed via `--dart-define` for
///   **debug/profile test APKs**. Never hardcode it. Release builds omit it.
/// - Prefer a backend (`ENHANCE_SERVER_URL` / Settings) for production.
class AiConfig {
  AiConfig._();

  /// Embedded only when building with:
  /// `--dart-define=OPENROUTER_API_KEY=$OPENROUTER_API_KEY`
  static const String openRouterApiKey = String.fromEnvironment(
    'OPENROUTER_API_KEY',
    defaultValue: '',
  );

  /// Optional default proxy URL (ngrok etc.) via dart-define.
  static const String defaultEnhanceServerUrl = String.fromEnvironment(
    'ENHANCE_SERVER_URL',
    defaultValue: '',
  );

  /// v11.51 camera filters: read straight from Supabase (anon/publishable
  /// key, RLS allows only enabled `kind='filter'` rows) so new filters
  /// added in the admin panel appear without a new APK.
  static const String filtersSupabaseUrl = String.fromEnvironment(
    'FILTERS_SUPABASE_URL',
    defaultValue: 'https://yrgfoglpzrvjfyoclwyw.supabase.co',
  );
  static const String filtersSupabaseKey = String.fromEnvironment(
    'FILTERS_SUPABASE_KEY',
    defaultValue: 'sb_publishable_8SDJRhygtRJHTs7Xncak_Q_U0JM4mO1',
  );

  /// Public Supabase bucket with style + filter preview images (the admin
  /// panel uploads there; the Vercel app itself is login-protected).
  static const String filtersMediaBase = String.fromEnvironment(
    'FILTERS_MEDIA_BASE',
    defaultValue:
        'https://yrgfoglpzrvjfyoclwyw.supabase.co/storage/v1/object/public/style-thumbs',
  );

  /// v11.63 AI video (key TEST builds only, like OPENROUTER_API_KEY):
  /// Phosor MiniMax H3 Turbo for every length. [videoApiKey] is unused
  /// (kept so a dart-define does not break the build). Server builds
  /// leave these empty and go through `/v1/video/*`.
  static const String videoApiKey = String.fromEnvironment(
    'VIDEO_API_KEY',
    defaultValue: '',
  );
  static const String phosorApiKey = String.fromEnvironment(
    'PHOSOR_API_KEY',
    defaultValue: '',
  );
  /// Unused (legacy 8scale base). Kept so an existing dart-define still compiles.
  static const String wanBaseUrl = String.fromEnvironment(
    'VIDEO_API_BASE',
    defaultValue: 'https://8scale.run',
  );
  static const String phosorBaseUrl = 'https://phosor.ai/api/v1';

  /// MiniMax region switch (default: allowed everywhere; no geo detection).
  static const bool minimaxEnabled = bool.fromEnvironment(
    'MINIMAX_ENABLED',
    defaultValue: true,
  );

  static const String openRouterImagesUrl =
      'https://openrouter.ai/api/v1/images';

  static const String model = 'openai/gpt-image-2.5-flare';

  /// v11.58 style models (per style, admin "Model"; fallback = Custom/Flare).
  /// FLUX Klein on OpenRouter: the user's photo only, no quality/resolution.
  static const String kleinModel = 'black-forest-labs/flux-3-image-klein';

  /// FLUX.2 Klein 4B on Runware (violent / bloody looks). Key TEST builds
  /// only (dart-define RUNWARE_API_KEY); server builds keep it on the server.
  static const String runwareApiKey = String.fromEnvironment(
    'RUNWARE_API_KEY',
    defaultValue: '',
  );
  static const String runwareUrl = 'https://api.runware.ai/v1';
  static const String runwareKlein4bModel = 'runware:400@4';

  /// v11.15 Macro subject detection (cheap vision chat call, no credits).
  static const String openRouterChatUrl =
      'https://openrouter.ai/api/v1/chat/completions';
  static const Duration detectTimeout = Duration(seconds: 5);
  static const int detectLongSide = 768; // v11.49: was 512

  static bool get hasEmbeddedApiKey => openRouterApiKey.isNotEmpty;

  /// Compile-time constant twin of [hasEmbeddedApiKey]. Code guarded by
  /// `if (AiConfig.kHasEmbeddedKey)` is removed from release builds (no
  /// key) by the AOT compiler — used to keep the local seed-style prompts
  /// out of release APKs.
  static const bool kHasEmbeddedKey = openRouterApiKey != '';

  static bool get isTestKeyBuild {
    // Assertion tree is stripped in release; use fromEnvironment presence.
    return hasEmbeddedApiKey;
  }
}
