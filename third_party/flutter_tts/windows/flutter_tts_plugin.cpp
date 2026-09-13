#include "include/flutter_tts/flutter_tts_plugin.h"
// This must be included before many other Windows headers.
#include <windows.h>
#include <ppltasks.h>
#include <VersionHelpers.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <map>
#include <memory>
#include <sstream>

typedef std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> FlutterResult;
//typedef flutter::MethodResult<flutter::EncodableValue>* PFlutterResult;

std::unique_ptr<flutter::MethodChannel<>> methodChannel;

#if 0 // Always use Win32 SAPI implementation to support all voices, including:
// 1. Traditional desktop voices (e.g., Microsoft Huihui Desktop, Microsoft Zira Desktop)
// 2. Natural voices from NaturalVoiceSAPIAdapter (e.g., Microsoft Xiaoxiao Online, Microsoft Xiaoyi Online)
// 3. Other SAPI-compatible voices
// 
// This implementation works on all Windows versions, including Windows 7, Windows 10, and Windows 11
// To get natural voices, users need to install NaturalVoiceSAPIAdapter from:
// https://github.com/gexgd0419/NaturalVoiceSAPIAdapter
#include <winrt/Windows.Media.SpeechSynthesis.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Media.Core.h>
using namespace winrt;
using namespace Windows::Media::SpeechSynthesis;
using namespace Concurrency;
using namespace std::chrono_literals;
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
namespace {
	class FlutterTtsPlugin : public flutter::Plugin {
	public:
		static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
		FlutterTtsPlugin();
		virtual ~FlutterTtsPlugin();
	private:
		// Called when a method is called on this plugin's channel from Dart.
		void HandleMethodCall(
			const flutter::MethodCall<flutter::EncodableValue>& method_call,
			std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
		void speak(const std::string, FlutterResult);
		void pause();
		void continuePlay();
		void stop();
		void setVolume(const double);
		void setPitch(const double);
		void setRate(const double);
		void getVoices(flutter::EncodableList&);
		void setVoice(const std::string, const std::string, FlutterResult&);
		void getLanguages(flutter::EncodableList&);
		void setLanguage(const std::string, FlutterResult&);
		void addMplayer();
		winrt::Windows::Foundation::IAsyncAction asyncSpeak(const std::string);
		bool speaking();
		bool paused();
		SpeechSynthesizer synth;
		winrt::Windows::Media::Playback::MediaPlayer mPlayer;
		bool isPaused;
		bool isSpeaking;
		bool awaitSpeakCompletion;
		FlutterResult speakResult;
	};

	void FlutterTtsPlugin::RegisterWithRegistrar(
		flutter::PluginRegistrarWindows* registrar) {
		methodChannel =
			std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
				registrar->messenger(), "flutter_tts",
				&flutter::StandardMethodCodec::GetInstance());
		auto plugin = std::make_unique<FlutterTtsPlugin>();

		methodChannel->SetMethodCallHandler(
			[plugin_pointer = plugin.get()](const auto& call, auto result) {
			plugin_pointer->HandleMethodCall(call, std::move(result));
		});
		registrar->AddPlugin(std::move(plugin));
	}

	void FlutterTtsPlugin::addMplayer() {
		mPlayer = winrt::Windows::Media::Playback::MediaPlayer::MediaPlayer();
		auto mEndedToken =
			mPlayer.MediaEnded([=](Windows::Media::Playback::MediaPlayer const& sender,
				Windows::Foundation::IInspectable const& args)
				{
				    methodChannel->InvokeMethod("speak.onComplete", NULL);
				    if (awaitSpeakCompletion) {
                        speakResult->Success(1);
                    }
					isSpeaking = false;
				});
	}

	bool FlutterTtsPlugin::speaking() {
		return isSpeaking;
	}

	bool FlutterTtsPlugin::paused() {
		return isPaused;
	}

	winrt::Windows::Foundation::IAsyncAction FlutterTtsPlugin::asyncSpeak(const std::string text) {
		SpeechSynthesisStream speechStream{
		  co_await synth.SynthesizeTextToStreamAsync(to_hstring(text))
		};
		winrt::param::hstring cType = L"Audio";
		winrt::Windows::Media::Core::MediaSource source =
			winrt::Windows::Media::Core::MediaSource::CreateFromStream(speechStream, cType);
		mPlayer.Source(source);
		mPlayer.Play();
	}

	void FlutterTtsPlugin::speak(const std::string text, FlutterResult result) {
		isSpeaking = true;
		auto my_task{ asyncSpeak(text) };
		methodChannel->InvokeMethod("speak.onStart", NULL);
        if (awaitSpeakCompletion) speakResult = std::move(result);
        else result->Success(1);
	};

	void FlutterTtsPlugin::pause() {
		mPlayer.Pause();
		isPaused = true;
		methodChannel->InvokeMethod("speak.onPause", NULL);
	}

	void FlutterTtsPlugin::continuePlay() {
		mPlayer.Play();
		isPaused = false;
		methodChannel->InvokeMethod("speak.onContinue", NULL);
	}

	void FlutterTtsPlugin::stop() {
	    methodChannel->InvokeMethod("speak.onCancel", NULL);
        if (awaitSpeakCompletion) {
            speakResult->Success(1);
        }

		mPlayer.Close();
		addMplayer();
		isSpeaking = false;
		isPaused = false;
	}
	void FlutterTtsPlugin::setVolume(const double newVolume) { synth.Options().AudioVolume(newVolume); }

	void FlutterTtsPlugin::setPitch(const double newPitch) { synth.Options().AudioPitch(newPitch); }

	void FlutterTtsPlugin::setRate(const double newRate) { synth.Options().SpeakingRate(newRate + 0.5); }

	void FlutterTtsPlugin::getVoices(flutter::EncodableList& voices) {
		auto synthVoices = synth.AllVoices();
		std::for_each(begin(synthVoices), end(synthVoices), [&voices](const VoiceInformation& voice)
			{
				flutter::EncodableMap voiceInfo;
				voiceInfo[flutter::EncodableValue("locale")] = to_string(voice.Language());
				voiceInfo[flutter::EncodableValue("name")] = to_string(voice.DisplayName());
				//  Convert VoiceGender to string
				std::string gender;
				switch (voice.Gender()) {
					case VoiceGender::Male:
						gender = "male";
						break;
					case VoiceGender::Female:
						gender = "female";
						break;
					default:
						gender = "unknown";
						break;
				}
				voiceInfo[flutter::EncodableValue("gender")] = gender; 
				// Identifier example "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens\MSTTS_V110_enUS_MarkM"
				voiceInfo[flutter::EncodableValue("identifier")] = to_string(voice.Id());
				voices.push_back(flutter::EncodableMap(voiceInfo));
			});
	}

	void FlutterTtsPlugin::setVoice(const std::string voiceLanguage, const std::string voiceName, FlutterResult& result) {
		bool found = false;
		auto voices = synth.AllVoices();
		VoiceInformation newVoice = synth.Voice();
		std::for_each(begin(voices), end(voices), [&voiceLanguage, &voiceName, &found, &newVoice](const VoiceInformation& voice)
			{
				if (to_string(voice.Language()) == voiceLanguage && to_string(voice.DisplayName()) == voiceName)
				{
					newVoice = voice;
					found = true;
				}
			});
		synth.Voice(newVoice);
		if (found) result->Success(1);
		else result->Success(0);
	}

	void FlutterTtsPlugin::getLanguages(flutter::EncodableList& languages) {
		auto synthVoices = synth.AllVoices();
		std::set<flutter::EncodableValue> languagesSet = {};
		std::for_each(begin(synthVoices), end(synthVoices), [&languagesSet](const VoiceInformation& voice)
			{
				languagesSet.insert(flutter::EncodableValue(to_string(voice.Language())));
			});
		std::for_each(begin(languagesSet), end(languagesSet), [&languages](const flutter::EncodableValue value)
			{
				languages.push_back(value);
			});
	}
	void FlutterTtsPlugin::setLanguage(const std::string voiceLanguage, FlutterResult& result) {
		bool found = false;
		auto voices = synth.AllVoices();
		VoiceInformation newVoice = synth.Voice();
		std::for_each(begin(voices), end(voices), [&voiceLanguage, &newVoice, &found](const VoiceInformation& voice)
			{
				if (to_string(voice.Language()) == voiceLanguage) newVoice = voice;
				found = true;
			});
		synth.Voice(newVoice);
		if (found) result->Success(1);
		else result->Success(0);
	}


	FlutterTtsPlugin::FlutterTtsPlugin() {
		synth = SpeechSynthesizer();
		addMplayer();
		isPaused = false;
		isSpeaking = false;
		awaitSpeakCompletion = false;
		speakResult = FlutterResult();
	}

	FlutterTtsPlugin::~FlutterTtsPlugin() { mPlayer.Close(); }

	void FlutterTtsPlugin::HandleMethodCall(
		const flutter::MethodCall<flutter::EncodableValue>& method_call,
		FlutterResult result) {
		if (method_call.method_name().compare("getPlatformVersion") == 0) {
			std::ostringstream version_stream;
			version_stream << "Windows UWP";
			result->Success(flutter::EncodableValue(version_stream.str()));
		}

#else
#include <string>
#include <atlstr.h>
#include <array>
#include <sapi.h>
#pragma warning(disable:4996)
#include <sphelper.h>
#pragma warning(default: 4996)
namespace {

	class FlutterTtsPlugin : public flutter::Plugin {
	public:
		static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
		FlutterTtsPlugin();
		virtual ~FlutterTtsPlugin();
	private:
		// Called when a method is called on this plugin's channel from Dart.
		void HandleMethodCall(
			const flutter::MethodCall<flutter::EncodableValue>& method_call,
			std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

		void speak(const std::string, FlutterResult);
		void pause();
		void continuePlay();
		void stop();
		void setVolume(const double);
		void setPitch(const double);
		void setRate(const double);
		void getVoices(flutter::EncodableList&);
		void setVoice(const std::string, const std::string, FlutterResult&);
		void getLanguages(flutter::EncodableList&);
		void setLanguage(const std::string, FlutterResult&);

		ISpVoice* pVoice;
		bool awaitSpeakCompletion = false;
		bool isPaused;
		double pitch;
		bool speaking();
		bool paused();
		FlutterResult speakResult;
    	HANDLE addWaitHandle;
	};

	void FlutterTtsPlugin::RegisterWithRegistrar(
		flutter::PluginRegistrarWindows* registrar) {
		methodChannel =
			std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
				registrar->messenger(), "flutter_tts",
				&flutter::StandardMethodCodec::GetInstance());
		auto plugin = std::make_unique<FlutterTtsPlugin>();
		methodChannel->SetMethodCallHandler(
			[plugin_pointer = plugin.get()](const auto& call, auto result) {
			plugin_pointer->HandleMethodCall(call, std::move(result));
		});

		registrar->AddPlugin(std::move(plugin));
	}

	FlutterTtsPlugin::FlutterTtsPlugin() {
		addWaitHandle = NULL;
		isPaused = false;
		speakResult = NULL;
		pVoice = NULL;
		HRESULT hr;
		hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
		if (FAILED(hr))
		{
			throw std::exception("TTS init failed");
		}

		hr = CoCreateInstance(CLSID_SpVoice, NULL, CLSCTX_ALL, IID_ISpVoice, (void**)&pVoice);
		if (FAILED(hr))
		{
			throw std::exception("TTS create instance failed");
		}
		pitch = 0;
	}

	FlutterTtsPlugin::~FlutterTtsPlugin() {
		::CoUninitialize();
	}

    void CALLBACK setResult(PVOID lpParam, BOOLEAN TimerOrWaitFired)
    {
        flutter::MethodResult<flutter::EncodableValue>* p = (flutter::MethodResult<flutter::EncodableValue>*) lpParam;
        p->Success(1);
    }

    void CALLBACK onCompletion(PVOID lpParam, BOOLEAN TimerOrWaitFired)
    {
        methodChannel->InvokeMethod("speak.onComplete", NULL);
    }

	bool FlutterTtsPlugin::speaking()
	{
		SPVOICESTATUS status;
		pVoice->GetStatus(&status, NULL);
		if (status.dwRunningState == SPRS_IS_SPEAKING) return true;
		return false;
	}
	bool FlutterTtsPlugin::paused() { return isPaused; }


	void FlutterTtsPlugin::speak(const std::string text, FlutterResult result) {
		HRESULT hr;
		const std::string arg = "<PITCH MIDDLE = '" + std::to_string(int((pitch - 1) * 10 * (1 + (pitch < 1)) )) + "'/>" + text;

		int wchars_num = MultiByteToWideChar(CP_UTF8, 0, arg.c_str(), -1, NULL, 0);
		wchar_t* wstr = new wchar_t[wchars_num];
		MultiByteToWideChar(CP_UTF8, 0, arg.c_str(), -1, wstr, wchars_num);
		hr = pVoice->Speak(wstr, 1, NULL);
		delete[] wstr;
		HANDLE speakCompletionHandle = pVoice->SpeakCompleteEvent();
		methodChannel->InvokeMethod("speak.onStart", NULL);
		RegisterWaitForSingleObject(&addWaitHandle, speakCompletionHandle, (WAITORTIMERCALLBACK)&onCompletion, speakResult.get(), INFINITE, WT_EXECUTEONLYONCE);
		if (awaitSpeakCompletion){
		    speakResult = std::move(result);
		    RegisterWaitForSingleObject(&addWaitHandle, speakCompletionHandle, (WAITORTIMERCALLBACK)&setResult, speakResult.get(), INFINITE, WT_EXECUTEONLYONCE);
		}
		else result->Success(1);
	}
	void FlutterTtsPlugin::pause()
	{
		if (isPaused == false)
		{
			pVoice->Pause();
			isPaused = true;
		}
	    methodChannel->InvokeMethod("speak.onPause", NULL);
	}
	void FlutterTtsPlugin::continuePlay()
	{
		isPaused = false;
		pVoice->Resume();
	    methodChannel->InvokeMethod("speak.onContinue", NULL);
	}
	void FlutterTtsPlugin::stop()
	{
		pVoice->Speak(L"", 2, NULL);
		pVoice->Resume();
		isPaused = false;
	    methodChannel->InvokeMethod("speak.onCancel", NULL);
	}
	void FlutterTtsPlugin::setVolume(const double newVolume)
	{
		const USHORT volume = (short)(100 * newVolume);
		pVoice->SetVolume(volume);
	}
	void FlutterTtsPlugin::setPitch(const double newPitch) {pitch = newPitch;}
	void FlutterTtsPlugin::setRate(const double newRate)
	{
		const long speechRate = (long)((newRate - 0.5) * 15);
		pVoice->SetRate(speechRate);
	}
	void FlutterTtsPlugin::getVoices(flutter::EncodableList& voices) {
		HRESULT hr;
		CComPtr<IEnumSpObjectTokens> cpEnum;
		// Get all voices
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) {
			OutputDebugString(L"Failed to enumerate voices\n");
			return;
		}

 		ULONG ulCount = 0;
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) {
			OutputDebugString(L"Failed to get voice count\n");
			return;
		}
		
		wchar_t countStr[50];
		swprintf_s(countStr, sizeof(countStr) / sizeof(wchar_t), L"Found %d voices\n", ulCount);
		OutputDebugString(countStr);
		
		for (ULONG i = 0; i < ulCount; i++)
		{
			CComPtr<ISpObjectToken> cpVoiceToken;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr) || cpVoiceToken == NULL) continue;
			
			std::string language = "unknown";
			std::string name = "unknown";
			std::string gender = "unknown";
			std::string identifier = "";

			// Get identifier
			WCHAR* pszId = NULL;
			if (SUCCEEDED(cpVoiceToken->GetId(&pszId))) {
				int idLen = WideCharToMultiByte(CP_UTF8, 0, pszId, -1, NULL, 0, NULL, NULL);
				if (idLen > 1) {
					identifier.resize(idLen - 1);
					WideCharToMultiByte(CP_UTF8, 0, pszId, -1, &identifier[0], idLen, NULL, NULL);
				}
				::CoTaskMemFree(pszId);
			}

			CComPtr<ISpDataKey> cpAttribKey;
			hr = cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey);
			if (SUCCEEDED(hr)) {
				WCHAR* pszValue = NULL;
				
				// Get language
				if (SUCCEEDED(cpAttribKey->GetStringValue(L"Language", &pszValue))) {
					wchar_t locale[100] = { 0 };
					ULONG lcid = wcstoul(pszValue, NULL, 16);
					if (lcid != 0 && LCIDToLocaleName(lcid, locale, 100, 0) != 0) {
						int localeLen = WideCharToMultiByte(CP_UTF8, 0, locale, -1, NULL, 0, NULL, NULL);
						if (localeLen > 1) {
							language.resize(localeLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, locale, -1, &language[0], localeLen, NULL, NULL);
						}
					} else {
						// Fallback: use the value directly if it's already a locale name
						int localeLen = WideCharToMultiByte(CP_UTF8, 0, pszValue, -1, NULL, 0, NULL, NULL);
						if (localeLen > 1) {
							language.resize(localeLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, pszValue, -1, &language[0], localeLen, NULL, NULL);
						}
					}
					::CoTaskMemFree(pszValue);
				}
				
				// Get name
				pszValue = NULL;
				if (SUCCEEDED(cpAttribKey->GetStringValue(L"Name", &pszValue))) {
					int nameLen = WideCharToMultiByte(CP_UTF8, 0, pszValue, -1, NULL, 0, NULL, NULL);
					if (nameLen > 1) {
						name.resize(nameLen - 1);
						WideCharToMultiByte(CP_UTF8, 0, pszValue, -1, &name[0], nameLen, NULL, NULL);
					}
					::CoTaskMemFree(pszValue);
				} else {
					// Fallback: get description from token
					WCHAR* pszDesc = NULL;
					if (SUCCEEDED(SpGetDescription(cpVoiceToken, &pszDesc))) {
						int descLen = WideCharToMultiByte(CP_UTF8, 0, pszDesc, -1, NULL, 0, NULL, NULL);
						if (descLen > 1) {
							name.resize(descLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, pszDesc, -1, &name[0], descLen, NULL, NULL);
						}
						::CoTaskMemFree(pszDesc);
					}
				}

				// Get gender
				pszValue = NULL;
				if (SUCCEEDED(cpAttribKey->GetStringValue(L"Gender", &pszValue))) {
					if (wcscmp(pszValue, L"Male") == 0) gender = "male";
					else if (wcscmp(pszValue, L"Female") == 0) gender = "female";
					::CoTaskMemFree(pszValue);
				}
			} else {
				// Attributes key missing, try to get at least the name
				WCHAR* pszDesc = NULL;
				if (SUCCEEDED(SpGetDescription(cpVoiceToken, &pszDesc))) {
					int descLen = WideCharToMultiByte(CP_UTF8, 0, pszDesc, -1, NULL, 0, NULL, NULL);
					if (descLen > 1) {
						name.resize(descLen - 1);
						WideCharToMultiByte(CP_UTF8, 0, pszDesc, -1, &name[0], descLen, NULL, NULL);
					}
					::CoTaskMemFree(pszDesc);
				}
			}

            flutter::EncodableMap voiceInfo;
            voiceInfo[flutter::EncodableValue("locale")] = language;
            voiceInfo[flutter::EncodableValue("name")] = name;
            voiceInfo[flutter::EncodableValue("gender")] = gender;
            voiceInfo[flutter::EncodableValue("identifier")] = identifier;
            voices.push_back(flutter::EncodableMap(voiceInfo));
		}
	}
	void FlutterTtsPlugin::setVoice(const std::string voiceLanguage, const std::string voiceName, FlutterResult& result) {
		HRESULT hr;
		CComPtr<IEnumSpObjectTokens> cpEnum;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) { result->Success(0); return; }
		ULONG ulCount = 0;
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) { result->Success(0); return; }
		
		bool success = false;
		for (ULONG i = 0; i < ulCount; i++)
		{
			CComPtr<ISpObjectToken> cpVoiceToken;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr) || cpVoiceToken == NULL) continue;
			
			std::string language = "";
			std::string name = "";

			CComPtr<ISpDataKey> cpAttribKey;
			if (SUCCEEDED(cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey))) {
				WCHAR* pszValue = NULL;
				
				// Get name
				if (SUCCEEDED(cpAttribKey->GetStringValue(L"Name", &pszValue))) {
					int nameLen = WideCharToMultiByte(CP_UTF8, 0, pszValue, -1, NULL, 0, NULL, NULL);
					if (nameLen > 1) {
						name.resize(nameLen - 1);
						WideCharToMultiByte(CP_UTF8, 0, pszValue, -1, &name[0], nameLen, NULL, NULL);
					}
					::CoTaskMemFree(pszValue);
				} else {
					WCHAR* pszDesc = NULL;
					if (SUCCEEDED(SpGetDescription(cpVoiceToken, &pszDesc))) {
						int descLen = WideCharToMultiByte(CP_UTF8, 0, pszDesc, -1, NULL, 0, NULL, NULL);
						if (descLen > 1) {
							name.resize(descLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, pszDesc, -1, &name[0], descLen, NULL, NULL);
						}
						::CoTaskMemFree(pszDesc);
					}
				}
				
				// Get language
				pszValue = NULL;
				if (SUCCEEDED(cpAttribKey->GetStringValue(L"Language", &pszValue))) {
					wchar_t locale[100] = { 0 };
					ULONG lcid = wcstoul(pszValue, NULL, 16);
					if (lcid != 0 && LCIDToLocaleName(lcid, locale, 100, 0) != 0) {
						int localeLen = WideCharToMultiByte(CP_UTF8, 0, locale, -1, NULL, 0, NULL, NULL);
						if (localeLen > 1) {
							language.resize(localeLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, locale, -1, &language[0], localeLen, NULL, NULL);
						}
					} else {
						int localeLen = WideCharToMultiByte(CP_UTF8, 0, pszValue, -1, NULL, 0, NULL, NULL);
						if (localeLen > 1) {
							language.resize(localeLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, pszValue, -1, &language[0], localeLen, NULL, NULL);
						}
					}
					::CoTaskMemFree(pszValue);
				}
            }

            // Try to match by name and language
			if ((!name.empty() && name == voiceName && (voiceLanguage.empty() || language == voiceLanguage)) || 
                (!language.empty() && language == voiceLanguage && voiceName.empty()))
			{
				hr = pVoice->SetVoice(cpVoiceToken);
				if (SUCCEEDED(hr)) {
					success = true;
					break;
				}
			}
		}
		result->Success(success ? 1 : 0);
	}
	void FlutterTtsPlugin::getLanguages(flutter::EncodableList& languages)
	{
		HRESULT hr;
		CComPtr<IEnumSpObjectTokens> cpEnum;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) return;

 		ULONG ulCount = 0;
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) return;

        std::set<flutter::EncodableValue> languagesSet = {};
		for (ULONG i = 0; i < ulCount; i++)
		{
			CComPtr<ISpObjectToken> cpVoiceToken;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr) || cpVoiceToken == NULL) continue;

			CComPtr<ISpDataKey> cpAttribKey;
			if (SUCCEEDED(cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey))) {
				WCHAR* pszBuffer = NULL;
				if (SUCCEEDED(cpAttribKey->GetStringValue(L"Language", &pszBuffer))) {
					wchar_t locale[100] = { 0 };
					ULONG lcid = wcstoul(pszBuffer, NULL, 16);
					std::string language = "";
					if (lcid != 0 && LCIDToLocaleName(lcid, locale, 100, 0) != 0) {
						int localeLen = WideCharToMultiByte(CP_UTF8, 0, locale, -1, NULL, 0, NULL, NULL);
						if (localeLen > 1) {
							language.resize(localeLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, locale, -1, &language[0], localeLen, NULL, NULL);
						}
					} else {
						int localeLen = WideCharToMultiByte(CP_UTF8, 0, pszBuffer, -1, NULL, 0, NULL, NULL);
						if (localeLen > 1) {
							language.resize(localeLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, pszBuffer, -1, &language[0], localeLen, NULL, NULL);
						}
					}
					if (!language.empty()) {
						languagesSet.insert(flutter::EncodableValue(language));
					}
					::CoTaskMemFree(pszBuffer);
				}
			}
		}
        for (const auto& value : languagesSet)
        {
            languages.push_back(value);
        }
	}

	void FlutterTtsPlugin::setLanguage(const std::string voiceLanguage, FlutterResult& result) {
		HRESULT hr;
		CComPtr<IEnumSpObjectTokens> cpEnum;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) { result->Success(0); return; }
		ULONG ulCount = 0;
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) { result->Success(0); return; }
		
		bool found = false;
		for (ULONG i = 0; i < ulCount; i++)
		{
			CComPtr<ISpObjectToken> cpVoiceToken;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr) || cpVoiceToken == NULL) continue;

			CComPtr<ISpDataKey> cpAttribKey;
			if (SUCCEEDED(cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey))) {
				WCHAR* pszBuffer = NULL;
				if (SUCCEEDED(cpAttribKey->GetStringValue(L"Language", &pszBuffer))) {
					wchar_t locale[100] = { 0 };
					ULONG lcid = wcstoul(pszBuffer, NULL, 16);
					std::string language = "";
					if (lcid != 0 && LCIDToLocaleName(lcid, locale, 100, 0) != 0) {
						int localeLen = WideCharToMultiByte(CP_UTF8, 0, locale, -1, NULL, 0, NULL, NULL);
						if (localeLen > 1) {
							language.resize(localeLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, locale, -1, &language[0], localeLen, NULL, NULL);
						}
					} else {
						int localeLen = WideCharToMultiByte(CP_UTF8, 0, pszBuffer, -1, NULL, 0, NULL, NULL);
						if (localeLen > 1) {
							language.resize(localeLen - 1);
							WideCharToMultiByte(CP_UTF8, 0, pszBuffer, -1, &language[0], localeLen, NULL, NULL);
						}
					}
					if (language == voiceLanguage)
					{
						pVoice->SetVoice(cpVoiceToken);
						found = true;
						::CoTaskMemFree(pszBuffer);
						break;
					}
					::CoTaskMemFree(pszBuffer);
				}
			}
		}
		result->Success(found ? 1 : 0);
	}


	void FlutterTtsPlugin::HandleMethodCall(
		const flutter::MethodCall<flutter::EncodableValue>& method_call,
		FlutterResult result) {

		if (method_call.method_name().compare("getPlatformVersion") == 0) {
			std::ostringstream version_stream;
			version_stream << "Windows ";
			if (IsWindows10OrGreater()) {
				version_stream << "10+";
			}
			else if (IsWindows8OrGreater()) {
				version_stream << "8";
			}
			else if (IsWindows7OrGreater()) {
				version_stream << "7";
			}
			result->Success(flutter::EncodableValue(version_stream.str()));
		}
#endif
		else if (method_call.method_name().compare("awaitSpeakCompletion") == 0) {
            const flutter::EncodableValue arg = method_call.arguments()[0];
            if (std::holds_alternative<bool>(arg)) {
                awaitSpeakCompletion = std::get<bool>(arg);
                result->Success(1);
            }
            else result->Success(0);
        }
		else if (method_call.method_name().compare("speak") == 0) {
			if (isPaused) { continuePlay(); result->Success(1); return; }
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<std::string>(arg)) {
				if (!speaking()) {
					const std::string text = std::get<std::string>(arg);
					speak(text, std::move(result));
				}
				else result->Success(0);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("pause") == 0) {
			FlutterTtsPlugin::pause();
			result->Success(1);
		}
		else if (method_call.method_name().compare("setLanguage") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<std::string>(arg)) {
				const std::string lang = std::get<std::string>(arg);
				setLanguage(lang, result);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("setVolume") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<double>(arg)) {
				const double newVolume = std::get<double>(arg);
				setVolume(newVolume);
				result->Success(1);
			}
			else result->Success(0);

		}
		else if (method_call.method_name().compare("setSpeechRate") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<double>(arg)) {
				const double newRate = std::get<double>(arg);
				setRate(newRate);
				result->Success(1);
			}
			else result->Success(0);

		}
        else if (method_call.method_name().compare("setPitch") == 0) {
            const flutter::EncodableValue arg = method_call.arguments()[0];
            if (std::holds_alternative<double>(arg)) {
                const double newPitch = std::get<double>(arg);
                setPitch(newPitch);
                result->Success(1);
            }
            else result->Success(0);
        }
		else if (method_call.method_name().compare("setVoice") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<flutter::EncodableMap>(arg)) {
				const flutter::EncodableMap voiceInfo = std::get<flutter::EncodableMap>(arg);
				std::string voiceLanguage = "";
				std::string voiceName = "";
				auto voiceLanguage_it = voiceInfo.find(flutter::EncodableValue("locale"));
				if (voiceLanguage_it != voiceInfo.end()) voiceLanguage = std::get<std::string>(voiceLanguage_it->second);
				auto voiceName_it = voiceInfo.find(flutter::EncodableValue("name"));
				if (voiceName_it != voiceInfo.end()) voiceName = std::get<std::string>(voiceName_it->second);
				setVoice(voiceLanguage, voiceName, result);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("stop") == 0) {
			stop();
			result->Success(1);
		}
		else if (method_call.method_name().compare("getLanguages") == 0) {
			flutter::EncodableList l;
			getLanguages(l);
			result->Success(l);
		}
		else if (method_call.method_name().compare("getVoices") == 0) {
			flutter::EncodableList l;
			getVoices(l);
			result->Success(l);
		}
		else {
			result->NotImplemented();
		}
	}
}

void FlutterTtsPluginRegisterWithRegistrar(
	FlutterDesktopPluginRegistrarRef registrar) {
	FlutterTtsPlugin::RegisterWithRegistrar(
		flutter::PluginRegistrarManager::GetInstance()
		->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
