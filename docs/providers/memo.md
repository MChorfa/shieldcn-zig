# Memo Badges Provider

Memo badges let you store custom badge data server-side and retrieve it later. This is useful for build status, coverage numbers, or any dynamic metric you control.

## API

### GET `/memo/:key.svg`

Retrieve a memo badge by key.

**Query Parameters:**

| Param        | Values                                                   | Default       |
| ------------ | -------------------------------------------------------- | ------------- |
| `variant`    | `default`, `secondary`, `outline`, `ghost`, `destructive`, `branded` | `default`     |
| `size`       | `xs`, `sm`, `default`, `lg`                              | `sm`          |
| `mode`       | `dark`, `light`                                          | `dark`        |
| `theme`      | `dark`, `light`, `high-contrast`, `enterprise`, `custom` | `dark`        |
| `color`      | named color or `#hex`                                    | from stored data |
| `labelColor` | named color or `#hex`                                    | theme         |
| `valueColor` | named color or `#hex`                                    | auto-contrast |
| `label`      | string                                                   | from stored data |

**Example:**

```bash
curl http://localhost:5335/memo/mykey.svg?mode=dark
```

### PUT `/memo/:key`

Create or update a memo badge.

**Request Body:**

```json
{
  "label": "custom label",
  "value": "custom value",
  "color": "22c55e"
}
```

**Example:**

```bash
curl -X PUT http://localhost:5335/memo/mykey \
  -H "Content-Type: application/json" \
  -d '{"label":"build","value":"passing","color":"22c55e"}'
```

**Response:**

```json
{"status":"ok"}
```

## Use Cases

### Build Status

```bash
# Update build status
curl -X PUT http://localhost:5335/memo/build-status \
  -H "Content-Type: application/json" \
  -d '{"label":"build","value":"passing","color":"22c55e"}'

# Display in README
![Build Status](http://your-server.com/memo/build-status.svg)
```

### Custom Metrics

```bash
# Update custom metric
curl -X PUT http://localhost:5335/memo/coverage \
  -H "Content-Type: application/json" \
  -d '{"label":"coverage","value":"87%","color":"3b82f6"}'

# Display with dark theme
![Coverage](http://your-server.com/memo/coverage.svg?mode=dark)
```

### Status Indicators

```bash
# Update status
curl -X PUT http://localhost:5335/memo/status \
  -H "Content-Type: application/json" \
  -d '{"label":"status","value":"operational","color":"22c55e"}'

# Display with custom colors
![Status](http://your-server.com/memo/status.svg?labelColor=1f2937&valueColor=22c55e)
```

## Storage

Memo badges are stored in memory by default. SQLite-backed persistence is planned.

## Notes

- Memo badges are server-specific unless a shared store is configured.
- Use unique keys to avoid conflicts.
- The `color` parameter is optional; if not provided, the badge uses the default theme colors.
