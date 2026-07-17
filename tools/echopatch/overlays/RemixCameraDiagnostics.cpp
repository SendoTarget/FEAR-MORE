#pragma once

#include "../../Globals.cpp"
#include "../../helper.cpp"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace RemixCameraDiagnostics
{
    using SetRenderTargetFn = HRESULT(WINAPI*)(IDirect3DDevice9*, DWORD, IDirect3DSurface9*);
    using EndSceneFn = HRESULT(WINAPI*)(IDirect3DDevice9*);
    using SetTransformFn = HRESULT(WINAPI*)(IDirect3DDevice9*, D3DTRANSFORMSTATETYPE, const D3DMATRIX*);
    using SetViewportFn = HRESULT(WINAPI*)(IDirect3DDevice9*, const D3DVIEWPORT9*);
    using DrawPrimitiveFn = HRESULT(WINAPI*)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, UINT);
    using DrawIndexedPrimitiveFn = HRESULT(WINAPI*)(IDirect3DDevice9*, D3DPRIMITIVETYPE, INT, UINT, UINT, UINT, UINT);
    using SetVertexShaderFn = HRESULT(WINAPI*)(IDirect3DDevice9*, IDirect3DVertexShader9*);
    using SetVertexShaderConstantFFn = HRESULT(WINAPI*)(IDirect3DDevice9*, UINT, const float*, UINT);

    struct ShaderIdentity
    {
        uint32_t hash = 0;
        uint32_t byteCount = 0;
        uint32_t versionToken = 0;
    };

    struct FrameState
    {
        uint64_t frameNumber = 0;
        uint32_t setTransformCalls = 0;
        uint32_t worldTransformCalls = 0;
        uint32_t viewTransformCalls = 0;
        uint32_t projectionTransformCalls = 0;
        uint32_t setRenderTargetCalls = 0;
        uint32_t setViewportCalls = 0;
        uint32_t shaderDrawCalls = 0;
        uint32_t fixedFunctionDrawCalls = 0;
        uint32_t fixedFunctionCameraDrawCalls = 0;
        uint64_t primitives = 0;
        uint32_t constantWrites = 0;
        uint32_t fourRegisterWrites = 0;
        uint32_t clipRegisterWrites = 0;
        uint32_t completedClipRegisterWrites = 0;
        uint32_t nonZeroClipRegisterWrites = 0;
        uint32_t clipCandidateDrawCalls = 0;
        UINT minimumConstantRegister = std::numeric_limits<UINT>::max();
        UINT maximumConstantRegister = 0;
    };

    struct DrawState
    {
        bool vertexShaderKnown = false;
        bool vertexShaderPresent = false;
        ShaderIdentity vertexShaderIdentity;
        bool worldPresent = false;
        bool viewPresent = false;
        bool projectionPresent = false;
        D3DMATRIX world = {};
        D3DMATRIX view = {};
        D3DMATRIX projection = {};
        bool clipRegistersPresent = false;
        D3DMATRIX clipRegisters = {};
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

    static HANDLE s_Log = INVALID_HANDLE_VALUE;
    static FrameState s_Frame;
    static D3DMATRIX s_World = {};
    static D3DMATRIX s_View = {};
    static D3DMATRIX s_Projection = {};
    static D3DMATRIX s_ClipRegisters = {};
    static uint8_t s_ClipRegisterRowMask = 0;
    static bool s_HaveWorld = false;
    static bool s_HaveView = false;
    static bool s_HaveProjection = false;
    static bool s_HaveClipRegisters = false;
    static D3DMATRIX s_FrameClipCandidate = {};
    static bool s_HaveFrameClipCandidate = false;
    static ShaderIdentity s_FrameClipShaderIdentity;
    static D3DMATRIX s_FrameFfpCameraView = {};
    static D3DMATRIX s_FrameFfpCameraProjection = {};
    static bool s_HaveFrameFfpCamera = false;
    static D3DVIEWPORT9 s_Viewport = {};
    static bool s_HaveViewport = false;
    static UINT s_RenderTargetWidth = 0;
    static UINT s_RenderTargetHeight = 0;
    static D3DFORMAT s_RenderTargetFormat = D3DFMT_UNKNOWN;
    static bool s_HaveVertexShader = false;
    static ShaderIdentity s_VertexShaderIdentity;

    static bool IsIdentity(const D3DMATRIX& matrix)
    {
        static const D3DMATRIX identity = {
            1.0f, 0.0f, 0.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 0.0f,
            0.0f, 0.0f, 1.0f, 0.0f,
            0.0f, 0.0f, 0.0f, 1.0f
        };
        const float* value = reinterpret_cast<const float*>(&matrix);
        const float* expected = reinterpret_cast<const float*>(&identity);
        for (size_t index = 0; index < 16; ++index)
        {
            if (!std::isfinite(value[index]) || std::fabs(value[index] - expected[index]) > 0.00001f)
                return false;
        }
        return true;
    }

    static bool IsFinite(const D3DMATRIX& matrix)
    {
        const float* value = reinterpret_cast<const float*>(&matrix);
        for (size_t index = 0; index < 16; ++index)
        {
            if (!std::isfinite(value[index]))
                return false;
        }
        return true;
    }

    static bool IsZero(const D3DMATRIX& matrix)
    {
        const float* value = reinterpret_cast<const float*>(&matrix);
        for (size_t index = 0; index < 16; ++index)
        {
            if (!std::isfinite(value[index]) || std::fabs(value[index]) > 0.00001f)
                return false;
        }
        return true;
    }

    static bool IsDegenerate(const D3DMATRIX& matrix)
    {
        // Rank-test a scale-normalized copy with partial pivoting.  A zero or
        // singular transform is finite and nonidentity, but it is not usable
        // camera state and must never satisfy the verifier's camera gate.
        double values[4][4] = {};
        double maximum = 0.0;
        const float* source = reinterpret_cast<const float*>(&matrix);
        for (size_t row = 0; row < 4; ++row)
        {
            for (size_t column = 0; column < 4; ++column)
            {
                values[row][column] = static_cast<double>(source[(row * 4) + column]);
                maximum = (std::fabs(values[row][column]) > maximum)
                    ? std::fabs(values[row][column])
                    : maximum;
            }
        }
        if (maximum <= static_cast<double>(FLT_EPSILON))
            return true;
        for (size_t row = 0; row < 4; ++row)
        {
            for (size_t column = 0; column < 4; ++column)
                values[row][column] /= maximum;
        }
        for (size_t column = 0; column < 4; ++column)
        {
            size_t pivotRow = column;
            double pivotMagnitude = std::fabs(values[pivotRow][column]);
            for (size_t row = column + 1; row < 4; ++row)
            {
                const double candidate = std::fabs(values[row][column]);
                if (candidate > pivotMagnitude)
                {
                    pivotMagnitude = candidate;
                    pivotRow = row;
                }
            }
            if (pivotMagnitude <= 0.0000001)
                return true;
            if (pivotRow != column)
            {
                for (size_t index = 0; index < 4; ++index)
                    std::swap(values[column][index], values[pivotRow][index]);
            }
            const double pivot = values[column][column];
            for (size_t row = column + 1; row < 4; ++row)
            {
                const double factor = values[row][column] / pivot;
                for (size_t index = column; index < 4; ++index)
                    values[row][index] -= factor * values[column][index];
            }
        }
        return false;
    }

    static bool IsUsable(const D3DMATRIX& matrix)
    {
        return IsFinite(matrix) && !IsZero(matrix) && !IsDegenerate(matrix);
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

    static void OpenLog()
    {
        if (s_Log != INVALID_HANDLE_VALUE)
            return;

        CreateDirectoryA("rtx-remix", nullptr);
        CreateDirectoryA("rtx-remix\\logs", nullptr);

        char path[MAX_PATH] = {};
        sprintf_s(path, "rtx-remix\\logs\\fearmore-camera-%lu.jsonl", GetCurrentProcessId());
        s_Log = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    }

    static ShaderIdentity GetShaderIdentity(IDirect3DVertexShader9* shader)
    {
        if (!shader)
            return {};

        ShaderIdentity identity;
        UINT byteCount = 0;
        if (SUCCEEDED(shader->GetFunction(nullptr, &byteCount)) && byteCount >= sizeof(uint32_t) && byteCount <= (1024u * 1024u))
        {
            std::vector<char> bytecode(byteCount);
            if (SUCCEEDED(shader->GetFunction(bytecode.data(), &byteCount)))
            {
                identity.byteCount = byteCount;
                memcpy(&identity.versionToken, bytecode.data(), sizeof(identity.versionToken));
                identity.hash = HashHelper::FNV1aRuntime(bytecode.data(), byteCount);
            }
        }

        return identity;
    }

    static DrawState CaptureDrawState(IDirect3DDevice9* device)
    {
        DrawState state;
        if (!device)
            return state;

        IDirect3DVertexShader9* shader = nullptr;
        state.vertexShaderKnown = SUCCEEDED(device->GetVertexShader(&shader));
        if (state.vertexShaderKnown)
        {
            state.vertexShaderPresent = shader != nullptr;
            state.vertexShaderIdentity = GetShaderIdentity(shader);
        }
        if (shader)
            shader->Release();

        state.worldPresent = SUCCEEDED(device->GetTransform(D3DTS_WORLD, &state.world));
        state.viewPresent = SUCCEEDED(device->GetTransform(D3DTS_VIEW, &state.view));
        state.projectionPresent = SUCCEEDED(device->GetTransform(D3DTS_PROJECTION, &state.projection));
        state.clipRegistersPresent = SUCCEEDED(device->GetVertexShaderConstantF(
            72, reinterpret_cast<float*>(&state.clipRegisters), 4));

        // Keep the frame-end diagnostic fields synchronized with the actual
        // device state even when a state-block Apply bypassed the Set* hooks.
        s_HaveVertexShader = state.vertexShaderKnown && state.vertexShaderPresent;
        s_VertexShaderIdentity = state.vertexShaderIdentity;
        s_HaveWorld = state.worldPresent;
        s_HaveView = state.viewPresent;
        s_HaveProjection = state.projectionPresent;
        s_World = state.world;
        s_View = state.view;
        s_Projection = state.projection;
        s_HaveClipRegisters = state.clipRegistersPresent;
        s_ClipRegisterRowMask = state.clipRegistersPresent ? 0x0Fu : 0;
        s_ClipRegisters = state.clipRegisters;
        return state;
    }

    static void CaptureRenderTarget(IDirect3DSurface9* renderTarget)
    {
        s_RenderTargetWidth = 0;
        s_RenderTargetHeight = 0;
        s_RenderTargetFormat = D3DFMT_UNKNOWN;
        if (!renderTarget)
            return;

        D3DSURFACE_DESC description = {};
        if (SUCCEEDED(renderTarget->GetDesc(&description)))
        {
            s_RenderTargetWidth = description.Width;
            s_RenderTargetHeight = description.Height;
            s_RenderTargetFormat = description.Format;
        }
    }

    static void ResetFrameCounters()
    {
        const uint64_t nextFrame = s_Frame.frameNumber + 1;
        s_Frame = {};
        s_Frame.frameNumber = nextFrame;
        s_FrameClipCandidate = {};
        s_HaveFrameClipCandidate = false;
        s_FrameClipShaderIdentity = {};
        s_FrameFfpCameraView = {};
        s_FrameFfpCameraProjection = {};
        s_HaveFrameFfpCamera = false;
    }

    static void LogFrame()
    {
        if (s_Frame.frameNumber >= 3600)
            return;

        char line[4096] = {};
        const UINT minimumRegister = s_Frame.minimumConstantRegister == std::numeric_limits<UINT>::max()
            ? 0
            : s_Frame.minimumConstantRegister;
        const D3DMATRIX& reportedClip = s_HaveFrameClipCandidate ? s_FrameClipCandidate : s_ClipRegisters;
        const float* clip = reinterpret_cast<const float*>(&reportedClip);
        const bool clipFinite = (s_HaveFrameClipCandidate || s_HaveClipRegisters) && IsFinite(reportedClip);
        char clipJson[16][32] = {};
        for (size_t index = 0; index < 16; ++index)
            FormatJsonFloat(clip[index], clipJson[index], sizeof(clipJson[index]));
        sprintf_s(line,
            "{\"event\":\"frame\",\"schema\":3,\"frame\":%llu,"
            "\"draws\":{\"shader\":%u,\"ffp\":%u,\"ffpWithCamera\":%u,\"primitives\":%llu},"
            "\"transforms\":{\"sets\":%u,\"worldSets\":%u,\"viewSets\":%u,\"projectionSets\":%u,"
            "\"worldPresent\":%s,\"viewPresent\":%s,\"projectionPresent\":%s,"
            "\"worldIdentity\":%s,\"viewIdentity\":%s,\"projectionIdentity\":%s,"
            "\"worldFinite\":%s,\"viewFinite\":%s,\"projectionFinite\":%s,"
            "\"worldUsable\":%s,\"viewUsable\":%s,\"projectionUsable\":%s,"
            "\"ffpCameraAtDrawPresent\":%s,\"ffpViewUsableAtDraw\":%s,\"ffpProjectionUsableAtDraw\":%s,\"ffpProjectionIdentityAtDraw\":%s},"
            "\"viewport\":{\"sets\":%u,\"present\":%s,\"x\":%lu,\"y\":%lu,\"width\":%lu,\"height\":%lu,\"minZ\":%.9g,\"maxZ\":%.9g},"
            "\"renderTarget\":{\"sets\":%u,\"width\":%u,\"height\":%u,\"format\":%d},"
            "\"vertexShader\":{\"present\":%s,\"hash\":\"%08X\",\"bytes\":%u,\"version\":\"%08X\"},"
            "\"constants\":{\"writes\":%u,\"fourRegisterWrites\":%u,\"clipRegisterWrites\":%u,\"completedClipRegisterWrites\":%u,\"nonZeroClipRegisterWrites\":%u,\"minimum\":%u,\"maximumExclusive\":%u,"
            "\"clipRowMask\":%u,\"clipPresent\":%s,\"frameCandidatePresent\":%s,\"frameCandidateDraws\":%u,\"frameCandidateShaderHash\":\"%08X\",\"clipFinite\":%s,\"clip\":[%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s]}}",
            static_cast<unsigned long long>(s_Frame.frameNumber),
            s_Frame.shaderDrawCalls, s_Frame.fixedFunctionDrawCalls, s_Frame.fixedFunctionCameraDrawCalls,
            static_cast<unsigned long long>(s_Frame.primitives),
            s_Frame.setTransformCalls, s_Frame.worldTransformCalls, s_Frame.viewTransformCalls, s_Frame.projectionTransformCalls,
            s_HaveWorld ? "true" : "false", s_HaveView ? "true" : "false", s_HaveProjection ? "true" : "false",
            s_HaveWorld && IsIdentity(s_World) ? "true" : "false",
            s_HaveView && IsIdentity(s_View) ? "true" : "false",
            s_HaveProjection && IsIdentity(s_Projection) ? "true" : "false",
            s_HaveWorld && IsFinite(s_World) ? "true" : "false",
            s_HaveView && IsFinite(s_View) ? "true" : "false",
            s_HaveProjection && IsFinite(s_Projection) ? "true" : "false",
            s_HaveWorld && IsUsable(s_World) ? "true" : "false",
            s_HaveView && IsUsable(s_View) ? "true" : "false",
            s_HaveProjection && IsUsable(s_Projection) ? "true" : "false",
            s_HaveFrameFfpCamera ? "true" : "false",
            s_HaveFrameFfpCamera && IsUsable(s_FrameFfpCameraView) ? "true" : "false",
            s_HaveFrameFfpCamera && IsUsable(s_FrameFfpCameraProjection) ? "true" : "false",
            s_HaveFrameFfpCamera && IsIdentity(s_FrameFfpCameraProjection) ? "true" : "false",
            s_Frame.setViewportCalls, s_HaveViewport ? "true" : "false",
            s_Viewport.X, s_Viewport.Y, s_Viewport.Width, s_Viewport.Height, s_Viewport.MinZ, s_Viewport.MaxZ,
            s_Frame.setRenderTargetCalls, s_RenderTargetWidth, s_RenderTargetHeight, static_cast<int>(s_RenderTargetFormat),
            s_HaveVertexShader ? "true" : "false", s_VertexShaderIdentity.hash,
            s_VertexShaderIdentity.byteCount, s_VertexShaderIdentity.versionToken,
            s_Frame.constantWrites, s_Frame.fourRegisterWrites, s_Frame.clipRegisterWrites,
            s_Frame.completedClipRegisterWrites, s_Frame.nonZeroClipRegisterWrites,
            minimumRegister, s_Frame.maximumConstantRegister,
            static_cast<unsigned int>(s_ClipRegisterRowMask),
            s_HaveClipRegisters ? "true" : "false",
            s_HaveFrameClipCandidate ? "true" : "false", s_Frame.clipCandidateDrawCalls, s_FrameClipShaderIdentity.hash,
            clipFinite ? "true" : "false",
            clipJson[0], clipJson[1], clipJson[2], clipJson[3], clipJson[4], clipJson[5], clipJson[6], clipJson[7],
            clipJson[8], clipJson[9], clipJson[10], clipJson[11], clipJson[12], clipJson[13], clipJson[14], clipJson[15]);
        WriteLogLine(line);
        if ((s_Frame.frameNumber % 60) == 0 && s_Log != INVALID_HANDLE_VALUE)
            FlushFileBuffers(s_Log);
    }

    static HRESULT WINAPI SetRenderTargetHook(IDirect3DDevice9* device, DWORD index, IDirect3DSurface9* renderTarget)
    {
        const HRESULT result = s_SetRenderTarget(device, index, renderTarget);
        if (SUCCEEDED(result) && index == 0)
        {
            ++s_Frame.setRenderTargetCalls;
            CaptureRenderTarget(renderTarget);
        }
        return result;
    }

    static HRESULT WINAPI EndSceneHook(IDirect3DDevice9* device)
    {
        const HRESULT result = s_EndScene(device);
        LogFrame();
        ResetFrameCounters();
        return result;
    }

    static HRESULT WINAPI SetTransformHook(IDirect3DDevice9* device, D3DTRANSFORMSTATETYPE state, const D3DMATRIX* matrix)
    {
        const HRESULT result = s_SetTransform(device, state, matrix);
        if (SUCCEEDED(result) && matrix)
        {
            ++s_Frame.setTransformCalls;
            if (state == D3DTS_WORLD)
            {
                s_World = *matrix;
                s_HaveWorld = true;
                ++s_Frame.worldTransformCalls;
            }
            else if (state == D3DTS_VIEW)
            {
                s_View = *matrix;
                s_HaveView = true;
                ++s_Frame.viewTransformCalls;
            }
            else if (state == D3DTS_PROJECTION)
            {
                s_Projection = *matrix;
                s_HaveProjection = true;
                ++s_Frame.projectionTransformCalls;
            }
        }
        return result;
    }

    static HRESULT WINAPI SetViewportHook(IDirect3DDevice9* device, const D3DVIEWPORT9* viewport)
    {
        const HRESULT result = s_SetViewport(device, viewport);
        if (SUCCEEDED(result) && viewport)
        {
            s_Viewport = *viewport;
            s_HaveViewport = true;
            ++s_Frame.setViewportCalls;
        }
        return result;
    }

    static void CountDraw(const DrawState& drawState, UINT primitiveCount)
    {
        if (drawState.vertexShaderKnown && drawState.vertexShaderPresent)
        {
            ++s_Frame.shaderDrawCalls;
            if (drawState.clipRegistersPresent && IsFinite(drawState.clipRegisters) && !IsZero(drawState.clipRegisters))
            {
                ++s_Frame.clipCandidateDrawCalls;
                if (!s_HaveFrameClipCandidate)
                {
                    s_FrameClipCandidate = drawState.clipRegisters;
                    s_HaveFrameClipCandidate = true;
                    s_FrameClipShaderIdentity = drawState.vertexShaderIdentity;
                }
            }
        }
        else if (drawState.vertexShaderKnown)
        {
            ++s_Frame.fixedFunctionDrawCalls;
            if (drawState.viewPresent && IsUsable(drawState.view) &&
                drawState.projectionPresent && IsUsable(drawState.projection) && !IsIdentity(drawState.projection))
            {
                ++s_Frame.fixedFunctionCameraDrawCalls;
                if (!s_HaveFrameFfpCamera)
                {
                    s_FrameFfpCameraView = drawState.view;
                    s_FrameFfpCameraProjection = drawState.projection;
                    s_HaveFrameFfpCamera = true;
                }
            }
        }
        s_Frame.primitives += primitiveCount;
    }

    static HRESULT WINAPI DrawPrimitiveHook(IDirect3DDevice9* device, D3DPRIMITIVETYPE primitiveType, UINT startVertex, UINT primitiveCount)
    {
        const DrawState drawState = CaptureDrawState(device);
        const HRESULT result = s_DrawPrimitive(device, primitiveType, startVertex, primitiveCount);
        if (SUCCEEDED(result))
            CountDraw(drawState, primitiveCount);
        return result;
    }

    static HRESULT WINAPI DrawIndexedPrimitiveHook(IDirect3DDevice9* device, D3DPRIMITIVETYPE primitiveType, INT baseVertexIndex,
        UINT minimumVertexIndex, UINT numberOfVertices, UINT startIndex, UINT primitiveCount)
    {
        const DrawState drawState = CaptureDrawState(device);
        const HRESULT result = s_DrawIndexedPrimitive(device, primitiveType, baseVertexIndex, minimumVertexIndex, numberOfVertices, startIndex, primitiveCount);
        if (SUCCEEDED(result))
            CountDraw(drawState, primitiveCount);
        return result;
    }

    static HRESULT WINAPI SetVertexShaderHook(IDirect3DDevice9* device, IDirect3DVertexShader9* shader)
    {
        const HRESULT result = s_SetVertexShader(device, shader);
        if (SUCCEEDED(result))
        {
            s_HaveVertexShader = shader != nullptr;
            s_VertexShaderIdentity = GetShaderIdentity(shader);
        }
        return result;
    }

    static HRESULT WINAPI SetVertexShaderConstantFHook(IDirect3DDevice9* device, UINT startRegister, const float* constantData, UINT vector4Count)
    {
        const HRESULT result = s_SetVertexShaderConstantF(device, startRegister, constantData, vector4Count);
        if (SUCCEEDED(result) && constantData && vector4Count > 0)
        {
            ++s_Frame.constantWrites;
            s_Frame.minimumConstantRegister = (startRegister < s_Frame.minimumConstantRegister)
                ? startRegister
                : s_Frame.minimumConstantRegister;
            const UINT endRegister = startRegister + vector4Count;
            s_Frame.maximumConstantRegister = (endRegister > s_Frame.maximumConstantRegister)
                ? endRegister
                : s_Frame.maximumConstantRegister;
            if (vector4Count == 4)
                ++s_Frame.fourRegisterWrites;

            static constexpr UINT clipStart = 72;
            static constexpr UINT clipEnd = 76;
            const UINT overlapStart = (startRegister > clipStart) ? startRegister : clipStart;
            const UINT overlapEnd = (endRegister < clipEnd) ? endRegister : clipEnd;
            if (overlapStart < overlapEnd)
            {
                ++s_Frame.clipRegisterWrites;
                float* clip = reinterpret_cast<float*>(&s_ClipRegisters);
                for (UINT registerIndex = overlapStart; registerIndex < overlapEnd; ++registerIndex)
                {
                    const UINT sourceOffset = (registerIndex - startRegister) * 4;
                    const UINT destinationOffset = (registerIndex - clipStart) * 4;
                    memcpy(clip + destinationOffset, constantData + sourceOffset, sizeof(float) * 4);
                    s_ClipRegisterRowMask |= static_cast<uint8_t>(1u << (registerIndex - clipStart));
                }
                s_HaveClipRegisters = s_ClipRegisterRowMask == 0x0Fu;
                if (s_HaveClipRegisters)
                {
                    ++s_Frame.completedClipRegisterWrites;
                    if (IsFinite(s_ClipRegisters) && !IsZero(s_ClipRegisters))
                    {
                        ++s_Frame.nonZeroClipRegisterWrites;
                    }
                }
            }
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
        if (!EnableRemixCameraDiagnostics || !device)
            return;

        OpenLog();
        void** vtable = *reinterpret_cast<void***>(device);
        const bool renderTargetHook = InstallHook(vtable[37], s_SetRenderTargetAddress, reinterpret_cast<LPVOID>(&SetRenderTargetHook), s_SetRenderTarget);
        const bool endSceneHook = InstallHook(vtable[42], s_EndSceneAddress, reinterpret_cast<LPVOID>(&EndSceneHook), s_EndScene);
        const bool transformHook = InstallHook(vtable[44], s_SetTransformAddress, reinterpret_cast<LPVOID>(&SetTransformHook), s_SetTransform);
        const bool viewportHook = InstallHook(vtable[47], s_SetViewportAddress, reinterpret_cast<LPVOID>(&SetViewportHook), s_SetViewport);
        const bool drawPrimitiveHook = InstallHook(vtable[81], s_DrawPrimitiveAddress, reinterpret_cast<LPVOID>(&DrawPrimitiveHook), s_DrawPrimitive);
        const bool drawIndexedHook = InstallHook(vtable[82], s_DrawIndexedPrimitiveAddress, reinterpret_cast<LPVOID>(&DrawIndexedPrimitiveHook), s_DrawIndexedPrimitive);
        const bool vertexShaderHook = InstallHook(vtable[92], s_SetVertexShaderAddress, reinterpret_cast<LPVOID>(&SetVertexShaderHook), s_SetVertexShader);
        const bool constantHook = InstallHook(vtable[94], s_SetVertexShaderConstantFAddress, reinterpret_cast<LPVOID>(&SetVertexShaderConstantFHook), s_SetVertexShaderConstantF);

        s_HaveWorld = SUCCEEDED(device->GetTransform(D3DTS_WORLD, &s_World));
        s_HaveView = SUCCEEDED(device->GetTransform(D3DTS_VIEW, &s_View));
        s_HaveProjection = SUCCEEDED(device->GetTransform(D3DTS_PROJECTION, &s_Projection));
        s_HaveViewport = SUCCEEDED(device->GetViewport(&s_Viewport));
        s_HaveVertexShader = false;
        s_VertexShaderIdentity = {};
        IDirect3DVertexShader9* initialVertexShader = nullptr;
        if (SUCCEEDED(device->GetVertexShader(&initialVertexShader)))
        {
            s_HaveVertexShader = initialVertexShader != nullptr;
            s_VertexShaderIdentity = GetShaderIdentity(initialVertexShader);
            if (initialVertexShader)
                initialVertexShader->Release();
        }
        s_ClipRegisters = {};
        s_ClipRegisterRowMask = 0;
        s_HaveClipRegisters = false;
        if (SUCCEEDED(device->GetVertexShaderConstantF(72, reinterpret_cast<float*>(&s_ClipRegisters), 4)))
        {
            s_ClipRegisterRowMask = 0x0Fu;
            s_HaveClipRegisters = true;
        }
        IDirect3DSurface9* renderTarget = nullptr;
        if (SUCCEEDED(device->GetRenderTarget(0, &renderTarget)) && renderTarget)
        {
            CaptureRenderTarget(renderTarget);
            renderTarget->Release();
        }

        char line[1024] = {};
        sprintf_s(line,
            "{\"event\":\"capability\",\"schema\":3,\"pid\":%lu,\"enabled\":true,"
            "\"hooks\":{\"setRenderTarget\":%s,\"endScene\":%s,\"setTransform\":%s,\"setViewport\":%s,"
            "\"drawPrimitive\":%s,\"drawIndexedPrimitive\":%s,\"setVertexShader\":%s,\"setVertexShaderConstantF\":%s},"
            "\"boundedFrames\":3600,\"clipRegisterStart\":72,\"clipRegisterCount\":4}",
            GetCurrentProcessId(), renderTargetHook ? "true" : "false", endSceneHook ? "true" : "false",
            transformHook ? "true" : "false", viewportHook ? "true" : "false", drawPrimitiveHook ? "true" : "false",
            drawIndexedHook ? "true" : "false", vertexShaderHook ? "true" : "false", constantHook ? "true" : "false");
        WriteLogLine(line);
    }
}

static void InstallRemixCameraDiagnostics(IDirect3DDevice9* device)
{
    RemixCameraDiagnostics::Install(device);
}
