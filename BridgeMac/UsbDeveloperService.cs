using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Iap2Loc.Protocol;

namespace SuixingLoc.Core;

/// <summary>Owns the isolated USB runtime (self-contained CPython + pymobiledevice3).
/// Snapshots never wait on device I/O. macOS port: process lifecycle is managed without
/// Windows Job Objects; the child is terminated on orderly shutdown and on process exit.</summary>
internal sealed class UsbDeveloperService : IAsyncDisposable
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly object gate = new();
    private readonly SemaphoreSlim startup = new(1, 1);
    private readonly SemaphoreSlim writes = new(1, 1);
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> pending = new();
    private Process? process;
    private Task? exitTask;
    private int next;
    private bool disposed;
    private TargetState? target;
    private JsonElement state = JsonSerializer.SerializeToElement(new { phase = "idle", status = "尚未连接" });

    public UsbDeveloperService()
    {
        // Best-effort cleanup if the core is terminated without a shutdown request
        // (e.g. the Flutter host is force-quit). The normal path goes through DisposeAsync.
        AppDomain.CurrentDomain.ProcessExit += (_, _) => KillChild();
    }

    public JsonElement Snapshot() { lock (gate) return state; }

    public void Remember(TargetState value)
    {
        lock (gate)
        {
            if (target is null || value.Revision >= target.Revision) target = value;
        }
    }

    public async Task UpdateTarget(TargetState value)
    {
        Remember(value);
        Process? current;
        lock (gate) current = process;
        if (current is null || current.HasExited) return;
        try { await SendTarget(); }
        catch (Exception ex) { SetFailure(ex.Message, exited: false); }
    }

    private Task<JsonElement> SendTarget()
    {
        TargetState current;
        lock (gate) current = target ?? throw new InvalidOperationException("请先保存目标位置。");
        return Request("target", new { latitude = current.ResolvedLatitude, longitude = current.ResolvedLongitude, current.Revision });
    }

    public async Task<JsonElement> Devices()
    {
        await EnsureStarted();
        return await Request("devices", new { });
    }

    public async Task<bool> Connect(string udid)
    {
        await EnsureStarted();
        await SendTarget();
        await Request("connect", new { udid });
        return true;
    }

    public async Task<JsonElement> RevealDeveloperMode(string udid)
    {
        await EnsureStarted();
        return await Request("revealDeveloperMode", new { udid });
    }

    public async Task<bool> Stop()
    {
        Process? current;
        lock (gate) current = process;
        if (current is not null && !current.HasExited) await Request("stop", new { });
        return true;
    }

    public async Task<bool> ClearError()
    {
        Process? current;
        lock (gate) current = process;
        if (current is not null && !current.HasExited) await Request("clearError", new { });
        else lock (gate)
        {
            var values = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(state.GetRawText())!;
            values["phase"] = JsonSerializer.SerializeToElement("idle");
            values["error"] = JsonSerializer.SerializeToElement<string?>(null);
            values["status"] = JsonSerializer.SerializeToElement("尚未连接");
            state = JsonSerializer.SerializeToElement(values);
        }
        return true;
    }

    private async Task EnsureStarted()
    {
        await startup.WaitAsync();
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (process is { HasExited: false }) return;
            if (exitTask is not null) await exitTask;
            process?.Dispose();
            // AppContext.BaseDirectory is Contents/MacOS/core; the USB runtime is bundled
            // next to the core as core/usb/{bin/python3,worker.py,lib/python3.14/site-packages}.
            var directory = Path.Combine(AppContext.BaseDirectory, "usb");
            var executable = Path.Combine(directory, "bin", "python3");
            var worker = Path.Combine(directory, "worker.py");
            if (!File.Exists(executable) || !File.Exists(worker))
                throw new InvalidOperationException("USB 开发者组件缺失，请重新安装完整应用包。");
            var info = new ProcessStartInfo(executable)
            {
                WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            info.ArgumentList.Add("-u");
            info.ArgumentList.Add("-X");
            info.ArgumentList.Add("utf8");
            info.ArgumentList.Add(worker);
            info.Environment["PYTHONIOENCODING"] = "utf-8";
            info.Environment["PYTHONUTF8"] = "1";
            // Keep the bundled runtime self-contained; never inherit a broken system Python.
            info.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
            var child = Process.Start(info) ?? throw new IOException("USB 开发者组件启动失败。");
            lock (gate) process = child;
            var outputTask = ReadOutput(child);
            _ = DrainErrors(child);
            exitTask = WatchExit(child, outputTask);
        }
        finally { startup.Release(); }
    }

    private async Task<JsonElement> Request(string method, object args)
    {
        var id = Interlocked.Increment(ref next);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = completion;
        try
        {
            await writes.WaitAsync();
            try
            {
                var child = process ?? throw new IOException("USB 开发者组件尚未启动。");
                await child.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { id, method, args }, Json));
                await child.StandardInput.FlushAsync();
            }
            finally { writes.Release(); }
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(23));
        }
        catch (TimeoutException) { throw new IOException("USB 组件响应超时，请停止连接后重试。"); }
        finally { pending.TryRemove(id, out _); }
    }

    private async Task ReadOutput(Process child)
    {
        try
        {
            while (await child.StandardOutput.ReadLineAsync() is { } line)
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.TryGetProperty("event", out var evt) && evt.GetString() == "state")
                {
                    lock (gate) state = root.GetProperty("state").Clone();
                }
                else if (root.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.Number &&
                         pending.TryRemove(id.GetInt32(), out var completion))
                {
                    if (root.TryGetProperty("error", out var error))
                        completion.TrySetException(new InvalidOperationException(error.GetString()));
                    else completion.TrySetResult(root.GetProperty("result").Clone());
                }
            }
        }
        catch (Exception) { if (!disposed) SetFailure("USB 组件通信中断，请重新连接。"); }
    }

    private static async Task DrainErrors(Process child)
    {
        // Third-party traces may contain device identifiers; never echo them into UI logs.
        try { while (await child.StandardError.ReadLineAsync() is not null) { } }
        catch (Exception) { }
    }

    private async Task WatchExit(Process child, Task outputTask)
    {
        await child.WaitForExitAsync();
        await outputTask;
        foreach (var item in pending) if (pending.TryRemove(item.Key, out var completion))
            completion.TrySetException(new IOException("USB 开发者组件已退出，请重新连接。"));
        if (!disposed) SetFailure("USB 开发者组件已退出，请重新连接；若曾提交定位，停止模拟状态未确认。");
    }

    private void SetFailure(string message, bool exited = true)
    {
        lock (gate)
        {
            var values = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(state.GetRawText())!;
            if (exited) values["phase"] = JsonSerializer.SerializeToElement("error");
            if (exited && values.TryGetValue("lastRevision", out var revision) && revision.ValueKind == JsonValueKind.Number)
                values["restoreWarning"] = JsonSerializer.SerializeToElement("USB 组件已中断，停止模拟状态未确认；请重新连接后再停止模拟。");
            values["error"] = JsonSerializer.SerializeToElement(message);
            state = JsonSerializer.SerializeToElement(values);
        }
    }

    private void KillChild()
    {
        try
        {
            Process? child;
            lock (gate) child = process;
            if (child is { HasExited: false }) child.Kill(entireProcessTree: true);
        }
        catch (Exception) { /* best effort on process teardown */ }
    }

    public async ValueTask DisposeAsync()
    {
        await startup.WaitAsync();
        try
        {
            if (disposed) return;
            disposed = true;
            if (process is { HasExited: false } child)
            {
                try
                {
                    await Request("shutdown", new { }).WaitAsync(TimeSpan.FromSeconds(14));
                    child.StandardInput.Close();
                    await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
                    if (exitTask is not null) await exitTask;
                }
                catch (Exception) { if (!child.HasExited) child.Kill(entireProcessTree: true); }
            }
            process?.Dispose();
        }
        finally { startup.Release(); }
    }
}
