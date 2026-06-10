using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using MsgKit;
using MsgKit.Enums;

var options = CliOptions.Parse(args);
var repositoryRoot = Path.GetFullPath(options.RepositoryRoot ?? Directory.GetCurrentDirectory());
var inputPaths = ResolveInputPaths(repositoryRoot, options);

if (inputPaths.Count == 0)
{
    throw new InvalidOperationException("No HTML files were found to process.");
}

foreach (var htmlPath in inputPaths)
{
    ConvertHtmlToOft(repositoryRoot, htmlPath, options);
}

static List<string> ResolveInputPaths(string repositoryRoot, CliOptions options)
{
    if (!string.IsNullOrWhiteSpace(options.HtmlPath))
    {
        var fullHtmlPath = Path.GetFullPath(options.HtmlPath, repositoryRoot);
        if (!File.Exists(fullHtmlPath))
        {
            throw new FileNotFoundException("HTML file not found.", fullHtmlPath);
        }

        return [fullHtmlPath];
    }

    var folder = Path.GetFullPath(options.Folder ?? ".", repositoryRoot);
    if (!Directory.Exists(folder))
    {
        throw new DirectoryNotFoundException($"Folder not found: {folder}");
    }

    var htmlFiles = Directory
        .EnumerateFiles(folder, "*.*", SearchOption.AllDirectories)
        .Where(path =>
            string.Equals(Path.GetExtension(path), ".html", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(Path.GetExtension(path), ".htm", StringComparison.OrdinalIgnoreCase))
        .Where(path =>
        {
            var fileName = Path.GetFileName(path);
            return !Regex.IsMatch(fileName, @"_oft_(input|build)\.html?$", RegexOptions.IgnoreCase);
        })
        .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
        .ToList();

    var preferred = htmlFiles
        .Where(path =>
        {
            var fileName = Path.GetFileName(path);
            return !Regex.IsMatch(fileName, @"(^local|_local)\.html?$", RegexOptions.IgnoreCase);
        })
        .ToList();

    return preferred.Count > 0 ? preferred : htmlFiles;
}

static void ConvertHtmlToOft(string repositoryRoot, string htmlPath, CliOptions options)
{
    var htmlDirectory = Path.GetDirectoryName(htmlPath) ?? repositoryRoot;
    var html = File.ReadAllText(htmlPath, Encoding.UTF8);
    var subject = !string.IsNullOrWhiteSpace(options.Subject)
        ? options.Subject!
        : ExtractTitle(html) ?? Path.GetFileNameWithoutExtension(htmlPath);

    var attachments = new List<InlineAttachment>();
    var rewrittenHtml = RewriteLocalImageSources(html, repositoryRoot, htmlDirectory, attachments);
    var outputPath = Path.Combine(htmlDirectory, Path.GetFileNameWithoutExtension(htmlPath) + ".oft");
    var buildJsonPath = Path.Combine(htmlDirectory, Path.GetFileNameWithoutExtension(htmlPath) + "_oft_build.json");

    if (File.Exists(outputPath))
    {
        File.Delete(outputPath);
    }

    using (var email = new Email(
        new Sender(options.SenderAddress, options.SenderName),
        new Representing(options.SenderAddress, options.SenderName),
        subject))
    {
        email.Subject = subject;
        email.BodyText = StripHtml(rewrittenHtml);
        email.BodyHtml = rewrittenHtml;
        email.Importance = MessageImportance.IMPORTANCE_NORMAL;
        email.IconIndex = MessageIconIndex.UnsentMail;

        foreach (var attachment in attachments)
        {
            email.Attachments.Add(attachment.FullPath, -1, true, attachment.ContentId);
        }

        email.Save(outputPath);
    }

    ValidateCompoundFile(outputPath);

    var manifest = new BuildManifest
    {
        GeneratedAt = DateTimeOffset.UtcNow,
        Html = ToRepoRelativePath(repositoryRoot, htmlPath),
        Oft = ToRepoRelativePath(repositoryRoot, outputPath),
        Subject = subject,
        Generator = "MsgKit 3.0.5 on .NET",
        OutlookDesktopRequired = false,
        InlineAttachmentCount = attachments.Count,
        InlineAttachments = attachments
            .Select(attachment => new InlineAttachmentManifest
            {
                Source = attachment.OriginalSource,
                ContentId = attachment.ContentId,
                File = ToRepoRelativePath(repositoryRoot, attachment.FullPath)
            })
            .ToList()
    };

    File.WriteAllText(
        buildJsonPath,
        JsonSerializer.Serialize(manifest, CreateJsonOptions()),
        new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

    Console.WriteLine($"Generated OFT: {ToRepoRelativePath(repositoryRoot, outputPath)}");
}

static string RewriteLocalImageSources(
    string html,
    string repositoryRoot,
    string htmlDirectory,
    List<InlineAttachment> attachments)
{
    return ImgSrcRegex().Replace(html, match =>
    {
        var prefix = match.Groups["prefix"].Value;
        var quote = match.Groups["quote"].Value;
        var source = match.Groups["source"].Value.Trim();

        if (IsExternalOrSpecialSource(source))
        {
            return match.Value;
        }

        var split = SplitResourceValue(source);
        if (string.IsNullOrWhiteSpace(split.Path))
        {
            return match.Value;
        }

        var decodedPath = Uri.UnescapeDataString(split.Path);
        var fullPath = Path.GetFullPath(decodedPath, htmlDirectory);
        if (!IsInsideDirectory(repositoryRoot, fullPath))
        {
            throw new InvalidOperationException($"Relative image source points outside the repository: {source}");
        }

        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException($"Relative image source was not found: {source}", fullPath);
        }

        var contentId = MakeContentId(fullPath, attachments.Count);
        attachments.Add(new InlineAttachment(source, fullPath, contentId));

        return $"{prefix}{quote}cid:{contentId}{quote}";
    });
}

static bool IsInsideDirectory(string directory, string path)
{
    var root = Path.GetFullPath(directory);
    if (!root.EndsWith(Path.DirectorySeparatorChar))
    {
        root += Path.DirectorySeparatorChar;
    }

    var fullPath = Path.GetFullPath(path);
    return fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase);
}

static Regex ImgSrcRegex() => new(
    "(?<prefix><img\\b[^>]*?\\bsrc\\s*=\\s*)(?<quote>[\"'])(?<source>.*?)(\\k<quote>)",
    RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant);

static bool IsExternalOrSpecialSource(string source)
{
    if (string.IsNullOrWhiteSpace(source))
    {
        return true;
    }

    if (source.StartsWith("//", StringComparison.Ordinal) ||
        source.StartsWith("/", StringComparison.Ordinal) ||
        source.StartsWith("#", StringComparison.Ordinal) ||
        source.StartsWith("cid:", StringComparison.OrdinalIgnoreCase) ||
        source.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
    {
        return true;
    }

    return Uri.TryCreate(source, UriKind.Absolute, out _);
}

static ResourceParts SplitResourceValue(string source)
{
    var firstMarker = source.Length;
    foreach (var marker in new[] { '?', '#' })
    {
        var index = source.IndexOf(marker, StringComparison.Ordinal);
        if (index >= 0 && index < firstMarker)
        {
            firstMarker = index;
        }
    }

    return firstMarker == source.Length
        ? new ResourceParts(source, string.Empty)
        : new ResourceParts(source[..firstMarker], source[firstMarker..]);
}

static string MakeContentId(string fullPath, int index)
{
    var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(fullPath).ToLowerInvariant()));
    var hash = Convert.ToHexString(bytes)[..16].ToLowerInvariant();
    var extension = Path.GetExtension(fullPath).TrimStart('.');
    var suffix = string.IsNullOrWhiteSpace(extension) ? "image" : extension.ToLowerInvariant();
    return $"img-{index + 1}-{hash}@edm.{suffix}";
}

static string? ExtractTitle(string html)
{
    var match = Regex.Match(html, @"(?is)<title[^>]*>(.*?)</title>");
    if (!match.Success)
    {
        return null;
    }

    var title = System.Net.WebUtility.HtmlDecode(match.Groups[1].Value).Trim();
    return string.IsNullOrWhiteSpace(title) ? null : title;
}

static string StripHtml(string html)
{
    var withoutScripts = Regex.Replace(html, @"(?is)<(script|style)[^>]*>.*?</\1>", string.Empty);
    var text = Regex.Replace(withoutScripts, @"(?s)<[^>]+>", " ");
    text = System.Net.WebUtility.HtmlDecode(text);
    return Regex.Replace(text, @"\s+", " ").Trim();
}

static void ValidateCompoundFile(string outputPath)
{
    var info = new FileInfo(outputPath);
    if (!info.Exists || info.Length < 512)
    {
        throw new InvalidOperationException($"OFT output is missing or too small: {outputPath}");
    }

    var expected = new byte[] { 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
    var actual = File.ReadAllBytes(outputPath).Take(expected.Length).ToArray();
    if (!actual.SequenceEqual(expected))
    {
        throw new InvalidOperationException($"OFT output is not an OLE compound file: {outputPath}");
    }
}

static string ToRepoRelativePath(string repositoryRoot, string path)
{
    var root = Path.GetFullPath(repositoryRoot);
    var fullPath = Path.GetFullPath(path);
    var relativePath = Path.GetRelativePath(root, fullPath);
    return relativePath.Replace(Path.DirectorySeparatorChar, '/');
}

static JsonSerializerOptions CreateJsonOptions() => new()
{
    WriteIndented = true,
    PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
};

internal sealed record CliOptions
{
    public string? Folder { get; private init; }
    public string? HtmlPath { get; private init; }
    public string? RepositoryRoot { get; private init; }
    public string? Subject { get; private init; }
    public string SenderAddress { get; private init; } = "no-reply@example.com";
    public string SenderName { get; private init; } = "eDM";

    public static CliOptions Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            if (!arg.StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException($"Unexpected argument: {arg}");
            }

            var key = arg[2..];
            if (i + 1 >= args.Length)
            {
                throw new ArgumentException($"Missing value for argument: {arg}");
            }

            values[key] = args[++i];
        }

        values.TryGetValue("folder", out var folder);
        values.TryGetValue("html", out var htmlPath);
        values.TryGetValue("repository-root", out var repositoryRoot);
        values.TryGetValue("subject", out var subject);
        values.TryGetValue("sender-address", out var senderAddress);
        values.TryGetValue("sender-name", out var senderName);

        return new CliOptions
        {
            Folder = folder,
            HtmlPath = htmlPath,
            RepositoryRoot = repositoryRoot,
            Subject = subject,
            SenderAddress = string.IsNullOrWhiteSpace(senderAddress) ? "no-reply@example.com" : senderAddress,
            SenderName = string.IsNullOrWhiteSpace(senderName) ? "eDM" : senderName
        };
    }
}

internal sealed record ResourceParts(string Path, string Suffix);
internal sealed record InlineAttachment(string OriginalSource, string FullPath, string ContentId);

internal sealed class BuildManifest
{
    public DateTimeOffset GeneratedAt { get; set; }
    public string Html { get; set; } = "";
    public string Oft { get; set; } = "";
    public string Subject { get; set; } = "";
    public string Generator { get; set; } = "";
    public bool OutlookDesktopRequired { get; set; }
    public int InlineAttachmentCount { get; set; }
    public List<InlineAttachmentManifest> InlineAttachments { get; set; } = [];
}

internal sealed class InlineAttachmentManifest
{
    public string Source { get; set; } = "";
    public string ContentId { get; set; } = "";
    public string File { get; set; } = "";
}
