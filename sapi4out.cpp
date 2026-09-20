#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <excpt.h>

#include "sapi4.hpp"

static LPSTR WideToCodePage(LPCWSTR Input, UINT CodePage)
{
	BOOL usedDefault = FALSE;
	int size = WideCharToMultiByte(
		CodePage, WC_NO_BEST_FIT_CHARS, Input, -1, NULL, 0, NULL, &usedDefault);
	if (size == 0 || usedDefault) {
		return NULL;
	}

	LPSTR output = (LPSTR)malloc(size);
	if (!output) {
		return NULL;
	}

	usedDefault = FALSE;
	if (!WideCharToMultiByte(
			CodePage, WC_NO_BEST_FIT_CHARS, Input, -1, output, size, NULL, &usedDefault) ||
		usedDefault) {
		free(output);
		return NULL;
	}

	return output;
}

static UINT VoiceCodePage(const VOICE_INFO* VoiceInfo)
{
	CHAR codePage[16];
	LCID locale = MAKELCID(VoiceInfo->ModeInfo.language.LanguageID, SORT_DEFAULT);
	if (GetLocaleInfoA(locale, LOCALE_IDEFAULTANSICODEPAGE, codePage, sizeof(codePage))) {
		UINT parsed = (UINT)strtoul(codePage, NULL, 10);
		if (parsed != 0 && IsValidCodePage(parsed)) {
			return parsed;
		}
	}

	return CP_ACP;
}

int wmain(int argc, wchar_t** argv)
{
	if (argc != 5) {
		fprintf(stderr, "usage: sapi4out.exe <voice> <pitch> <speed> <text>\n");
		return 2;
	}

	LPSTR voice = WideToCodePage(argv[1], CP_ACP);
	if (!voice) {
		fprintf(stderr, "voice name cannot be represented in the Windows code page\n");
		return 3;
	}

	VOICE_INFO VoiceInfo;
	memset((void *)&VoiceInfo, 0, sizeof(VoiceInfo));
	if (!InitializeForVoice(voice, &VoiceInfo)) {
		free(voice);
		fprintf(stderr, "could not initialize voice\n");
		return 4;
	}
	free(voice);

	UINT codePage = VoiceCodePage(&VoiceInfo);
	LPSTR text = WideToCodePage(argv[4], codePage);
	if (!text) {
		fprintf(stderr, "text cannot be represented in voice code page %u\n", codePage);
		DeinitializeForVoice(&VoiceInfo);
		return 5;
	}

	UINT64 Len;
	
	LPSTR outFile = (LPSTR)malloc(17);
	if (!outFile) {
		free(text);
		DeinitializeForVoice(&VoiceInfo);
		return 6;
	}

	BOOL success = GetTTS(
		&VoiceInfo, (WORD)_wtoi(argv[2]), (DWORD)_wtol(argv[3]), text, &Len, &outFile);
	free(text);
	DeinitializeForVoice(&VoiceInfo);
	if (!success) {
		free(outFile);
		fprintf(stderr, "voice synthesis failed\n");
		return 7;
	}
	
	printf("%s\n", outFile);
	free(outFile);
	return 0;
}
