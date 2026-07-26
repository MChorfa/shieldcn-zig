# GitHub Provider

The GitHub provider fetches repository metrics from the GitHub API and renders them as badges.

## Endpoints

All endpoints follow the pattern: `/github/{metric}/{owner}/{repo}.svg`

### Available Metrics

| Metric         | Description                 | API Endpoint                            |
| -------------- | --------------------------- | --------------------------------------- |
| `stars`        | Repository stargazers count | `/repos/{owner}/{repo}`                 |
| `forks`        | Repository forks count      | `/repos/{owner}/{repo}`                 |
| `issues`       | Open issues count           | `/repos/{owner}/{repo}`                 |
| `pulls`        | Open pull requests count    | `/repos/{owner}/{repo}`                 |
| `release`      | Latest release tag          | `/repos/{owner}/{repo}/releases/latest` |
| `commits`      | Last commit date            | `/repos/{owner}/{repo}`                 |
| `contributors` | Contributor count           | `/repos/{owner}/{repo}/contributors`    |

## Usage

### Stars Badge

```bash
# Basic stars badge
curl http://localhost:5335/github/stars/ziglang/zig.svg

# With dark theme
curl http://localhost:5335/github/stars/ziglang/zig.svg?mode=dark

# With custom label
curl http://localhost:5335/github/stars/ziglang/zig.svg?label=stargazers

# With branded variant
curl http://localhost:5335/github/stars/ziglang/zig.svg?variant=branded
```

**Markdown Example:**

```markdown
![Stars](http://your-server.com/github/stars/ziglang/zig.svg)
```

### Forks Badge

```bash
# Basic forks badge
curl http://localhost:5335/github/forks/torvalds/linux.svg

# With custom color
curl http://localhost:5335/github/forks/torvalds/linux.svg?color=3b82f6

# With outline variant
curl http://localhost:5335/github/forks/torvalds/linux.svg?variant=outline
```

**Markdown Example:**

```markdown
![Forks](http://your-server.com/github/forks/torvalds/linux.svg)
```

### Issues Badge

```bash
# Basic issues badge
curl http://localhost:5335/github/issues/facebook/react.svg

# Dark theme with custom label
curl http://localhost:5335/github/issues/facebook/react.svg?mode=dark&label=open%20issues
```

**Markdown Example:**

```markdown
![Issues](http://your-server.com/github/issues/facebook/react.svg)
```

### Pull Requests Badge

```bash
# Basic PRs badge
curl http://localhost:5335/github/pulls/microsoft/vscode.svg

# Branded variant
curl http://localhost:5335/github/pulls/microsoft/vscode.svg?variant=branded
```

**Markdown Example:**

```markdown
![Pull Requests](http://your-server.com/github/pulls/microsoft/vscode.svg)
```

### Release Badge

```bash
# Latest release tag
curl http://localhost:5335/github/release/ziglang/zig.svg

# With custom label
curl http://localhost:5335/github/release/ziglang/zig.svg?label=version
```

**Markdown Example:**

```markdown
![Release](http://your-server.com/github/release/ziglang/zig.svg)
```

### Commits Badge

```bash
# Last commit date
curl http://localhost:5335/github/commits/ziglang/zig.svg

# With custom label
curl http://localhost:5335/github/commits/ziglang/zig.svg?label=last%20commit
```

**Markdown Example:**

```markdown
![Commits](http://your-server.com/github/commits/ziglang/zig.svg)
```

### Contributors Badge

```bash
# Contributor count
curl http://localhost:5335/github/contributors/ziglang/zig.svg

# With branded variant
curl http://localhost:5335/github/contributors/ziglang/zig.svg?variant=branded
```

**Markdown Example:**

```markdown
![Contributors](http://your-server.com/github/contributors/ziglang/zig.svg)
```

## Query Parameters

All GitHub badges support the following query parameters (keys are case-insensitive):

| Param         | Values                                                    | Default       |
| ------------- | --------------------------------------------------------- | ------------- |
| `variant`     | `default`, `secondary`, `outline`, `ghost`, `destructive`, `branded` | `default`     |
| `size`        | `xs`, `sm`, `default`, `lg`                               | `sm`          |
| `mode`        | `dark`, `light`                                           | `dark`        |
| `theme`       | `dark`, `light`, `high-contrast`, `enterprise`, `custom`  | `dark`        |
| `font`        | `inter`, `geist`, `geist-mono`                            | `inter`       |
| `color`       | named color or `#hex`                                     | from path     |
| `labelColor`  | named color or `#hex`                                     | theme         |
| `valueColor`  | named color or `#hex`                                     | auto-contrast |
| `labelTextColor` | named color or `#hex`                                  | theme         |
| `label`       | string                                                    | from metric   |
| `split`       | `true`, `false`                                           | `true` when color present |
| `statusDot`   | `true`, `false`                                           | `false`       |
| `gradient`    | color name                                                | none          |
| `labelOpacity`| float `0`–`1`                                             | `0.85`        |

## Authentication

The GitHub provider uses a token pool for authentication. Configure GitHub tokens via environment variables:

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

Multiple tokens can be supplied; the pool round-robins across tokens with remaining quota.

Tokens are used to:

- Increase API rate limits (5000 requests/hour vs 60/hour)
- Access private repositories (if configured)

## Caching

GitHub API responses are cached for 1 hour (3600 seconds) to reduce API load.

## Rate Limiting

Without authentication: 60 requests/hour  
With authentication: 5000 requests/hour

If rate limits are exceeded, the badge will show an error state.

## Notes

- The `commits` badge shows the full ISO 8601 date string.
- The `release` badge shows the tag name.
- The `contributors` badge counts the total number of contributors.
