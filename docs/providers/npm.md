# npm Provider

The npm provider fetches package metadata from the npm registry and renders it as a badge.

## Endpoints

| Endpoint                         | Metric      | Description                          |
| -------------------------------- | ----------- | ------------------------------------ |
| `/npm/:package.svg`              | `version`   | Latest version (default)             |
| `/npm/version/:package.svg`      | `version`   | Latest version, optionally with tag  |
| `/npm/downloads/:package.svg`    | `downloads` | Downloads for the chosen period      |
| `/npm/license/:package.svg`      | `license`   | Package license from `package.json`  |

For scoped packages, encode the slash as `%2f`:

```bash
curl http://localhost:5335/npm/version/@types%2fnode.svg
```

## Usage

### Version Badge

```bash
# Latest version (default)
curl http://localhost:5335/npm/react.svg

# Specific dist tag
curl http://localhost:5335/npm/react.svg?tag=beta

# With branded variant
curl http://localhost:5335/npm/react.svg?variant=branded
```

### Downloads Badge

```bash
# Downloads in the last month (default)
curl http://localhost:5335/npm/downloads/react.svg

# Downloads in the last week
curl http://localhost:5335/npm/downloads/react.svg?period=last-week

# Downloads in the last year
curl http://localhost:5335/npm/downloads/react.svg?period=last-year
```

### License Badge

```bash
curl http://localhost:5335/npm/license/react.svg
```

## Query Parameters

| Param        | Values                                                   | Default       |
| ------------ | -------------------------------------------------------- | ------------- |
| `variant`    | `default`, `secondary`, `outline`, `ghost`, `destructive`, `branded` | `default`     |
| `size`       | `xs`, `sm`, `default`, `lg`                              | `sm`          |
| `mode`       | `dark`, `light`                                          | `dark`        |
| `theme`      | `dark`, `light`, `high-contrast`, `enterprise`, `custom` | `dark`        |
| `color`      | named color or `#hex`                                    | from path     |
| `labelColor` | named color or `#hex`                                    | theme         |
| `valueColor` | named color or `#hex`                                    | auto-contrast |
| `label`      | string                                                   | from provider |
| `tag`        | npm dist tag (for `version`)                             | `latest`      |
| `period`     | `last-week`, `last-month`, `last-year` (for `downloads`) | `last-month`  |

## Caching

npm API responses are cached for 1 hour (3600 seconds).

## Rate Limiting

The npm registry does not require authentication for public package metadata. Rate limits are generous; if they are exceeded, the badge will show an error state.
