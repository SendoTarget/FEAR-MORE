#pragma once

#include "../../Globals.cpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

// This overlay is deliberately a passive observer. CameraDiagnostics (or a
// later shared D3D9 hook hub) remains the sole MinHook owner and calls the
// functions below from its successful SetVertexShader, pre-draw, and
// EndScene paths. In particular, BeforeDraw receives the original
// SetTransform trampoline so reassertion cannot recurse through the hook hub.
namespace RtxCameraReassertion
{
    using SetTransformFn = HRESULT(WINAPI*)(
        IDirect3DDevice9*, D3DTRANSFORMSTATETYPE, const D3DMATRIX*);

    static constexpr uint32_t kSchema = 1;
    static constexpr uint64_t kFrameLimit = 300;
    // Frontend presentation can run far above the gameplay cap, so pre-arm
    // lifetime and progress use QPC wall time rather than EndScene counts.
    static constexpr LONGLONG kPreArmTimeoutSeconds = 300;
    static constexpr LONGLONG kPreArmProgressSeconds = 60;
    static constexpr uint32_t kEventRecordLimit = 16384;
    static constexpr uint64_t kInitialEventSamples = 16;
    static constexpr uint64_t kPeriodicEventSampleInterval = 1024;
    static constexpr uint32_t kTargetShaderHash = 0xF7D91705u;
    static constexpr uint32_t kTargetShaderBytes = 880;
    static constexpr uint32_t kTargetShaderVersion = 0xFFFE0101u;
    static constexpr UINT kTargetConstantRegister = 0;
    static constexpr UINT kTargetConstantRegisterCount = 4;
    static constexpr float kAbsoluteTolerance = 0.002f;
    static constexpr float kRelativeTolerance = 0.00002f;
    static constexpr float kMainNearPlane = 4.3f;
    static constexpr float kMainNearTolerance = 0.02f;
    static constexpr char kCapabilityProof[] =
        "FearMoreDiagnostics\\rtx-camera-reassertion-";
    static constexpr char kExperimentProof[] =
        "FearMore RTX camera reassertion: F7D91705-880 c0-c3, "
        "300-frame query-gated passive observer.";

    struct ShaderIdentity
    {
        uint32_t hash = 0;
        uint32_t byteCount = 0;
        uint32_t versionToken = 0;
        bool known = false;
    };

    struct MatrixComparison
    {
        bool finite = false;
        bool matches = false;
        float maximumAbsoluteError = 0.0f;
        float maximumNormalizedError = 0.0f;
        float rootMeanSquareError = 0.0f;
    };

    static SRWLOCK s_StateLock = SRWLOCK_INIT;
    static HANDLE s_Log = INVALID_HANDLE_VALUE;
    static IDirect3DDevice9* s_Device = nullptr;
    static DWORD s_ProcessId = 0;
    static LARGE_INTEGER s_QpcFrequency = {};
    static uint64_t s_FrameNumber = 0;
    static uint64_t s_PreArmFrameNumber = 0;
    static LARGE_INTEGER s_PreArmStartQpc = {};
    static LARGE_INTEGER s_PreArmDeadlineQpc = {};
    static LARGE_INTEGER s_NextPreArmProgressQpc = {};
    static LONGLONG s_PreArmProgressTicks = 0;
    static bool s_Installed = false;
    static bool s_Active = false;
    static bool s_Armed = false;
    static bool s_PreArmClockReady = false;
    static IDirect3DVertexShader9* s_ObservedShaderPointer = nullptr;
    static ShaderIdentity s_ObservedShader;
    static bool s_ObservedShaderIsTarget = false;
    static uint64_t s_TargetShaderSelections = 0;
    static uint64_t s_CandidateDraws = 0;
    static uint64_t s_ShaderStateDivergences = 0;
    static uint64_t s_QueryFailures = 0;
    static uint64_t s_NumericRejects = 0;
    static uint64_t s_NumericMatches = 0;
    static uint64_t s_ReassertAttempts = 0;
    static uint64_t s_ReassertSuccesses = 0;
    static uint64_t s_ReassertFailures = 0;
    static uint32_t s_EventRecords = 0;
    static uint64_t s_SampledOutEventRecords = 0;
    static uint64_t s_DroppedEventRecords = 0;

    class ExclusiveStateLock
    {
    public:
        ExclusiveStateLock() { AcquireSRWLockExclusive(&s_StateLock); }
        ~ExclusiveStateLock() { ReleaseSRWLockExclusive(&s_StateLock); }
        ExclusiveStateLock(const ExclusiveStateLock&) = delete;
        ExclusiveStateLock& operator=(const ExclusiveStateLock&) = delete;
    };

    static bool TryReadQpc(LARGE_INTEGER& value)
    {
        value = {};
        return QueryPerformanceCounter(&value) != FALSE;
    }

    static LARGE_INTEGER ReadQpc()
    {
        LARGE_INTEGER value = {};
        TryReadQpc(value);
        return value;
    }

    static uint32_t HashBytes(const void* data, size_t byteCount)
    {
        // Same unsigned-byte FNV-1a implementation as CameraDiagnostics.
        const uint8_t* bytes = static_cast<const uint8_t*>(data);
        uint32_t hash = 2166136261u;
        for (size_t index = 0; index < byteCount; ++index)
        {
            hash ^= static_cast<uint32_t>(bytes[index]);
            hash *= 16777619u;
        }
        return hash;
    }

    static bool IsDirectoryWithoutReparsePoint(const std::wstring& path)
    {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        return attributes != INVALID_FILE_ATTRIBUTES &&
            (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
            (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
    }

    static std::vector<std::wstring> TokenizeCommandLine(const wchar_t* commandLine)
    {
        std::vector<std::wstring> arguments;
        if (!commandLine)
            return arguments;

        const wchar_t* cursor = commandLine;
        while (*cursor)
        {
            while (*cursor == L' ' || *cursor == L'\t')
                ++cursor;
            if (!*cursor)
                break;

            bool quoted = false;
            std::wstring argument;
            while (*cursor)
            {
                if (*cursor == L'"')
                {
                    quoted = !quoted;
                    ++cursor;
                    continue;
                }
                if (!quoted && (*cursor == L' ' || *cursor == L'\t'))
                    break;
                argument.push_back(*cursor++);
            }
            arguments.push_back(argument);
        }
        return arguments;
    }

    static bool GetUserDirectory(std::wstring& userDirectory)
    {
        const std::vector<std::wstring> arguments = TokenizeCommandLine(GetCommandLineW());
        for (size_t index = 0; index + 1 < arguments.size(); ++index)
        {
            if (_wcsicmp(arguments[index].c_str(), L"-userdirectory") != 0)
                continue;

            const std::wstring& selected = arguments[index + 1];
            if (selected.empty())
                return false;

            const DWORD required = GetFullPathNameW(selected.c_str(), 0, nullptr, nullptr);
            if (required == 0)
                return false;
            std::vector<wchar_t> fullPath(static_cast<size_t>(required) + 1, L'\0');
            if (GetFullPathNameW(
                    selected.c_str(),
                    static_cast<DWORD>(fullPath.size()),
                    fullPath.data(),
                    nullptr) == 0)
            {
                return false;
            }

            userDirectory.assign(fullPath.data());
            while (userDirectory.size() > 3 &&
                (userDirectory.back() == L'\\' || userDirectory.back() == L'/'))
            {
                userDirectory.pop_back();
            }
            return IsDirectoryWithoutReparsePoint(userDirectory);
        }
        return false;
    }

    static bool IsExactFear108Executable()
    {
        if (g_State.CurrentFEARGame != FEAR || g_State.BaseAddress == 0)
            return false;

        const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(g_State.BaseAddress);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE ||
            dos->e_lfanew <= 0 || dos->e_lfanew > 0x100000)
        {
            return false;
        }

        const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(
            g_State.BaseAddress + static_cast<uintptr_t>(dos->e_lfanew));
        return nt->Signature == IMAGE_NT_SIGNATURE &&
            nt->FileHeader.Machine == IMAGE_FILE_MACHINE_I386 &&
            nt->FileHeader.TimeDateStamp == FEAR_TIMESTAMP &&
            nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC;
    }

    static void WriteLogLineLocked(const char* line)
    {
        if (s_Log == INVALID_HANDLE_VALUE || !line)
            return;

        DWORD bytesWritten = 0;
        WriteFile(s_Log, line, static_cast<DWORD>(strlen(line)), &bytesWritten, nullptr);
        static constexpr char newline[] = "\r\n";
        WriteFile(s_Log, newline, static_cast<DWORD>(sizeof(newline) - 1), &bytesWritten, nullptr);
    }

    static bool ReserveEventRecordLocked()
    {
        if (s_EventRecords >= kEventRecordLimit)
        {
            ++s_DroppedEventRecords;
            return false;
        }
        ++s_EventRecords;
        return true;
    }

    static bool ShouldRecordOccurrenceLocked(uint64_t occurrence)
    {
        // Preserve enough ordered detail to diagnose startup while keeping
        // synchronous filesystem writes off nearly every draw. Aggregate
        // counters remain exhaustive and are emitted in the final summary.
        const bool selected = occurrence <= kInitialEventSamples ||
            (occurrence % kPeriodicEventSampleInterval) == 0;
        if (!selected)
            ++s_SampledOutEventRecords;
        return selected;
    }

    static void ResetExperimentStateLocked()
    {
        s_FrameNumber = 0;
        s_PreArmFrameNumber = 0;
        s_PreArmStartQpc = {};
        s_PreArmDeadlineQpc = {};
        s_NextPreArmProgressQpc = {};
        s_PreArmProgressTicks = 0;
        s_Active = false;
        s_Armed = false;
        s_PreArmClockReady = false;
        s_ObservedShaderPointer = nullptr;
        s_ObservedShader = {};
        s_ObservedShaderIsTarget = false;
        s_TargetShaderSelections = 0;
        s_CandidateDraws = 0;
        s_ShaderStateDivergences = 0;
        s_QueryFailures = 0;
        s_NumericRejects = 0;
        s_NumericMatches = 0;
        s_ReassertAttempts = 0;
        s_ReassertSuccesses = 0;
        s_ReassertFailures = 0;
        s_EventRecords = 0;
        s_SampledOutEventRecords = 0;
        s_DroppedEventRecords = 0;
    }

    static bool OpenLogLocked()
    {
        std::wstring userDirectory;
        if (!GetUserDirectory(userDirectory))
            return false;

        const std::wstring diagnosticsDirectory = userDirectory + L"\\FearMoreDiagnostics";
        if (!CreateDirectoryW(diagnosticsDirectory.c_str(), nullptr) &&
            GetLastError() != ERROR_ALREADY_EXISTS)
        {
            return false;
        }
        if (!IsDirectoryWithoutReparsePoint(diagnosticsDirectory))
            return false;

        s_ProcessId = GetCurrentProcessId();
        wchar_t fileName[96] = {};
        swprintf_s(fileName, L"rtx-camera-reassertion-%lu.jsonl", s_ProcessId);
        const std::wstring logPath = diagnosticsDirectory + L"\\" + fileName;
        s_Log = CreateFileW(
            logPath.c_str(),
            GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr,
            CREATE_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            nullptr);
        if (s_Log == INVALID_HANDLE_VALUE)
            return false;

        if (QueryPerformanceFrequency(&s_QpcFrequency) != FALSE)
            return true;

        CloseHandle(s_Log);
        s_Log = INVALID_HANDLE_VALUE;
        return false;
    }

    static bool InitializePreArmClockLocked()
    {
        s_PreArmClockReady = false;
        if (s_QpcFrequency.QuadPart <= 0)
            return false;

        const LONGLONG maximum = (std::numeric_limits<LONGLONG>::max)();
        if (s_QpcFrequency.QuadPart > maximum / kPreArmTimeoutSeconds ||
            s_QpcFrequency.QuadPart > maximum / kPreArmProgressSeconds)
        {
            return false;
        }

        LARGE_INTEGER start = {};
        if (!TryReadQpc(start) || start.QuadPart < 0)
            return false;

        const LONGLONG timeoutTicks =
            s_QpcFrequency.QuadPart * kPreArmTimeoutSeconds;
        const LONGLONG progressTicks =
            s_QpcFrequency.QuadPart * kPreArmProgressSeconds;
        if (timeoutTicks <= 0 || progressTicks <= 0 ||
            start.QuadPart > maximum - timeoutTicks)
        {
            return false;
        }

        s_PreArmStartQpc = start;
        s_PreArmDeadlineQpc.QuadPart = start.QuadPart + timeoutTicks;
        s_NextPreArmProgressQpc.QuadPart = start.QuadPart + progressTicks;
        s_PreArmProgressTicks = progressTicks;
        s_PreArmClockReady = true;
        return true;
    }

    static double GetPreArmElapsedSecondsLocked(const LARGE_INTEGER& qpc)
    {
        if (!s_PreArmClockReady || s_QpcFrequency.QuadPart <= 0 ||
            qpc.QuadPart < s_PreArmStartQpc.QuadPart)
        {
            return -1.0;
        }
        return static_cast<double>(qpc.QuadPart - s_PreArmStartQpc.QuadPart) /
            static_cast<double>(s_QpcFrequency.QuadPart);
    }

    static void AdvancePreArmProgressDeadlineLocked(const LARGE_INTEGER& qpc)
    {
        while (s_NextPreArmProgressQpc.QuadPart <= qpc.QuadPart &&
            s_NextPreArmProgressQpc.QuadPart < s_PreArmDeadlineQpc.QuadPart)
        {
            const LONGLONG remaining = s_PreArmDeadlineQpc.QuadPart -
                s_NextPreArmProgressQpc.QuadPart;
            if (remaining <= s_PreArmProgressTicks)
                s_NextPreArmProgressQpc = s_PreArmDeadlineQpc;
            else
                s_NextPreArmProgressQpc.QuadPart += s_PreArmProgressTicks;
        }
    }

    static void CloseLogLocked()
    {
        if (s_Log == INVALID_HANDLE_VALUE)
            return;
        FlushFileBuffers(s_Log);
        CloseHandle(s_Log);
        s_Log = INVALID_HANDLE_VALUE;
    }

    static void WriteSummaryLocked(const char* reason, const char* state)
    {
        const LARGE_INTEGER qpc = ReadQpc();
        char line[2048] = {};
        sprintf_s(line,
            "{\"event\":\"summary\",\"schema\":%u,\"capability\":\"rtx-camera-reassertion-v1\"," 
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"state\":\"%s\"," 
            "\"armed\":%s,\"prearmFrames\":%llu,\"frame\":%llu,\"reason\":\"%s\"," 
            "\"targetShaderSelections\":%llu,\"candidateDraws\":%llu,\"shaderStateDivergences\":%llu," 
            "\"queryFailures\":%llu,\"numericRejects\":%llu,\"numericMatches\":%llu," 
            "\"reassertAttempts\":%llu,\"reassertSuccesses\":%llu,\"reassertFailures\":%llu," 
            "\"eventRecords\":%u,\"sampledOutEventRecords\":%llu," 
            "\"droppedEventRecords\":%llu,\"active\":false}",
            kSchema,
            s_ProcessId,
            static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart),
            state,
            s_Armed ? "true" : "false",
            static_cast<unsigned long long>(s_PreArmFrameNumber),
            static_cast<unsigned long long>(s_FrameNumber),
            reason,
            static_cast<unsigned long long>(s_TargetShaderSelections),
            static_cast<unsigned long long>(s_CandidateDraws),
            static_cast<unsigned long long>(s_ShaderStateDivergences),
            static_cast<unsigned long long>(s_QueryFailures),
            static_cast<unsigned long long>(s_NumericRejects),
            static_cast<unsigned long long>(s_NumericMatches),
            static_cast<unsigned long long>(s_ReassertAttempts),
            static_cast<unsigned long long>(s_ReassertSuccesses),
            static_cast<unsigned long long>(s_ReassertFailures),
            s_EventRecords,
            static_cast<unsigned long long>(s_SampledOutEventRecords),
            static_cast<unsigned long long>(s_DroppedEventRecords));
        WriteLogLineLocked(line);
    }

    static void WritePreArmLocked(const char* reason, const LARGE_INTEGER& qpc)
    {
        char line[1024] = {};
        sprintf_s(line,
            "{\"event\":\"prearm\",\"schema\":%u,\"capability\":\"rtx-camera-reassertion-v1\"," 
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"state\":\"prearm\"," 
            "\"armed\":false,\"reason\":\"%s\",\"prearmFrame\":%llu," 
            "\"elapsedSeconds\":%.6f,\"timeoutSeconds\":%lld," 
            "\"deadlineClock\":\"qpc\",\"targetShaderHash\":\"F7D91705\"}",
            kSchema,
            s_ProcessId,
            static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart),
            reason,
            static_cast<unsigned long long>(s_PreArmFrameNumber),
            GetPreArmElapsedSecondsLocked(qpc),
            static_cast<long long>(kPreArmTimeoutSeconds));
        WriteLogLineLocked(line);
    }

    static void WriteArmLocked(const LARGE_INTEGER& qpc)
    {
        char line[1024] = {};
        sprintf_s(line,
            "{\"event\":\"arm\",\"schema\":%u,\"capability\":\"rtx-camera-reassertion-v1\"," 
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"state\":\"armed\"," 
            "\"armed\":true,\"reason\":\"exact-target-shader-selected\"," 
            "\"prearmFrames\":%llu,\"prearmElapsedSeconds\":%.6f," 
            "\"frame\":0,\"shaderHash\":\"F7D91705\"," 
            "\"shaderBytes\":880,\"shaderVersion\":\"FFFE0101\",\"register\":0," 
            "\"registerCount\":4,\"boundedFrames\":%llu}",
            kSchema,
            s_ProcessId,
            static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart),
            static_cast<unsigned long long>(s_PreArmFrameNumber),
            GetPreArmElapsedSecondsLocked(qpc),
            static_cast<unsigned long long>(kFrameLimit));
        WriteLogLineLocked(line);
    }

    static void WriteTimeoutLocked(const char* reason, const LARGE_INTEGER& qpc)
    {
        char line[1024] = {};
        sprintf_s(line,
            "{\"event\":\"timeout\",\"schema\":%u,\"capability\":\"rtx-camera-reassertion-v1\"," 
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"state\":\"timeout\"," 
            "\"armed\":false,\"reason\":\"%s\",\"prearmFrames\":%llu," 
            "\"elapsedSeconds\":%.6f,\"timeoutSeconds\":%lld," 
            "\"deadlineClock\":\"qpc\",\"frame\":0}",
            kSchema,
            s_ProcessId,
            static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart),
            reason,
            static_cast<unsigned long long>(s_PreArmFrameNumber),
            GetPreArmElapsedSecondsLocked(qpc),
            static_cast<long long>(kPreArmTimeoutSeconds));
        WriteLogLineLocked(line);
    }

    static void ClearObservedShaderLocked()
    {
        s_ObservedShaderPointer = nullptr;
        s_ObservedShader = {};
        s_ObservedShaderIsTarget = false;
    }

    static void FailPreArmLocked(const char* reason, const LARGE_INTEGER& qpc)
    {
        s_Active = false;
        WriteTimeoutLocked(reason, qpc);
        WriteSummaryLocked(reason, "timeout");
        CloseLogLocked();
        ClearObservedShaderLocked();
    }

    static bool ResolveShaderIdentity(
        IDirect3DVertexShader9* shader,
        uint32_t suppliedHash,
        uint32_t suppliedByteCount,
        uint32_t suppliedVersionToken,
        ShaderIdentity& identity)
    {
        identity = {};
        if (!shader)
            return false;

        if (suppliedHash != 0 && suppliedByteCount != 0 && suppliedVersionToken != 0)
        {
            identity.hash = suppliedHash;
            identity.byteCount = suppliedByteCount;
            identity.versionToken = suppliedVersionToken;
            identity.known = true;
            return true;
        }

        UINT byteCount = 0;
        if (FAILED(shader->GetFunction(nullptr, &byteCount)) ||
            byteCount != kTargetShaderBytes)
        {
            return false;
        }

        std::array<uint8_t, kTargetShaderBytes> bytecode = {};
        UINT returnedByteCount = byteCount;
        if (FAILED(shader->GetFunction(bytecode.data(), &returnedByteCount)) ||
            returnedByteCount != byteCount)
        {
            return false;
        }

        identity.hash = HashBytes(bytecode.data(), bytecode.size());
        identity.byteCount = byteCount;
        std::memcpy(&identity.versionToken, bytecode.data(), sizeof(identity.versionToken));
        identity.known = true;
        return true;
    }

    static bool IsTargetShader(const ShaderIdentity& identity)
    {
        return identity.known &&
            identity.hash == kTargetShaderHash &&
            identity.byteCount == kTargetShaderBytes &&
            identity.versionToken == kTargetShaderVersion;
    }

    static D3DMATRIX MultiplyMatrix(const D3DMATRIX& left, const D3DMATRIX& right)
    {
        D3DMATRIX result = {};
        for (size_t row = 0; row < 4; ++row)
        {
            for (size_t column = 0; column < 4; ++column)
            {
                for (size_t inner = 0; inner < 4; ++inner)
                    result.m[row][column] += left.m[row][inner] * right.m[inner][column];
            }
        }
        return result;
    }

    static D3DMATRIX TransposeMatrix(const D3DMATRIX& matrix)
    {
        D3DMATRIX result = {};
        for (size_t row = 0; row < 4; ++row)
        {
            for (size_t column = 0; column < 4; ++column)
                result.m[row][column] = matrix.m[column][row];
        }
        return result;
    }

    static MatrixComparison CompareMatrices(
        const D3DMATRIX& observed,
        const D3DMATRIX& expected)
    {
        MatrixComparison comparison;
        comparison.finite = true;
        double squaredError = 0.0;
        for (size_t row = 0; row < 4; ++row)
        {
            for (size_t column = 0; column < 4; ++column)
            {
                const float actual = observed.m[row][column];
                const float wanted = expected.m[row][column];
                if (!std::isfinite(actual) || !std::isfinite(wanted))
                {
                    comparison.finite = false;
                    comparison.matches = false;
                    return comparison;
                }

                const float absoluteError = std::fabs(actual - wanted);
                const float allowedError = std::max(
                    kAbsoluteTolerance,
                    std::fabs(wanted) * kRelativeTolerance);
                comparison.maximumAbsoluteError = std::max(
                    comparison.maximumAbsoluteError,
                    absoluteError);
                comparison.maximumNormalizedError = std::max(
                    comparison.maximumNormalizedError,
                    absoluteError / allowedError);
                squaredError += static_cast<double>(absoluteError) * absoluteError;
            }
        }

        comparison.rootMeanSquareError = static_cast<float>(std::sqrt(squaredError / 16.0));
        comparison.matches = comparison.maximumNormalizedError <= 1.0f;
        return comparison;
    }

    static void LogQueryFailureLocked(
        HRESULT getVertexShaderResult,
        HRESULT getWorldResult,
        HRESULT getViewResult,
        HRESULT getProjectionResult,
        HRESULT getConstantsResult,
        const ShaderIdentity& actualIdentity,
        bool pointerMatched)
    {
        if (!ReserveEventRecordLocked())
            return;
        const LARGE_INTEGER qpc = ReadQpc();
        char line[1536] = {};
        sprintf_s(line,
            "{\"event\":\"query-failure\",\"schema\":%u,\"capability\":\"rtx-camera-reassertion-v1\"," 
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"frame\":%llu," 
            "\"shaderHash\":\"%08X\",\"shaderBytes\":%u,\"shaderVersion\":\"%08X\"," 
            "\"pointerMatched\":%s,\"hresult\":{\"getVertexShader\":\"%08lX\"," 
            "\"getWorld\":\"%08lX\",\"getView\":\"%08lX\",\"getProjection\":\"%08lX\"," 
            "\"getConstants\":\"%08lX\"}}",
            kSchema,
            s_ProcessId,
            static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart),
            static_cast<unsigned long long>(s_FrameNumber),
            actualIdentity.hash,
            actualIdentity.byteCount,
            actualIdentity.versionToken,
            pointerMatched ? "true" : "false",
            static_cast<unsigned long>(getVertexShaderResult),
            static_cast<unsigned long>(getWorldResult),
            static_cast<unsigned long>(getViewResult),
            static_cast<unsigned long>(getProjectionResult),
            static_cast<unsigned long>(getConstantsResult));
        WriteLogLineLocked(line);
    }

    static void LogNumericRejectLocked(
        const MatrixComparison& comparison,
        float nearDifference,
        bool mainNearPlane)
    {
        if (!ReserveEventRecordLocked())
            return;
        const LARGE_INTEGER qpc = ReadQpc();
        char line[1024] = {};
        sprintf_s(line,
            "{\"event\":\"numeric-reject\",\"schema\":%u,\"capability\":\"rtx-camera-reassertion-v1\"," 
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"frame\":%llu," 
            "\"shaderHash\":\"F7D91705\",\"register\":0,\"registerCount\":4," 
            "\"finite\":%s,\"matrixMatched\":%s,\"mainNearPlane\":%s," 
            "\"nearDifference\":%.9g,\"maximumAbsoluteError\":%.9g," 
            "\"maximumNormalizedError\":%.9g,\"rootMeanSquareError\":%.9g}",
            kSchema,
            s_ProcessId,
            static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart),
            static_cast<unsigned long long>(s_FrameNumber),
            comparison.finite ? "true" : "false",
            comparison.matches ? "true" : "false",
            mainNearPlane ? "true" : "false",
            nearDifference,
            comparison.maximumAbsoluteError,
            comparison.maximumNormalizedError,
            comparison.rootMeanSquareError);
        WriteLogLineLocked(line);
    }

    static void LogReassertLocked(
        const MatrixComparison& comparison,
        float nearDifference,
        HRESULT getVertexShaderResult,
        HRESULT getWorldResult,
        HRESULT getViewResult,
        HRESULT getProjectionResult,
        HRESULT getConstantsResult,
        HRESULT setWorldResult,
        HRESULT setViewResult,
        HRESULT setProjectionResult)
    {
        if (!ReserveEventRecordLocked())
            return;
        const LARGE_INTEGER qpc = ReadQpc();
        char line[2048] = {};
        sprintf_s(line,
            "{\"event\":\"reassert\",\"schema\":%u,\"capability\":\"rtx-camera-reassertion-v1\"," 
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"frame\":%llu," 
            "\"shaderHash\":\"F7D91705\",\"shaderBytes\":880,\"shaderVersion\":\"FFFE0101\"," 
            "\"register\":0,\"registerCount\":4,\"matrixMatched\":true,\"mainNearPlane\":true," 
            "\"nearDifference\":%.9g,\"maximumAbsoluteError\":%.9g," 
            "\"maximumNormalizedError\":%.9g,\"rootMeanSquareError\":%.9g," 
            "\"hresult\":{\"getVertexShader\":\"%08lX\",\"getWorld\":\"%08lX\"," 
            "\"getView\":\"%08lX\",\"getProjection\":\"%08lX\",\"getConstants\":\"%08lX\"," 
            "\"setWorld\":\"%08lX\",\"setView\":\"%08lX\",\"setProjection\":\"%08lX\"}," 
            "\"reasserted\":%s}",
            kSchema,
            s_ProcessId,
            static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart),
            static_cast<unsigned long long>(s_FrameNumber),
            nearDifference,
            comparison.maximumAbsoluteError,
            comparison.maximumNormalizedError,
            comparison.rootMeanSquareError,
            static_cast<unsigned long>(getVertexShaderResult),
            static_cast<unsigned long>(getWorldResult),
            static_cast<unsigned long>(getViewResult),
            static_cast<unsigned long>(getProjectionResult),
            static_cast<unsigned long>(getConstantsResult),
            static_cast<unsigned long>(setWorldResult),
            static_cast<unsigned long>(setViewResult),
            static_cast<unsigned long>(setProjectionResult),
            SUCCEEDED(setWorldResult) && SUCCEEDED(setViewResult) && SUCCEEDED(setProjectionResult)
                ? "true"
                : "false");
        WriteLogLineLocked(line);
    }

    static void Install(IDirect3DDevice9* device)
    {
        if (!EnableRtxCameraReassertion || !device || !IsExactFear108Executable())
            return;

        ExclusiveStateLock lock;
        if (s_Installed && s_Device == device)
            return;

        if (s_Installed && s_Active && s_Log != INVALID_HANDLE_VALUE)
            WriteSummaryLocked("device-replaced", "aborted");
        CloseLogLocked();
        ResetExperimentStateLocked();

        s_Installed = true;
        s_Device = device;
        if (!OpenLogLocked())
        {
            // Installation can be retried if the diagnostics path was only
            // temporarily unavailable when the D3D9 device was created.
            s_Installed = false;
            s_Device = nullptr;
            return;
        }

        s_Active = true;
        if (!InitializePreArmClockLocked())
        {
            const LARGE_INTEGER unavailableQpc = {};
            FailPreArmLocked("qpc-unavailable", unavailableQpc);
            return;
        }

        OutputDebugStringA(kCapabilityProof);
        OutputDebugStringA(kExperimentProof);
        const LARGE_INTEGER qpc = s_PreArmStartQpc;
        char line[3072] = {};
        sprintf_s(line,
            "{\"event\":\"capability\",\"schema\":%u,\"capability\":\"rtx-camera-reassertion-v1\"," 
            "\"proof\":\"FearMoreDiagnostics\\\\rtx-camera-reassertion-\"," 
            "\"experimentProof\":\"FearMore RTX camera reassertion: F7D91705-880 c0-c3, "
            "300-frame query-gated passive observer.\",\"pid\":%lu,\"qpc\":%lld," 
            "\"qpcFrequency\":%lld,\"frame\":0,\"enabled\":true," 
            "\"exactExecutable\":{\"game\":\"FEAR\",\"version\":\"1.08\"," 
            "\"timestamp\":\"44EF6AE6\",\"machine\":\"x86\"}," 
            "\"passiveObserver\":true,\"ownsHooks\":false," 
            "\"callbacks\":[\"AfterSetVertexShader\",\"BeforeDraw\",\"OnEndScene\"]," 
            "\"targetShader\":{\"hash\":\"F7D91705\",\"bytes\":880," 
            "\"version\":\"FFFE0101\",\"register\":0,\"registerCount\":4}," 
            "\"hashAlgorithm\":\"fnv1a32-unsigned-byte\",\"directQueries\":true," 
            "\"queries\":[\"GetVertexShader\",\"GetTransform(WORLD)\",\"GetTransform(VIEW)\"," 
            "\"GetTransform(PROJECTION)\",\"GetVertexShaderConstantF(c0,4)\"]," 
            "\"matrixConvention\":\"transpose(World*View*Projection)\"," 
            "\"absoluteTolerance\":%.9g,\"relativeTolerance\":%.9g," 
            "\"mainNearDifference\":-4.3,\"mainNearTolerance\":%.9g," 
            "\"reassertsUnchangedTransforms\":true,\"setTransformViaPassedOriginal\":true," 
            "\"writesShaderConstants\":false,\"state\":\"prearm\",\"armed\":false," 
            "\"prearmFrame\":0,\"prearmTimeoutSeconds\":%lld," 
            "\"prearmProgressSeconds\":%lld,\"prearmDeadlineClock\":\"qpc\"," 
            "\"boundedFrames\":%llu,\"framesStartAfterExactTargetSelection\":true," 
            "\"boundedEventRecords\":%u,\"eventSampling\":{\"initial\":%llu," 
            "\"periodicInterval\":%llu},\"active\":true}",
            kSchema,
            s_ProcessId,
            static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart),
            kAbsoluteTolerance,
            kRelativeTolerance,
            kMainNearTolerance,
            static_cast<long long>(kPreArmTimeoutSeconds),
            static_cast<long long>(kPreArmProgressSeconds),
            static_cast<unsigned long long>(kFrameLimit),
            kEventRecordLimit,
            static_cast<unsigned long long>(kInitialEventSamples),
            static_cast<unsigned long long>(kPeriodicEventSampleInterval));
        WriteLogLineLocked(line);
        WritePreArmLocked("installed", qpc);
        FlushFileBuffers(s_Log);
    }

    // Called by the sole SetVertexShader hook owner only after the underlying
    // D3D9 call succeeds. Zero diagnostic identity fields are allowed before
    // CameraDiagnostics arms; this observer resolves the bounded 880-byte
    // candidate itself without emitting into the camera capture stream.
    static void AfterSetVertexShader(
        IDirect3DDevice9* device,
        IDirect3DVertexShader9* shader,
        uint32_t hash,
        uint32_t byteCount,
        uint32_t versionToken)
    {
        ExclusiveStateLock lock;
        if (!s_Active || device != s_Device ||
            (s_Armed && s_FrameNumber >= kFrameLimit))
            return;

        s_ObservedShaderPointer = shader;
        s_ObservedShader = {};
        s_ObservedShaderIsTarget = ResolveShaderIdentity(
            shader, hash, byteCount, versionToken, s_ObservedShader) &&
            IsTargetShader(s_ObservedShader);
        if (s_ObservedShaderIsTarget)
        {
            ++s_TargetShaderSelections;
            if (!s_Armed)
            {
                LARGE_INTEGER armQpc = {};
                if (!s_PreArmClockReady || !TryReadQpc(armQpc))
                {
                    FailPreArmLocked("qpc-unavailable", armQpc);
                    return;
                }
                if (armQpc.QuadPart >= s_PreArmDeadlineQpc.QuadPart)
                {
                    FailPreArmLocked("qpc-deadline-expired", armQpc);
                    return;
                }

                // The bounded experiment begins at the first exact target
                // selection before the wall-clock deadline, so frontend and
                // loading EndScene calls cannot consume its 300 gameplay frames.
                s_Armed = true;
                s_FrameNumber = 0;
                WriteArmLocked(armQpc);
                FlushFileBuffers(s_Log);
            }
        }
    }

    // Called immediately before either original draw function. It never owns
    // or invokes the draw itself, and it cannot mutate shader constants.
    static void BeforeDraw(IDirect3DDevice9* device, SetTransformFn originalSetTransform)
    {
        ExclusiveStateLock lock;
        if (!s_Active || !s_Armed || s_FrameNumber >= kFrameLimit || device != s_Device ||
            !s_ObservedShaderIsTarget)
        {
            return;
        }

        ++s_CandidateDraws;
        HRESULT getVertexShaderResult = E_POINTER;
        HRESULT getWorldResult = E_POINTER;
        HRESULT getViewResult = E_POINTER;
        HRESULT getProjectionResult = E_POINTER;
        HRESULT getConstantsResult = E_POINTER;
        ShaderIdentity actualIdentity;
        bool pointerMatched = false;

        IDirect3DVertexShader9* currentShader = nullptr;
        getVertexShaderResult = device->GetVertexShader(&currentShader);
        if (SUCCEEDED(getVertexShaderResult) && currentShader)
        {
            pointerMatched = currentShader == s_ObservedShaderPointer;
            ResolveShaderIdentity(currentShader, 0, 0, 0, actualIdentity);
            currentShader->Release();
        }

        if (!originalSetTransform || FAILED(getVertexShaderResult) ||
            !pointerMatched || !IsTargetShader(actualIdentity))
        {
            ++s_ShaderStateDivergences;
            if (ShouldRecordOccurrenceLocked(s_ShaderStateDivergences))
            {
                LogQueryFailureLocked(
                    getVertexShaderResult,
                    getWorldResult,
                    getViewResult,
                    getProjectionResult,
                    getConstantsResult,
                    actualIdentity,
                    pointerMatched);
            }
            return;
        }

        D3DMATRIX world = {};
        D3DMATRIX view = {};
        D3DMATRIX projection = {};
        D3DMATRIX constantMatrix = {};
        getWorldResult = device->GetTransform(D3DTS_WORLD, &world);
        getViewResult = device->GetTransform(D3DTS_VIEW, &view);
        getProjectionResult = device->GetTransform(D3DTS_PROJECTION, &projection);
        getConstantsResult = device->GetVertexShaderConstantF(
            kTargetConstantRegister,
            reinterpret_cast<float*>(&constantMatrix),
            kTargetConstantRegisterCount);

        if (FAILED(getWorldResult) || FAILED(getViewResult) ||
            FAILED(getProjectionResult) || FAILED(getConstantsResult))
        {
            ++s_QueryFailures;
            if (ShouldRecordOccurrenceLocked(s_QueryFailures))
            {
                LogQueryFailureLocked(
                    getVertexShaderResult,
                    getWorldResult,
                    getViewResult,
                    getProjectionResult,
                    getConstantsResult,
                    actualIdentity,
                    pointerMatched);
            }
            return;
        }

        const D3DMATRIX worldView = MultiplyMatrix(world, view);
        const D3DMATRIX worldViewProjection = MultiplyMatrix(worldView, projection);
        const D3DMATRIX expectedConstants = TransposeMatrix(worldViewProjection);
        const MatrixComparison comparison = CompareMatrices(constantMatrix, expectedConstants);
        const float nearDifference = constantMatrix.m[2][3] - constantMatrix.m[3][3];
        const bool mainNearPlane = std::isfinite(nearDifference) &&
            std::fabs(nearDifference + kMainNearPlane) <= kMainNearTolerance;

        const bool matrixMatch = comparison.finite && comparison.matches;
        if (!matrixMatch || !mainNearPlane)
        {
            ++s_NumericRejects;
            if (ShouldRecordOccurrenceLocked(s_NumericRejects))
                LogNumericRejectLocked(comparison, nearDifference, mainNearPlane);
            return;
        }

        ++s_NumericMatches;
        ++s_ReassertAttempts;
        const HRESULT setWorldResult = originalSetTransform(device, D3DTS_WORLD, &world);
        const HRESULT setViewResult = originalSetTransform(device, D3DTS_VIEW, &view);
        const HRESULT setProjectionResult = originalSetTransform(device, D3DTS_PROJECTION, &projection);
        if (SUCCEEDED(setWorldResult) && SUCCEEDED(setViewResult) && SUCCEEDED(setProjectionResult))
            ++s_ReassertSuccesses;
        else
            ++s_ReassertFailures;

        if (ShouldRecordOccurrenceLocked(s_ReassertAttempts))
        {
            LogReassertLocked(
                comparison,
                nearDifference,
                getVertexShaderResult,
                getWorldResult,
                getViewResult,
                getProjectionResult,
                getConstantsResult,
                setWorldResult,
                setViewResult,
                setProjectionResult);
        }
    }

    // Called once by the sole EndScene hook owner after its original call.
    static void OnEndScene(IDirect3DDevice9* device)
    {
        ExclusiveStateLock lock;
        if (!s_Active || device != s_Device)
            return;

        if (!s_Armed)
        {
            // Retained only as diagnostic throughput evidence. It never
            // participates in the pre-arm timeout decision.
            ++s_PreArmFrameNumber;
            LARGE_INTEGER qpc = {};
            if (!s_PreArmClockReady || !TryReadQpc(qpc))
            {
                FailPreArmLocked("qpc-unavailable", qpc);
                return;
            }
            if (qpc.QuadPart >= s_PreArmDeadlineQpc.QuadPart)
            {
                FailPreArmLocked("qpc-deadline-expired", qpc);
                return;
            }
            if (qpc.QuadPart >= s_NextPreArmProgressQpc.QuadPart)
            {
                WritePreArmLocked("waiting-for-exact-target-shader", qpc);
                AdvancePreArmProgressDeadlineLocked(qpc);
            }
            return;
        }

        ++s_FrameNumber;
        if (s_FrameNumber < kFrameLimit)
            return;

        s_Active = false;
        WriteSummaryLocked("bounded-complete", "completed");
        CloseLogLocked();
        ClearObservedShaderLocked();
    }
}

static void InstallRtxCameraReassertion(IDirect3DDevice9* device)
{
    // EchoPatch's PE timestamp is the authoritative FEAR v1.08 identity.
    // The feature is opt-in and silently fails closed for FEARMP/expansions,
    // unsupported executables, a missing user directory, or a missing device.
    if (!EnableRtxCameraReassertion || !device ||
        g_State.CurrentFEARGame != FEAR || !RtxCameraReassertion::IsExactFear108Executable())
    {
        return;
    }
    RtxCameraReassertion::Install(device);
}
