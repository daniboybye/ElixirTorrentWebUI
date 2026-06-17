defmodule ElixirTorrentWebUI.Languages do
  @moduledoc """
  Curated list of 64 UI languages for the Settings picker.

  Entries are ordered alphabetically by English name (A→Z). Each entry carries
  a representative country flag emoji for the picker. Locales without a
  `priv/gettext/<locale>` catalog fall back to English msgids.
  """

  @type entry :: %{code: String.t(), label: String.t(), flag: String.t()}

  # 64 languages, alphabetical by English name (A→Z).
  @entries [
    %{code: "af", label: "Afrikaans", flag: "🇿🇦"},
    %{code: "sq", label: "Shqip (Albanian)", flag: "🇦🇱"},
    %{code: "am", label: "አማርኛ (Amharic)", flag: "🇪🇹"},
    %{code: "ar", label: "العربية (Arabic)", flag: "🇸🇦"},
    %{code: "eu", label: "Euskara (Basque)", flag: "🇪🇸"},
    %{code: "be", label: "Беларуская (Belarusian)", flag: "🇧🇾"},
    %{code: "bn", label: "বাংলা (Bengali)", flag: "🇧🇩"},
    %{code: "bs", label: "Bosanski (Bosnian)", flag: "🇧🇦"},
    %{code: "bg", label: "Български (Bulgarian)", flag: "🇧🇬"},
    %{code: "my", label: "မြန်မာဘာသာ (Burmese)", flag: "🇲🇲"},
    %{code: "ca", label: "Català (Catalan)", flag: "🇪🇸"},
    %{code: "hr", label: "Hrvatski (Croatian)", flag: "🇭🇷"},
    %{code: "cs", label: "Čeština (Czech)", flag: "🇨🇿"},
    %{code: "da", label: "Dansk (Danish)", flag: "🇩🇰"},
    %{code: "nl", label: "Nederlands (Dutch)", flag: "🇳🇱"},
    %{code: "en", label: "English", flag: "🇬🇧"},
    %{code: "et", label: "Eesti (Estonian)", flag: "🇪🇪"},
    %{code: "fi", label: "Suomi (Finnish)", flag: "🇫🇮"},
    %{code: "fr", label: "Français (French)", flag: "🇫🇷"},
    %{code: "gl", label: "Galego (Galician)", flag: "🇪🇸"},
    %{code: "de", label: "Deutsch (German)", flag: "🇩🇪"},
    %{code: "el", label: "Ελληνικά (Greek)", flag: "🇬🇷"},
    %{code: "gu", label: "ગુજરાતી (Gujarati)", flag: "🇮🇳"},
    %{code: "he", label: "עברית (Hebrew)", flag: "🇮🇱"},
    %{code: "hi", label: "हिन्दी (Hindi)", flag: "🇮🇳"},
    %{code: "hu", label: "Magyar (Hungarian)", flag: "🇭🇺"},
    %{code: "is", label: "Íslenska (Icelandic)", flag: "🇮🇸"},
    %{code: "id", label: "Bahasa Indonesia (Indonesian)", flag: "🇮🇩"},
    %{code: "ga", label: "Gaeilge (Irish)", flag: "🇮🇪"},
    %{code: "it", label: "Italiano (Italian)", flag: "🇮🇹"},
    %{code: "ja", label: "日本語 (Japanese)", flag: "🇯🇵"},
    %{code: "km", label: "ភាសាខ្មែរ (Khmer)", flag: "🇰🇭"},
    %{code: "ko", label: "한국어 (Korean)", flag: "🇰🇷"},
    %{code: "lv", label: "Latviešu (Latvian)", flag: "🇱🇻"},
    %{code: "lt", label: "Lietuvių (Lithuanian)", flag: "🇱🇹"},
    %{code: "lb", label: "Lëtzebuergesch (Luxembourgish)", flag: "🇱🇺"},
    %{code: "mk", label: "Македонски (Macedonian)", flag: "🇲🇰"},
    %{code: "ms", label: "Bahasa Melayu (Malay)", flag: "🇲🇾"},
    %{code: "mt", label: "Malti (Maltese)", flag: "🇲🇹"},
    %{code: "zh", label: "中文 (Mandarin Chinese)", flag: "🇨🇳"},
    %{code: "mr", label: "मराठी (Marathi)", flag: "🇮🇳"},
    %{code: "ne", label: "नेपाली (Nepali)", flag: "🇳🇵"},
    %{code: "no", label: "Norsk (Norwegian)", flag: "🇳🇴"},
    %{code: "fa", label: "فارسی (Persian)", flag: "🇮🇷"},
    %{code: "pl", label: "Polski (Polish)", flag: "🇵🇱"},
    %{code: "pt", label: "Português (Portuguese)", flag: "🇵🇹"},
    %{code: "pa", label: "ਪੰਜਾਬੀ (Punjabi)", flag: "🇮🇳"},
    %{code: "ro", label: "Română (Romanian)", flag: "🇷🇴"},
    %{code: "ru", label: "Русский (Russian)", flag: "🇷🇺"},
    %{code: "sr", label: "Српски (Serbian)", flag: "🇷🇸"},
    %{code: "sk", label: "Slovenčina (Slovak)", flag: "🇸🇰"},
    %{code: "sl", label: "Slovenščina (Slovenian)", flag: "🇸🇮"},
    %{code: "es", label: "Español (Spanish)", flag: "🇪🇸"},
    %{code: "sw", label: "Kiswahili (Swahili)", flag: "🇰🇪"},
    %{code: "sv", label: "Svenska (Swedish)", flag: "🇸🇪"},
    %{code: "tl", label: "Filipino (Tagalog)", flag: "🇵🇭"},
    %{code: "ta", label: "தமிழ் (Tamil)", flag: "🇮🇳"},
    %{code: "te", label: "తెలుగు (Telugu)", flag: "🇮🇳"},
    %{code: "th", label: "ไทย (Thai)", flag: "🇹🇭"},
    %{code: "tr", label: "Türkçe (Turkish)", flag: "🇹🇷"},
    %{code: "uk", label: "Українська (Ukrainian)", flag: "🇺🇦"},
    %{code: "ur", label: "اردو (Urdu)", flag: "🇵🇰"},
    %{code: "vi", label: "Tiếng Việt (Vietnamese)", flag: "🇻🇳"},
    %{code: "cy", label: "Cymraeg (Welsh)", flag: "🇬🇧"}
  ]

  @codes MapSet.new(@entries, & &1.code)

  @spec list() :: [entry()]
  def list, do: @entries

  @spec picker_label(entry()) :: String.t()
  def picker_label(%{flag: flag, label: label}), do: "#{flag} #{label}"

  @spec valid?(String.t()) :: boolean()
  def valid?(code) when is_binary(code), do: MapSet.member?(@codes, code)

  @spec default() :: String.t()
  def default, do: "en"
end
