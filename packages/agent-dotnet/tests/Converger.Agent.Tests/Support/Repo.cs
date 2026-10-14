namespace Converger.Agent.Tests.Support;

/// <summary>Locates the shared fixtures and schemas of the repository.</summary>
internal static class Repo
{
    private static readonly Lazy<string> RootDir = new(FindRoot);

    /// <summary>The repository root (the folder holding packages/ and priv/).</summary>
    public static string Root => RootDir.Value;

    /// <summary>packages/conformance/agent.json.</summary>
    public static string AgentFixture => Path.Combine(Root, "packages", "conformance", "agent.json");

    /// <summary>priv/protocol/v1.</summary>
    public static string SchemaRoot => Path.Combine(Root, "priv", "protocol", "v1");

    private static string FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "packages", "conformance", "agent.json")))
            {
                return dir.FullName;
            }
        }
        throw new InvalidOperationException("packages/conformance/agent.json not found above " + AppContext.BaseDirectory);
    }
}
