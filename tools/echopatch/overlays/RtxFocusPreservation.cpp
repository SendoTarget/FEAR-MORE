#pragma once

#include "../../Globals.cpp"
#include "../../Addresses.cpp"

namespace
{
    constexpr size_t kRtxFocusCallSize = 5;
    constexpr size_t kInitRenderGuardSize = 9;
    constexpr uintptr_t kInitRenderCallOffset = 0xE0;
    constexpr uintptr_t kTermRenderCallOffset = 0x190;

    // Exact F.E.A.R. v1.08 instructions after SteamDRM has decrypted WindowProc.
    // The gain guard includes the compiler's `test eax, eax; je success` so the
    // replacement cannot leave that result check consuming an undefined value.
    constexpr uint8_t kExpectedInitRenderContext[kInitRenderGuardSize] =
        { 0xE8, 0x4B, 0x6C, 0x00, 0x00, 0x85, 0xC0, 0x74, 0x20 };
    constexpr uint8_t kSuccessfulInitRenderResult[kRtxFocusCallSize] =
        { 0xB8, 0x00, 0x00, 0x00, 0x00 };
    constexpr uint8_t kSuccessfulInitRenderContext[kInitRenderGuardSize] =
        { 0xB8, 0x00, 0x00, 0x00, 0x00, 0x85, 0xC0, 0x74, 0x20 };
    constexpr uint8_t kExpectedTermRenderCall[kRtxFocusCallSize] =
        { 0xE8, 0xBB, 0x68, 0x00, 0x00 };
    constexpr uint8_t kBypassedTermRenderCall[kRtxFocusCallSize] =
        { 0x90, 0x90, 0x90, 0x90, 0x90 };

    constexpr char kRtxFocusPreservationProof[] =
        "FearMore RTX focus preservation: exact FEAR v1.08 renderer calls bypassed; "
        "focus events, input, sound, and Console_WindowProc detours preserved.";

    static bool MatchesExpectedBytes(uintptr_t address, const uint8_t* expected, size_t size)
    {
        return address != 0 &&
            std::memcmp(reinterpret_cast<const void*>(address), expected, size) == 0;
    }

    static void FlushCallSite(uintptr_t address)
    {
        FlushInstructionCache(
            GetCurrentProcess(),
            reinterpret_cast<const void*>(address),
            kRtxFocusCallSize);
    }

    static void AppendRtxFocusPreservationLog(const std::string& message)
    {
        HANDLE log = CreateFileA(
            "FearMore-EchoPatch.log",
            FILE_APPEND_DATA,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            nullptr);
        if (log == INVALID_HANDLE_VALUE)
            return;

        DWORD bytesWritten = 0;
        WriteFile(log, message.data(), static_cast<DWORD>(message.size()), &bytesWritten, nullptr);
        CloseHandle(log);
    }

    static void ReportRtxFocusPreservationFailure(const char* reason)
    {
        std::string message = "EchoPatch: RTX focus preservation was not applied: ";
        message += reason;
        message += "\r\n";
        OutputDebugStringA(message.c_str());
        AppendRtxFocusPreservationLog(message);

        if (ShowErrors)
        {
            MessageBoxA(nullptr, message.c_str(), "EchoPatch", MB_ICONERROR);
        }
    }

    static bool RestoreNativeFocusSites(uintptr_t initRenderCall, uintptr_t termRenderCall)
    {
        const bool initRestored = MemoryHelper::WriteMemoryRaw(
            initRenderCall,
            kExpectedInitRenderContext,
            kRtxFocusCallSize);
        const bool termRestored = MemoryHelper::WriteMemoryRaw(
            termRenderCall,
            kExpectedTermRenderCall,
            kRtxFocusCallSize);
        FlushCallSite(initRenderCall);
        FlushCallSite(termRenderCall);
        return initRestored && termRestored &&
            MatchesExpectedBytes(initRenderCall, kExpectedInitRenderContext, kInitRenderGuardSize) &&
            MatchesExpectedBytes(termRenderCall, kExpectedTermRenderCall, kRtxFocusCallSize);
    }

    static void ReportRtxFocusPreservationSuccess()
    {
        std::string message = "EchoPatch: ";
        message += kRtxFocusPreservationProof;
        message += "\r\n";
        OutputDebugStringA(message.c_str());
        AppendRtxFocusPreservationLog(message);
    }
}

// This deliberately does not hook WindowProc. ConsoleEnabled remains the sole
// owner of the Console_WindowProc detour. Only the renderer shutdown/re-init
// calls inside the original F.E.A.R. handler are removed, leaving focus events,
// input clearing, sound release/reacquire, and console routing unchanged.
static void ApplyRtxFocusPreservation()
{
    if (!PreserveRtxRendererOnFocusChange)
        return;

    // The verified call offsets and bytes belong only to F.E.A.R. v1.08.
    // FEARMP and both expansions retain their upstream activation behavior.
    if (g_State.CurrentFEARGame != FEAR)
    {
        ReportRtxFocusPreservationFailure("the active executable is not F.E.A.R. v1.08");
        return;
    }

    const uintptr_t windowProc = GetAddress(Addr::Console_WindowProc);
    if (windowProc == 0)
    {
        ReportRtxFocusPreservationFailure("Console_WindowProc has no verified address");
        return;
    }

    const uintptr_t initRenderCall = windowProc + kInitRenderCallOffset;
    const uintptr_t termRenderCall = windowProc + kTermRenderCallOffset;

    // Verify both sites before the first write so a revision mismatch cannot
    // leave a half-applied focus policy.
    if (!MatchesExpectedBytes(initRenderCall, kExpectedInitRenderContext, kInitRenderGuardSize) ||
        !MatchesExpectedBytes(termRenderCall, kExpectedTermRenderCall, kRtxFocusCallSize))
    {
        ReportRtxFocusPreservationFailure("renderer call-site bytes did not match the pinned executable");
        return;
    }

    // r_InitRender returns LT_OK (zero). Its result is tested immediately after
    // the call, so bypassing it must provide that result explicitly rather than
    // leaving EAX undefined. MOV EAX, 0 is exactly five bytes and preserves the
    // following branch layout.
    if (!MemoryHelper::WriteMemoryRaw(
            initRenderCall,
            kSuccessfulInitRenderResult,
            kRtxFocusCallSize) ||
        !MatchesExpectedBytes(
            initRenderCall,
            kSuccessfulInitRenderContext,
            kInitRenderGuardSize))
    {
        const bool restored = RestoreNativeFocusSites(initRenderCall, termRenderCall);
        ReportRtxFocusPreservationFailure("the renderer re-initialization call was not writable");
        if (!restored)
            ReportRtxFocusPreservationFailure("the failed initialization bypass could not be rolled back");
        return;
    }

    if (!MemoryHelper::MakeNOP(termRenderCall, kRtxFocusCallSize))
    {
        // Native activation behavior is safer than a one-sided lifecycle.
        const bool restored = RestoreNativeFocusSites(initRenderCall, termRenderCall);
        ReportRtxFocusPreservationFailure(restored
            ? "the renderer shutdown call was not writable; the first write was rolled back"
            : "the renderer shutdown call failed and the first write could not be rolled back");
        return;
    }

    FlushCallSite(initRenderCall);
    FlushCallSite(termRenderCall);
    if (!MatchesExpectedBytes(
            initRenderCall,
            kSuccessfulInitRenderContext,
            kInitRenderGuardSize) ||
        !MatchesExpectedBytes(
            termRenderCall,
            kBypassedTermRenderCall,
            kRtxFocusCallSize))
    {
        const bool restored = RestoreNativeFocusSites(initRenderCall, termRenderCall);
        ReportRtxFocusPreservationFailure(restored
            ? "post-write verification failed; native activation behavior was restored"
            : "post-write verification failed and native activation behavior could not be restored");
        return;
    }

    ReportRtxFocusPreservationSuccess();
}
