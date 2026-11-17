using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Iap2Loc.Protocol;

namespace Iap2Loc.Desktop;

/// <summary>
/// macOS port of DesktopSettings. The Windows build protects the Amap key with DPAPI,
/// which does not exist on macOS. Here we derive a local AES key from a per-machine
/// salt file inside the app data directory and encrypt in place. The key never leaves
/// the machine; this is at-rest obfuscation, not a security boundary.
/// </summary>
internal sealed class DesktopSettings
{
    public static string DataDirectory => Environment.GetEnvironmentVariable("SUIXING_DATA")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library", "Application Support", "SuixingLoc");
    public static string SettingsPath => Path.Combine(DataDirectory, "desktop.json");
    private static string KeyPath => Path.Combine(DataDirectory, ".key");

    public double Latitude { get; set; } = 31.2304;
    public double Longitude { get; set; } = 121.4737;
    public double Altitude { get; set; } = 10;
    public double Accuracy { get; set; } = 5;
    public double Speed { get; set; }
    public double Bearing { get; set; }
    public int Rate { get; set; } = 250;
    public int Quality { get; set; } = 1;
    public int Satellites { get; set; } = 8;
    public bool JitterPosition { get; set; }
    public bool JitterAccuracy { get; set; }
    public double JitterMeters { get; set; } = 10;
    public double AccuracyMin { get; set; } = 3;
    public double AccuracyMax { get; set; } = 12;
    public string Datum { get; set; } = "gcj";
    public string SearchProvider { get; set; } = "auto";
    public string SearchCity { get; set; } = "";
    public string PhotonEndpoint { get; set; } = "https://photon.komoot.io/api/";
    public string ProtectedAmapKey { get; set; } = "";
    public bool UseImportedIdentity { get; set; }
    public List<string> SearchHistory { get; set; } = new();

    [JsonIgnore]
    public string AmapKey
    {
        get
        {
            try { return string.IsNullOrEmpty(ProtectedAmapKey) ? "" : LocalProtect.Decrypt(Convert.FromBase64String(ProtectedAmapKey)); }
            catch { return ""; }
        }
        set => ProtectedAmapKey = string.IsNullOrWhiteSpace(value)
            ? ""
            : Convert.ToBase64String(LocalProtect.Encrypt(value.Trim()));
    }

    public static DesktopSettings Load()
    {
        try
        {
            var settings = JsonSerializer.Deserialize<DesktopSettings>(File.ReadAllText(SettingsPath)) ?? new();
            var target = new LocationTarget(settings.Latitude, settings.Longitude);
            target.Apply(settings.ToTargetUpdate());
            if (settings.Rate is < 10 or > 60000 || settings.Quality is < 0 or > 8 || settings.Satellites is < 0 or > 99
                || settings.Altitude is < -12000 or > 100000 || settings.Accuracy is < .1 or > 100000
                || settings.Speed is < 0 or > 1000 || settings.JitterMeters is < 0 or > 10000
                || settings.AccuracyMin is < .1 or > 100000 || settings.AccuracyMax is < .1 or > 100000)
                throw new ArgumentException("保存的定位参数超出范围");
            settings.SearchHistory ??= new();
            settings.SearchHistory = settings.SearchHistory.Where(s => !string.IsNullOrWhiteSpace(s) && s.Length <= 200).Distinct().Take(15).ToList();
            settings.SearchCity ??= "";
            settings.PhotonEndpoint ??= "https://photon.komoot.io/api/";
            if (settings.SearchProvider is not ("auto" or "amap" or "photon")) settings.SearchProvider = "auto";
            if (settings.Datum is not ("gcj" or "wgs")) settings.Datum = "gcj";
            return settings;
        }
        catch { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(DataDirectory);
        LocalProtect.EnsureKey(KeyPath);
        var temporary = SettingsPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, SettingsPath, true);
    }

    public TargetUpdate ToTargetUpdate() => new()
    {
        Latitude = Latitude, Longitude = Longitude, Altitude = Altitude, Accuracy = Accuracy,
        Speed = Speed, Bearing = Bearing, Quality = Quality, Satellites = Satellites,
        JitterPosition = JitterPosition, JitterAccuracy = JitterAccuracy, JitterMeters = JitterMeters,
        AccuracyMin = AccuracyMin, AccuracyMax = AccuracyMax,
    };
}

/// <summary>AES-GCM helper keyed by a 32-byte file stored with 0600 permissions in the data dir.</summary>
internal static class LocalProtect
{
    private static readonly object Gate = new();
    private static byte[]? _cached;

    public static void EnsureKey(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (File.Exists(path) && new FileInfo(path).Length == 32) return;
        var key = RandomNumberGenerator.GetBytes(32);
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, key);
        File.Move(tmp, path, true);
        Restrict(path);
    }

    private static byte[] Key(string path)
    {
        lock (Gate)
        {
            if (_cached is { Length: 32 }) return _cached;
            EnsureKey(path);
            _cached = File.ReadAllBytes(path);
            if (_cached.Length != 32) throw new CryptographicException("本地密钥文件损坏");
            return _cached;
        }
    }

    public static byte[] Encrypt(string plain)
    {
        var nonce = RandomNumberGenerator.GetBytes(12);
        using var aes = new AesGcm(Key(DefaultKeyPath()), 16);
        var cipher = new byte[Encoding.UTF8.GetByteCount(plain)];
        var tag = new byte[16];
        aes.Encrypt(nonce, Encoding.UTF8.GetBytes(plain), cipher, tag);
        return Concat(nonce, tag, cipher);
    }

    public static string Decrypt(byte[] blob)
    {
        if (blob.Length < 28) throw new CryptographicException("密文格式错误");
        var nonce = blob[..12];
        var tag = blob[12..28];
        var cipher = blob[28..];
        var plain = new byte[cipher.Length];
        using var aes = new AesGcm(Key(DefaultKeyPath()), 16);
        aes.Decrypt(nonce, cipher, tag, plain);
        return Encoding.UTF8.GetString(plain);
    }

    private static string DefaultKeyPath() => Path.Combine(DataDir(), ".key");
    private static string DataDir() => DesktopSettings.DataDirectory;

    internal static byte[] EncryptBytes(byte[] raw)
    {
        var nonce = RandomNumberGenerator.GetBytes(12);
        using var aes = new AesGcm(Key(DefaultKeyPath()), 16);
        var cipher = new byte[raw.Length];
        var tag = new byte[16];
        aes.Encrypt(nonce, raw, cipher, tag);
        return Concat(nonce, tag, cipher);
    }

    internal static byte[] DecryptBytes(byte[] blob)
    {
        if (blob.Length < 28) throw new CryptographicException("密文格式错误");
        var nonce = blob[..12];
        var tag = blob[12..28];
        var cipher = blob[28..];
        var plain = new byte[cipher.Length];
        using var aes = new AesGcm(Key(DefaultKeyPath()), 16);
        aes.Decrypt(nonce, cipher, tag, plain);
        return plain;
    }

    private static byte[] Concat(byte[] a, byte[] b, byte[] c)
    {
        var result = new byte[a.Length + b.Length + c.Length];
        Buffer.BlockCopy(a, 0, result, 0, a.Length);
        Buffer.BlockCopy(b, 0, result, a.Length, b.Length);
        Buffer.BlockCopy(c, 0, result, a.Length + b.Length, c.Length);
        return result;
    }

    public static void Restrict(string path)
    {
        if (OperatingSystem.IsWindows()) return;
        try { File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite); }
        catch { }
    }
}
