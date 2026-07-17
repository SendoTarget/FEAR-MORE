#pragma once

#include "../../Globals.cpp"
#include "../../helper.cpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace CameraDiagnostics
{
    using SetRenderTargetFn = HRESULT(WINAPI*)(IDirect3DDevice9*, DWORD, IDirect3DSurface9*);
    using EndSceneFn = HRESULT(WINAPI*)(IDirect3DDevice9*);
    using SetTransformFn = HRESULT(WINAPI*)(IDirect3DDevice9*, D3DTRANSFORMSTATETYPE, const D3DMATRIX*);
    using SetViewportFn = HRESULT(WINAPI*)(IDirect3DDevice9*, const D3DVIEWPORT9*);
    using DrawPrimitiveFn = HRESULT(WINAPI*)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, UINT);
    using DrawIndexedPrimitiveFn = HRESULT(WINAPI*)(IDirect3DDevice9*, D3DPRIMITIVETYPE, INT, UINT, UINT, UINT, UINT);
    using SetVertexShaderFn = HRESULT(WINAPI*)(IDirect3DDevice9*, IDirect3DVertexShader9*);
    using SetVertexShaderConstantFFn = HRESULT(WINAPI*)(IDirect3DDevice9*, UINT, const float*, UINT);

    static constexpr uint32_t kSchema = 1;
    static constexpr uint64_t kFrameLimit = 3600;
    static constexpr uint32_t kShaderLimit = 128;
    static constexpr uint32_t kConstantRecordLimit = 8192;
    static constexpr uint32_t kTransformRecordLimit = 256;
    static constexpr uint32_t kConstantShapeCapacity = 2048;
    static constexpr uint32_t kShapeBurstSampleLimit = 8;
    static constexpr uint32_t kShapeSampleLimit = 32;
    static constexpr uint64_t kShapeSampleIntervalFrames = 150;
    static constexpr uint32_t kMaximumShaderBytes = 1024 * 1024;
    static constexpr uint32_t kMaximumShaderDumpBytes = 16 * 1024 * 1024;
    static constexpr uint32_t kMaximumConstantPayloadBytes = 32 * 1024 * 1024;
    static constexpr uint32_t kLoggedConstantFloatLimit = 16;
    static constexpr char kCapabilityProof[] = "FearMoreDiagnostics\\camera-d3d9-";
    static constexpr char kArmingPolicy[] = "same-pid-source-camera-log-at-end-scene";

    struct ShaderIdentity
    {
        uint32_t hash = 0;
        uint32_t byteCount = 0;
        uint32_t versionToken = 0;
        bool bytecodeKnown = false;
    };

    struct ShaderCacheEntry
    {
        IDirect3DVertexShader9* pointer = nullptr;
        ShaderIdentity identity;
    };

    struct ConstantShape
    {
        bool occupied = false;
        bool shaderPresent = false;
        ShaderIdentity shader;
        UINT startRegister = 0;
        UINT vector4Count = 0;
        uint32_t samples = 0;
        uint64_t lastSampleFrame = 0;
        uint32_t lastValueHash = 0;
        bool hasLastValueHash = false;
    };

    struct FrameState
    {
        uint64_t frameNumber = 0;
        uint32_t shaderDrawCalls = 0;
        uint32_t fixedFunctionDrawCalls = 0;
        uint64_t primitives = 0;
        uint32_t setVertexShaderCalls = 0;
        uint32_t constantWrites = 0;
        uint32_t setTransformCalls = 0;
        uint32_t worldTransformCalls = 0;
        uint32_t viewTransformCalls = 0;
        uint32_t projectionTransformCalls = 0;
        uint32_t setViewportCalls = 0;
        uint32_t setRenderTargetCalls = 0;
    };

    static SetRenderTargetFn s_SetRenderTarget = nullptr;
    static EndSceneFn s_EndScene = nullptr;
    static SetTransformFn s_SetTransform = nullptr;
    static SetViewportFn s_SetViewport = nullptr;
    static DrawPrimitiveFn s_DrawPrimitive = nullptr;
    static DrawIndexedPrimitiveFn s_DrawIndexedPrimitive = nullptr;
    static SetVertexShaderFn s_SetVertexShader = nullptr;
    static SetVertexShaderConstantFFn s_SetVertexShaderConstantF = nullptr;

    static void* s_SetRenderTargetAddress = nullptr;
    static void* s_EndSceneAddress = nullptr;
    static void* s_SetTransformAddress = nullptr;
    static void* s_SetViewportAddress = nullptr;
    static void* s_DrawPrimitiveAddress = nullptr;
    static void* s_DrawIndexedPrimitiveAddress = nullptr;
    static void* s_SetVertexShaderAddress = nullptr;
    static void* s_SetVertexShaderConstantFAddress = nullptr;

    static SRWLOCK s_StateLock = SRWLOCK_INIT;
    static HANDLE s_Log = INVALID_HANDLE_VALUE;
    static HANDLE s_ConstantPayloads = INVALID_HANDLE_VALUE;
    static std::wstring s_DiagnosticsDirectory;
    static std::wstring s_ShaderDirectory;
    static std::wstring s_SourceCameraLogPath;
    static LARGE_INTEGER s_QpcFrequency = {};
    static FILETIME s_ProcessStartTime = {};
    static DWORD s_ProcessId = 0;
    static FrameState s_Frame;
    static std::array<ShaderCacheEntry, kShaderLimit> s_ShaderCache = {};
    static uint32_t s_ShaderCount = 0;
    static uint32_t s_ShaderDumpBytes = 0;
    static uint32_t s_ConstantPayloadBytes = 0;
    static std::array<ConstantShape, kConstantShapeCapacity> s_ConstantShapes = {};
    static uint32_t s_ConstantRecords = 0;
    static uint32_t s_TransformRecords = 0;
    static bool s_CurrentShaderPresent = false;
    static ShaderIdentity s_CurrentShader;
    static D3DVIEWPORT9 s_Viewport = {};
    static bool s_HaveViewport = false;
    static UINT s_RenderTargetWidth = 0;
    static UINT s_RenderTargetHeight = 0;
    static D3DFORMAT s_RenderTargetFormat = D3DFMT_UNKNOWN;
    static bool s_HaveRenderTarget = false;
    static bool s_HaveProcessStartTime = false;
    static bool s_CaptureArmed = false;

    class ExclusiveStateLock
    {
    public:
        ExclusiveStateLock() { AcquireSRWLockExclusive(&s_StateLock); }
        ~ExclusiveStateLock() { ReleaseSRWLockExclusive(&s_StateLock); }
        ExclusiveStateLock(const ExclusiveStateLock&) = delete;
        ExclusiveStateLock& operator=(const ExclusiveStateLock&) = delete;
    };

    static LARGE_INTEGER ReadQpc()
    {
        LARGE_INTEGER value = {};
        QueryPerformanceCounter(&value);
        return value;
    }

    static uint32_t HashBytes(const void* data, size_t byteCount)
    {
        const uint8_t* bytes = static_cast<const uint8_t*>(data);
        uint32_t hash = 2166136261u;
        for (size_t index = 0; index < byteCount; ++index)
        {
            hash ^= static_cast<uint32_t>(bytes[index]);
            hash *= 16777619u;
        }
        return hash;
    }

    static void WriteLogLine(const char* line)
    {
        if (s_Log == INVALID_HANDLE_VALUE || !line)
            return;

        DWORD bytesWritten = 0;
        const DWORD byteCount = static_cast<DWORD>(strlen(line));
        WriteFile(s_Log, line, byteCount, &bytesWritten, nullptr);
        static constexpr char newline[] = "\r\n";
        WriteFile(s_Log, newline, static_cast<DWORD>(sizeof(newline) - 1), &bytesWritten, nullptr);
    }

    static void FormatJsonFloat(float value, char* buffer, size_t bufferSize)
    {
        if (!buffer || bufferSize == 0)
            return;
        if (!std::isfinite(value))
        {
            strcpy_s(buffer, bufferSize, "null");
            return;
        }
        sprintf_s(buffer, bufferSize, "%.9g", value);
    }

    static bool IsDirectoryWithoutReparsePoint(const std::wstring& path)
    {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        return attributes != INVALID_FILE_ATTRIBUTES &&
            (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
            (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
    }

    static bool IsCaptureActiveLocked()
    {
        return s_CaptureArmed && s_Frame.frameNumber < kFrameLimit;
    }

    static bool SourceCameraLogIsReady()
    {
        WIN32_FILE_ATTRIBUTE_DATA attributes = {};
        if (s_SourceCameraLogPath.empty() ||
            !GetFileAttributesExW(s_SourceCameraLogPath.c_str(), GetFileExInfoStandard, &attributes))
        {
            return false;
        }
        if ((attributes.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)
            return false;

        // Diagnostic directories intentionally survive safe stage reruns. A
        // reused PID must not let a stale source-camera file arm a new process.
        return !s_HaveProcessStartTime || CompareFileTime(&attributes.ftLastWriteTime, &s_ProcessStartTime) >= 0;
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
            if (GetFullPathNameW(selected.c_str(), static_cast<DWORD>(fullPath.size()), fullPath.data(), nullptr) == 0)
                return false;
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

    static bool OpenLog()
    {
        if (s_Log != INVALID_HANDLE_VALUE)
            return true;

        std::wstring userDirectory;
        if (!GetUserDirectory(userDirectory))
            return false;

        s_ProcessId = GetCurrentProcessId();
        FILETIME exitTime = {};
        FILETIME kernelTime = {};
        FILETIME userTime = {};
        s_HaveProcessStartTime = GetProcessTimes(
            GetCurrentProcess(), &s_ProcessStartTime, &exitTime, &kernelTime, &userTime) != FALSE;

        s_DiagnosticsDirectory = userDirectory + L"\\FearMoreDiagnostics";
        if (!CreateDirectoryW(s_DiagnosticsDirectory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS)
            return false;
        if (!IsDirectoryWithoutReparsePoint(s_DiagnosticsDirectory))
            return false;

        s_ShaderDirectory = s_DiagnosticsDirectory + L"\\shaders";
        wchar_t fileName[96] = {};
        swprintf_s(fileName, L"camera-source-%lu.jsonl", s_ProcessId);
        s_SourceCameraLogPath = s_DiagnosticsDirectory + L"\\" + fileName;

        swprintf_s(fileName, L"camera-d3d9-%lu.jsonl", s_ProcessId);
        const std::wstring logPath = s_DiagnosticsDirectory + L"\\" + fileName;
        s_Log = CreateFileW(logPath.c_str(), GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (s_Log == INVALID_HANDLE_VALUE)
            return false;

        swprintf_s(fileName, L"camera-d3d9-%lu.constants.f32bin", s_ProcessId);
        const std::wstring constantPayloadPath = s_DiagnosticsDirectory + L"\\" + fileName;
        s_ConstantPayloads = CreateFileW(constantPayloadPath.c_str(), GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_DELETE,
            nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (s_ConstantPayloads == INVALID_HANDLE_VALUE)
        {
            CloseHandle(s_Log);
            s_Log = INVALID_HANDLE_VALUE;
            DeleteFileW(logPath.c_str());
            return false;
        }

        QueryPerformanceFrequency(&s_QpcFrequency);
        return true;
    }

    static bool WriteShaderBytecode(const ShaderIdentity& identity, const std::vector<uint8_t>& bytecode,
        bool& alreadyPresent, std::wstring& leafName)
    {
        alreadyPresent = false;
        leafName.clear();
        if (!identity.bytecodeKnown || bytecode.empty() ||
            bytecode.size() > kMaximumShaderBytes ||
            s_ShaderDumpBytes + bytecode.size() > kMaximumShaderDumpBytes)
        {
            return false;
        }

        if (!CreateDirectoryW(s_ShaderDirectory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS)
            return false;
        if (!IsDirectoryWithoutReparsePoint(s_ShaderDirectory))
            return false;

        wchar_t fileName[96] = {};
        swprintf_s(fileName, L"vs-%08X-%u.dxso", identity.hash, identity.byteCount);
        leafName.assign(fileName);
        const std::wstring path = s_ShaderDirectory + L"\\" + leafName;
        HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
            nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
        {
            alreadyPresent = GetLastError() == ERROR_FILE_EXISTS;
            return alreadyPresent;
        }

        DWORD bytesWritten = 0;
        const BOOL wrote = WriteFile(file, bytecode.data(), static_cast<DWORD>(bytecode.size()), &bytesWritten, nullptr);
        CloseHandle(file);
        if (!wrote || bytesWritten != bytecode.size())
        {
            DeleteFileW(path.c_str());
            return false;
        }
        s_ShaderDumpBytes += bytesWritten;
        return true;
    }

    static bool WriteConstantPayload(const float* constantData, UINT vector4Count, uint32_t& payloadOffset,
        uint32_t& payloadBytes)
    {
        payloadOffset = s_ConstantPayloadBytes;
        payloadBytes = 0;
        if (s_ConstantPayloads == INVALID_HANDLE_VALUE || !constantData || vector4Count == 0 || vector4Count > 256)
            return false;

        const uint32_t byteCount = vector4Count * 4u * static_cast<uint32_t>(sizeof(float));
        if (byteCount > kMaximumConstantPayloadBytes - s_ConstantPayloadBytes)
            return false;

        DWORD bytesWritten = 0;
        const BOOL wrote = WriteFile(s_ConstantPayloads, constantData, byteCount, &bytesWritten, nullptr);
        s_ConstantPayloadBytes += bytesWritten;
        if (!wrote || bytesWritten != byteCount)
        {
            CloseHandle(s_ConstantPayloads);
            s_ConstantPayloads = INVALID_HANDLE_VALUE;
            return false;
        }

        payloadBytes = byteCount;
        return true;
    }

    static ShaderIdentity ObserveShader(IDirect3DVertexShader9* shader)
    {
        if (!shader)
            return {};

        for (uint32_t index = 0; index < s_ShaderCount; ++index)
        {
            if (s_ShaderCache[index].pointer == shader)
                return s_ShaderCache[index].identity;
        }

        // Once the unique-shader budget is exhausted, do not turn recurring
        // SetVertexShader calls into unbounded bytecode queries.
        if (s_ShaderCount >= kShaderLimit)
            return {};

        ShaderIdentity identity;
        std::vector<uint8_t> bytecode;
        UINT byteCount = 0;
        if (SUCCEEDED(shader->GetFunction(nullptr, &byteCount)) &&
            byteCount >= sizeof(uint32_t) && byteCount <= kMaximumShaderBytes)
        {
            bytecode.resize(byteCount);
            UINT returnedByteCount = byteCount;
            if (SUCCEEDED(shader->GetFunction(bytecode.data(), &returnedByteCount)) && returnedByteCount == byteCount)
            {
                identity.byteCount = byteCount;
                memcpy(&identity.versionToken, bytecode.data(), sizeof(identity.versionToken));
                identity.hash = HashBytes(bytecode.data(), bytecode.size());
                identity.bytecodeKnown = true;
            }
            else
            {
                bytecode.clear();
            }
        }

        // Retain the observed COM object for the bounded capture so Direct3D
        // cannot destroy it and recycle the pointer for a different shader.
        shader->AddRef();
        s_ShaderCache[s_ShaderCount].pointer = shader;
        s_ShaderCache[s_ShaderCount].identity = identity;
        ++s_ShaderCount;

        bool alreadyPresent = false;
        std::wstring dumpLeafName;
        const bool dumpAvailable = WriteShaderBytecode(identity, bytecode, alreadyPresent, dumpLeafName);
        const LARGE_INTEGER qpc = ReadQpc();
        char dumpLeafNameUtf8[192] = {};
        if (!dumpLeafName.empty())
            WideCharToMultiByte(CP_UTF8, 0, dumpLeafName.c_str(), -1, dumpLeafNameUtf8, sizeof(dumpLeafNameUtf8), nullptr, nullptr);
        char line[1024] = {};
        sprintf_s(line,
            "{\"event\":\"vertex-shader\",\"schema\":%u,\"capability\":\"camera-d3d9-setter-capture-v1\","
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"frame\":%llu,"
            "\"hashAlgorithm\":\"fnv1a32-unsigned-byte\",\"hash\":\"%08X\",\"bytes\":%u,\"version\":\"%08X\","
            "\"bytecodeKnown\":%s,\"dumpAvailable\":%s,\"dumpAlreadyPresent\":%s,\"dump\":\"shaders/%s\"}",
            kSchema, s_ProcessId, static_cast<long long>(qpc.QuadPart), static_cast<long long>(s_QpcFrequency.QuadPart),
            static_cast<unsigned long long>(s_Frame.frameNumber), identity.hash, identity.byteCount, identity.versionToken,
            identity.bytecodeKnown ? "true" : "false", dumpAvailable ? "true" : "false",
            alreadyPresent ? "true" : "false", dumpLeafNameUtf8);
        WriteLogLine(line);
        return identity;
    }

    static uint32_t GetShapeBucket(const ShaderIdentity& shader, bool shaderPresent, UINT startRegister, UINT vector4Count)
    {
        uint32_t hash = shaderPresent ? shader.hash : 0x9E3779B9u;
        hash ^= shader.byteCount + 0x9E3779B9u + (hash << 6) + (hash >> 2);
        hash ^= startRegister + 0x9E3779B9u + (hash << 6) + (hash >> 2);
        hash ^= vector4Count + 0x9E3779B9u + (hash << 6) + (hash >> 2);
        return hash % kConstantShapeCapacity;
    }

    static ConstantShape* FindOrCreateConstantShape(bool shaderPresent, const ShaderIdentity& shader,
        UINT startRegister, UINT vector4Count)
    {
        const uint32_t initialBucket = GetShapeBucket(shader, shaderPresent, startRegister, vector4Count);
        for (uint32_t probe = 0; probe < kConstantShapeCapacity; ++probe)
        {
            ConstantShape& shape = s_ConstantShapes[(initialBucket + probe) % kConstantShapeCapacity];
            if (!shape.occupied)
            {
                shape.occupied = true;
                shape.shaderPresent = shaderPresent;
                shape.shader = shader;
                shape.startRegister = startRegister;
                shape.vector4Count = vector4Count;
                return &shape;
            }
            if (shape.shaderPresent == shaderPresent && shape.shader.hash == shader.hash &&
                shape.shader.byteCount == shader.byteCount && shape.startRegister == startRegister &&
                shape.vector4Count == vector4Count)
            {
                return &shape;
            }
        }
        return nullptr;
    }

    static bool ShouldSampleShape(ConstantShape& shape, uint32_t valueHash)
    {
        if (shape.samples >= kShapeSampleLimit || s_ConstantRecords >= kConstantRecordLimit)
            return false;
        if (shape.hasLastValueHash && shape.lastValueHash == valueHash)
            return false;
        if (shape.samples >= kShapeBurstSampleLimit &&
            s_Frame.frameNumber < shape.lastSampleFrame + kShapeSampleIntervalFrames)
            return false;
        shape.lastSampleFrame = s_Frame.frameNumber;
        shape.lastValueHash = valueHash;
        shape.hasLastValueHash = true;
        ++shape.samples;
        ++s_ConstantRecords;
        return true;
    }

    static void LogConstantWrite(UINT startRegister, const float* constantData, UINT vector4Count)
    {
        if (!constantData || vector4Count == 0 || vector4Count > 256)
            return;

        const size_t totalFloatCount = static_cast<size_t>(vector4Count) * 4;
        const size_t loggedFloatCount = std::min<size_t>(totalFloatCount, kLoggedConstantFloatLimit);
        const uint32_t valueHash = HashBytes(constantData, totalFloatCount * sizeof(float));
        ConstantShape* shape = FindOrCreateConstantShape(
            s_CurrentShaderPresent, s_CurrentShader, startRegister, vector4Count);
        if (!shape || !ShouldSampleShape(*shape, valueHash))
            return;

        uint32_t payloadOffset = 0;
        uint32_t payloadBytes = 0;
        const bool payloadAvailable = WriteConstantPayload(constantData, vector4Count, payloadOffset, payloadBytes);
        std::string values;
        values.reserve(loggedFloatCount * 24);
        for (size_t index = 0; index < loggedFloatCount; ++index)
        {
            char formatted[32] = {};
            FormatJsonFloat(constantData[index], formatted, sizeof(formatted));
            if (!values.empty())
                values.push_back(',');
            values += formatted;
        }

        const LARGE_INTEGER qpc = ReadQpc();
        char line[2048] = {};
        sprintf_s(line,
            "{\"event\":\"constant-write\",\"schema\":%u,\"capability\":\"camera-d3d9-setter-capture-v1\","
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"frame\":%llu,"
            "\"shaderPresent\":%s,\"shaderHash\":\"%08X\",\"shaderBytes\":%u,"
            "\"startRegister\":%u,\"endRegisterExclusive\":%u,\"vector4Count\":%u,"
            "\"valueCount\":%llu,\"valueHash\":\"%08X\","
            "\"payloadAvailable\":%s,\"payloadOffset\":%u,\"payloadBytes\":%u,"
            "\"payloadEncoding\":\"ieee754-f32le\","
            "\"loggedValueCount\":%llu,\"valuesTruncated\":%s,\"values\":[%s],\"shapeSample\":%u}",
            kSchema, s_ProcessId, static_cast<long long>(qpc.QuadPart), static_cast<long long>(s_QpcFrequency.QuadPart),
            static_cast<unsigned long long>(s_Frame.frameNumber), s_CurrentShaderPresent ? "true" : "false",
            s_CurrentShader.hash, s_CurrentShader.byteCount, startRegister, startRegister + vector4Count, vector4Count,
            static_cast<unsigned long long>(totalFloatCount), valueHash,
            payloadAvailable ? "true" : "false", payloadOffset, payloadBytes,
            static_cast<unsigned long long>(loggedFloatCount), totalFloatCount > loggedFloatCount ? "true" : "false",
            values.c_str(), shape->samples);
        WriteLogLine(line);
    }

    static void LogTransformWrite(D3DTRANSFORMSTATETYPE state, const D3DMATRIX& matrix)
    {
        if (s_TransformRecords >= kTransformRecordLimit)
            return;

        const bool commonState = state == D3DTS_WORLD || state == D3DTS_VIEW || state == D3DTS_PROJECTION;
        if (!commonState)
            return;

        // Fixed-function world transforms may update per draw. Sample each
        // state at a bounded cadence rather than turning the setter into an
        // unbounded trace.
        static constexpr uint64_t neverSampled = static_cast<uint64_t>(-1);
        static uint64_t lastSampleFrame[3] = { neverSampled, neverSampled, neverSampled };
        static uint32_t samples[3] = {};
        const uint32_t index = state == D3DTS_WORLD ? 0u : (state == D3DTS_VIEW ? 1u : 2u);
        if (samples[index] >= kShapeSampleLimit)
            return;
        if (lastSampleFrame[index] != neverSampled &&
            s_Frame.frameNumber < lastSampleFrame[index] + kShapeSampleIntervalFrames)
        {
            return;
        }
        lastSampleFrame[index] = s_Frame.frameNumber;
        ++samples[index];
        ++s_TransformRecords;

        const float* values = reinterpret_cast<const float*>(&matrix);
        std::string valueJson;
        valueJson.reserve(384);
        for (size_t valueIndex = 0; valueIndex < 16; ++valueIndex)
        {
            char formatted[32] = {};
            FormatJsonFloat(values[valueIndex], formatted, sizeof(formatted));
            if (!valueJson.empty())
                valueJson.push_back(',');
            valueJson += formatted;
        }
        const char* stateName = state == D3DTS_WORLD ? "world" : (state == D3DTS_VIEW ? "view" : "projection");
        const LARGE_INTEGER qpc = ReadQpc();
        char line[1536] = {};
        sprintf_s(line,
            "{\"event\":\"transform-write\",\"schema\":%u,\"capability\":\"camera-d3d9-setter-capture-v1\","
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"frame\":%llu,"
            "\"state\":\"%s\",\"values\":[%s],\"sample\":%u}",
            kSchema, s_ProcessId, static_cast<long long>(qpc.QuadPart), static_cast<long long>(s_QpcFrequency.QuadPart),
            static_cast<unsigned long long>(s_Frame.frameNumber), stateName, valueJson.c_str(), samples[index]);
        WriteLogLine(line);
    }

    static void ResetFrameCounters()
    {
        const uint64_t nextFrame = s_Frame.frameNumber + 1;
        s_Frame = {};
        s_Frame.frameNumber = nextFrame;
    }

    static void ReleaseShaderCache()
    {
        for (uint32_t index = 0; index < s_ShaderCount; ++index)
        {
            if (s_ShaderCache[index].pointer)
            {
                s_ShaderCache[index].pointer->Release();
                s_ShaderCache[index].pointer = nullptr;
            }
        }
        s_CurrentShaderPresent = false;
        s_CurrentShader = {};
    }

    static void ArmCapture()
    {
        s_CaptureArmed = true;
        const LARGE_INTEGER qpc = ReadQpc();
        char line[1024] = {};
        sprintf_s(line,
            "{\"event\":\"arm\",\"schema\":%u,\"capability\":\"camera-d3d9-setter-capture-v1\","
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"frame\":%llu,"
            "\"armingPolicy\":\"%s\",\"sourceCameraLog\":\"UserDirectory/FearMoreDiagnostics/camera-source-%lu.jsonl\","
            "\"sourceLogFreshness\":\"last-write-at-or-after-process-start-when-available\","
            "\"processStartKnown\":%s,\"captureStarts\":\"next-frame\",\"firstCaptureFrame\":0}",
            kSchema, s_ProcessId, static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart),
            static_cast<unsigned long long>(s_Frame.frameNumber), kArmingPolicy, s_ProcessId,
            s_HaveProcessStartTime ? "true" : "false");
        WriteLogLine(line);
        FlushFileBuffers(s_Log);
        if (s_ConstantPayloads != INVALID_HANDLE_VALUE)
            FlushFileBuffers(s_ConstantPayloads);
    }

    static void LogFrame()
    {
        if (s_Frame.frameNumber >= kFrameLimit)
            return;

        const LARGE_INTEGER qpc = ReadQpc();
        char line[2048] = {};
        sprintf_s(line,
            "{\"event\":\"frame\",\"schema\":%u,\"capability\":\"camera-d3d9-setter-capture-v1\","
            "\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"frame\":%llu,"
            "\"draws\":{\"shader\":%u,\"fixedFunction\":%u,\"primitives\":%llu},"
            "\"setters\":{\"vertexShader\":%u,\"constants\":%u,\"transforms\":%u,\"world\":%u,\"view\":%u,\"projection\":%u,\"viewport\":%u,\"renderTarget\":%u},"
            "\"currentVertexShader\":{\"present\":%s,\"hash\":\"%08X\",\"bytes\":%u,\"version\":\"%08X\"},"
            "\"viewport\":{\"present\":%s,\"x\":%lu,\"y\":%lu,\"width\":%lu,\"height\":%lu,\"minZ\":%.9g,\"maxZ\":%.9g},"
            "\"renderTarget\":{\"present\":%s,\"width\":%u,\"height\":%u,\"format\":%d},"
            "\"records\":{\"shaders\":%u,\"constants\":%u,\"transforms\":%u,\"shaderDumpBytes\":%u,\"constantPayloadBytes\":%u}}",
            kSchema, s_ProcessId, static_cast<long long>(qpc.QuadPart), static_cast<long long>(s_QpcFrequency.QuadPart),
            static_cast<unsigned long long>(s_Frame.frameNumber), s_Frame.shaderDrawCalls, s_Frame.fixedFunctionDrawCalls,
            static_cast<unsigned long long>(s_Frame.primitives), s_Frame.setVertexShaderCalls, s_Frame.constantWrites,
            s_Frame.setTransformCalls, s_Frame.worldTransformCalls, s_Frame.viewTransformCalls,
            s_Frame.projectionTransformCalls, s_Frame.setViewportCalls, s_Frame.setRenderTargetCalls,
            s_CurrentShaderPresent ? "true" : "false", s_CurrentShader.hash, s_CurrentShader.byteCount,
            s_CurrentShader.versionToken, s_HaveViewport ? "true" : "false", s_Viewport.X, s_Viewport.Y,
            s_Viewport.Width, s_Viewport.Height, s_Viewport.MinZ, s_Viewport.MaxZ,
            s_HaveRenderTarget ? "true" : "false", s_RenderTargetWidth, s_RenderTargetHeight,
            static_cast<int>(s_RenderTargetFormat), s_ShaderCount, s_ConstantRecords, s_TransformRecords,
            s_ShaderDumpBytes, s_ConstantPayloadBytes);
        WriteLogLine(line);
        if ((s_Frame.frameNumber % 60) == 0)
        {
            FlushFileBuffers(s_Log);
            if (s_ConstantPayloads != INVALID_HANDLE_VALUE)
                FlushFileBuffers(s_ConstantPayloads);
        }
    }

    static HRESULT WINAPI SetRenderTargetHook(IDirect3DDevice9* device, DWORD index, IDirect3DSurface9* renderTarget)
    {
        const HRESULT result = s_SetRenderTarget(device, index, renderTarget);
        if (SUCCEEDED(result) && index == 0)
        {
            ExclusiveStateLock lock;
            if (!IsCaptureActiveLocked())
                return result;

            D3DSURFACE_DESC description = {};
            const bool haveDescription = renderTarget && SUCCEEDED(renderTarget->GetDesc(&description));
            ++s_Frame.setRenderTargetCalls;
            s_HaveRenderTarget = haveDescription;
            s_RenderTargetWidth = haveDescription ? description.Width : 0;
            s_RenderTargetHeight = haveDescription ? description.Height : 0;
            s_RenderTargetFormat = haveDescription ? description.Format : D3DFMT_UNKNOWN;
        }
        return result;
    }

    static HRESULT WINAPI EndSceneHook(IDirect3DDevice9* device)
    {
        const HRESULT result = s_EndScene(device);
        ExclusiveStateLock lock;
        if (!s_CaptureArmed)
        {
            // This is the only filesystem readiness check after installation.
            // The arm transition happens after this EndScene, so the first
            // captured setters and draws belong to the following frame.
            if (SourceCameraLogIsReady())
                ArmCapture();
            return result;
        }
        if (!IsCaptureActiveLocked())
            return result;

        LogFrame();
        ResetFrameCounters();
        if (s_Frame.frameNumber == kFrameLimit)
        {
            FlushFileBuffers(s_Log);
            if (s_ConstantPayloads != INVALID_HANDLE_VALUE)
                FlushFileBuffers(s_ConstantPayloads);
            ReleaseShaderCache();
        }
        return result;
    }

    static HRESULT WINAPI SetTransformHook(IDirect3DDevice9* device, D3DTRANSFORMSTATETYPE state, const D3DMATRIX* matrix)
    {
        const HRESULT result = s_SetTransform(device, state, matrix);
        if (SUCCEEDED(result) && matrix)
        {
            ExclusiveStateLock lock;
            if (!IsCaptureActiveLocked())
                return result;

            ++s_Frame.setTransformCalls;
            if (state == D3DTS_WORLD)
                ++s_Frame.worldTransformCalls;
            else if (state == D3DTS_VIEW)
                ++s_Frame.viewTransformCalls;
            else if (state == D3DTS_PROJECTION)
                ++s_Frame.projectionTransformCalls;
            LogTransformWrite(state, *matrix);
        }
        return result;
    }

    static HRESULT WINAPI SetViewportHook(IDirect3DDevice9* device, const D3DVIEWPORT9* viewport)
    {
        const HRESULT result = s_SetViewport(device, viewport);
        if (SUCCEEDED(result) && viewport)
        {
            ExclusiveStateLock lock;
            if (!IsCaptureActiveLocked())
                return result;

            s_Viewport = *viewport;
            s_HaveViewport = true;
            ++s_Frame.setViewportCalls;
        }
        return result;
    }

    static void CountDraw(UINT primitiveCount)
    {
        ExclusiveStateLock lock;
        if (!IsCaptureActiveLocked())
            return;
        if (s_CurrentShaderPresent)
            ++s_Frame.shaderDrawCalls;
        else
            ++s_Frame.fixedFunctionDrawCalls;
        s_Frame.primitives += primitiveCount;
    }

    static HRESULT WINAPI DrawPrimitiveHook(IDirect3DDevice9* device, D3DPRIMITIVETYPE primitiveType,
        UINT startVertex, UINT primitiveCount)
    {
        const HRESULT result = s_DrawPrimitive(device, primitiveType, startVertex, primitiveCount);
        if (SUCCEEDED(result))
            CountDraw(primitiveCount);
        return result;
    }

    static HRESULT WINAPI DrawIndexedPrimitiveHook(IDirect3DDevice9* device, D3DPRIMITIVETYPE primitiveType,
        INT baseVertexIndex, UINT minimumVertexIndex, UINT numberOfVertices, UINT startIndex, UINT primitiveCount)
    {
        const HRESULT result = s_DrawIndexedPrimitive(device, primitiveType, baseVertexIndex,
            minimumVertexIndex, numberOfVertices, startIndex, primitiveCount);
        if (SUCCEEDED(result))
            CountDraw(primitiveCount);
        return result;
    }

    static HRESULT WINAPI SetVertexShaderHook(IDirect3DDevice9* device, IDirect3DVertexShader9* shader)
    {
        const HRESULT result = s_SetVertexShader(device, shader);
        if (SUCCEEDED(result))
        {
            ExclusiveStateLock lock;
            if (!IsCaptureActiveLocked())
                return result;

            s_CurrentShaderPresent = shader != nullptr;
            s_CurrentShader = ObserveShader(shader);
            ++s_Frame.setVertexShaderCalls;
        }
        return result;
    }

    static HRESULT WINAPI SetVertexShaderConstantFHook(IDirect3DDevice9* device, UINT startRegister,
        const float* constantData, UINT vector4Count)
    {
        const HRESULT result = s_SetVertexShaderConstantF(device, startRegister, constantData, vector4Count);
        if (SUCCEEDED(result) && constantData && vector4Count > 0)
        {
            ExclusiveStateLock lock;
            if (!IsCaptureActiveLocked())
                return result;

            ++s_Frame.constantWrites;
            LogConstantWrite(startRegister, constantData, vector4Count);
        }
        return result;
    }

    template <typename TFunction>
    static bool InstallHook(void* address, void*& installedAddress, LPVOID hook, TFunction& original)
    {
        if (installedAddress == address && original)
            return true;
        if (installedAddress)
        {
            MH_RemoveHook(installedAddress);
            installedAddress = nullptr;
            original = nullptr;
        }
        if (!HookHelper::ApplyHook(address, hook, reinterpret_cast<LPVOID*>(&original)))
            return false;
        installedAddress = address;
        return true;
    }

    static void Install(IDirect3DDevice9* device)
    {
        if (!EnableCameraDiagnostics || !device)
            return;

        ExclusiveStateLock lock;
        if (!OpenLog())
            return;

        // Keep a stable narrow proof string in the binary for package
        // verification. The JSON record below uses an escaped representation.
        OutputDebugStringA(kCapabilityProof);

        void** vtable = *reinterpret_cast<void***>(device);
        const bool renderTargetHook = InstallHook(vtable[37], s_SetRenderTargetAddress,
            reinterpret_cast<LPVOID>(&SetRenderTargetHook), s_SetRenderTarget);
        const bool endSceneHook = InstallHook(vtable[42], s_EndSceneAddress,
            reinterpret_cast<LPVOID>(&EndSceneHook), s_EndScene);
        const bool transformHook = InstallHook(vtable[44], s_SetTransformAddress,
            reinterpret_cast<LPVOID>(&SetTransformHook), s_SetTransform);
        const bool viewportHook = InstallHook(vtable[47], s_SetViewportAddress,
            reinterpret_cast<LPVOID>(&SetViewportHook), s_SetViewport);
        const bool drawPrimitiveHook = InstallHook(vtable[81], s_DrawPrimitiveAddress,
            reinterpret_cast<LPVOID>(&DrawPrimitiveHook), s_DrawPrimitive);
        const bool drawIndexedHook = InstallHook(vtable[82], s_DrawIndexedPrimitiveAddress,
            reinterpret_cast<LPVOID>(&DrawIndexedPrimitiveHook), s_DrawIndexedPrimitive);
        const bool vertexShaderHook = InstallHook(vtable[92], s_SetVertexShaderAddress,
            reinterpret_cast<LPVOID>(&SetVertexShaderHook), s_SetVertexShader);
        const bool constantHook = InstallHook(vtable[94], s_SetVertexShaderConstantFAddress,
            reinterpret_cast<LPVOID>(&SetVertexShaderConstantFHook), s_SetVertexShaderConstantF);

        const LARGE_INTEGER qpc = ReadQpc();
        char line[2048] = {};
        sprintf_s(line,
            "{\"event\":\"capability\",\"schema\":%u,\"capability\":\"camera-d3d9-setter-capture-v1\","
            "\"proof\":\"FearMoreDiagnostics\\\\camera-d3d9-\",\"pid\":%lu,\"qpc\":%lld,\"qpcFrequency\":%lld,\"frame\":%llu,\"enabled\":true,"
            "\"hooks\":{\"setRenderTarget\":%s,\"endScene\":%s,\"setTransform\":%s,\"setViewport\":%s,"
            "\"drawPrimitive\":%s,\"drawIndexedPrimitive\":%s,\"setVertexShader\":%s,\"setVertexShaderConstantF\":%s},"
            "\"boundedFrames\":%llu,\"boundedShaderRecords\":%u,\"boundedConstantRecords\":%u,"
            "\"boundedTransformRecords\":%u,\"boundedShaderDumpBytes\":%u,\"boundedConstantPayloadBytes\":%u,"
            "\"shapeBurstSampleLimit\":%u,\"shapeSampleLimit\":%u,\"shapeSampleIntervalFrames\":%llu,"
            "\"hashAlgorithm\":\"fnv1a32-unsigned-byte\",\"constantPayloadEncoding\":\"ieee754-f32le\","
            "\"perDrawDeviceQueries\":false,\"stateBlockResync\":false,\"registerAssumptions\":false,"
            "\"mirrorsState\":false,\"shaderPointerLifetime\":\"addref-until-capture-bound\",\"armed\":false,"
            "\"armingPolicy\":\"%s\",\"armCheckScope\":\"end-scene-only-until-armed\","
            "\"sourceCameraLog\":\"UserDirectory/FearMoreDiagnostics/camera-source-<pid>.jsonl\","
            "\"sourceLogFreshness\":\"last-write-at-or-after-process-start-when-available\",\"captureStarts\":\"next-frame\","
            "\"log\":\"UserDirectory/FearMoreDiagnostics/camera-d3d9-<pid>.jsonl\","
            "\"constantPayloads\":\"UserDirectory/FearMoreDiagnostics/camera-d3d9-<pid>.constants.f32bin\"}",
            kSchema, s_ProcessId, static_cast<long long>(qpc.QuadPart),
            static_cast<long long>(s_QpcFrequency.QuadPart), static_cast<unsigned long long>(s_Frame.frameNumber),
            renderTargetHook ? "true" : "false", endSceneHook ? "true" : "false",
            transformHook ? "true" : "false", viewportHook ? "true" : "false",
            drawPrimitiveHook ? "true" : "false", drawIndexedHook ? "true" : "false",
            vertexShaderHook ? "true" : "false", constantHook ? "true" : "false",
            static_cast<unsigned long long>(kFrameLimit), kShaderLimit, kConstantRecordLimit,
            kTransformRecordLimit, kMaximumShaderDumpBytes, kMaximumConstantPayloadBytes,
            kShapeBurstSampleLimit, kShapeSampleLimit,
            static_cast<unsigned long long>(kShapeSampleIntervalFrames), kArmingPolicy);
        WriteLogLine(line);
        FlushFileBuffers(s_Log);
        FlushFileBuffers(s_ConstantPayloads);
    }
}

static void InstallCameraDiagnostics(IDirect3DDevice9* device)
{
    CameraDiagnostics::Install(device);
}
