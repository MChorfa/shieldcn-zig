# GitHub Provider

The GitHub provider fetches repository metrics from the GitHub API and displays them as badges.

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
curl http://localhost:5335/github/ziglang/zig/stars.svg

# With dark theme
curl http://localhost:5335/github/ziglang/zig/stars.svg?theme=dark

# With custom label
curl http://localhost:5335/github/ziglang/zig/stars.svg?label=stargazers

# With branded variant
curl http://localhost:5335/github/ziglang/zig/stars.svg?variant=branded
```

**BadgeSandbox Example:**

```markdown
![Stars](http://your-server.com/github/ziglang/zig/stars.svg)
```

### Forks Badge

```bash
# Basic forks badge
curl http://localhost:5335/github/torvalds/linux/forks.svg

# With custom colors
curl http://localhost:5335/github/torvalds/linux/forks.svg?color=3b82f6

# Flat-square variant
curl http://localhost:5335/github/torvalds/linux/forks.svg?variant=flat-square
```

**BadgeSandbox Example:**

```markdown
![Forks](http://your-server.com/github/torvalds/linux/forks.svg)
```

### Issues Badge

```bash
# Basic issues badge
curl http://localhost:5335/github/facebook/react/issues.svg

# Dark theme with custom label
curl http://localhost:5335/github/facebook/react/issues.svg?theme=dark&label=open%20issues
```

**BadgeSandbox Example:**

```markdown
![Issues](http://your-server.com/github/facebook/react/issues.svg)
```

### Pull Requests Badge

```bash
# Basic PRs badge
curl http://localhost:5335/github/microsoft/vscode/pulls.svg

# For-the-badge variant
curl http://localhost:5335/github/microsoft/vscode/pulls.svg?variant=for-the-badge
```

**BadgeSandbox Example:**

```markdown
![Pull Requests](http://your-server.com/github/microsoft/vscode/pulls.svg)
```

### Release Badge

```bash
# Latest release tag
curl http://localhost:5335/github/ziglang/zig/release.svg

# With custom label
curl http://localhost:5335/github/ziglang/zig/release.svg?label=version

# Dark theme
curl http://localhost:5335/github/ziglang/zig/release.svg?theme=dark
```

**BadgeSandbox Example:**

```markdown
![Release](http://your-server.com/github/ziglang/zig/release.svg)
```

### Commits Badge

```bash
# Last commit date
curl http://localhost:5335/github/ziglang/zig/commits.svg

# With custom label
curl http://localhost:5335/github/ziglang/zig/commits.svg?label=last%20commit
```

**BadgeSandbox Example:**

```markdown
![Commits](http://your-server.com/github/ziglang/zig/commits.svg)
```

### Contributors Badge

```bash
# Contributor count
curl http://localhost:5335/github/ziglang/zig/contributors.svg

# With branded variant
curl http://localhost:5335/github/ziglang/zig/contributors.svg?variant=branded
```

**BadgeSandbox Example:**

```markdown
![Contributors](http://your-server.com/github/ziglang/zig/contributors.svg)
```

## Query Parameters

All GitHub badges support standard query parameters:

- `variant` - Badge variant: `flat`, `flat-square`, `for-the-badge`, `plastic`, `branded` (default: `flat`)
- `theme` - Color theme: `light`, `dark` (default: `light`)
- `color` - Custom badge color (hex code)
- `label` - Custom label text
- `label_color` - Custom label color (hex code)
- `value_color` - Custom value color (hex code)

## Authentication

The GitHub provider uses a token pool for authentication. Configure GitHub tokens via environment variables:

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

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

- All badges link to the relevant GitHub page (stars → stargazers, forks → network, etc.)
- The `commits` badge shows the full ISO 8601 date string
- The `release` badge shows the tag name and links to the release page
- The `contributors` badge counts the total number of contributors
