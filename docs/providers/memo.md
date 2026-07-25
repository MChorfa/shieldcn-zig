# Memo Badges Provider

Memo badges allow you to store custom badge data server-side and retrieve it later. This is useful for displaying custom metrics, status indicators, or any dynamic data you want to control.

## API

### GET `/memo/:key.svg`

Retrieve a memo badge by key.

**Query Parameters:**
- `variant` - Badge variant: `flat`, `flat-square`, `for-the-badge`, `plastic` (default: `flat`)
- `theme` - Color theme: `light`, `dark` (default: `light`)
- `color` - Custom badge color (hex code)
- `label` - Custom label text
- `label_color` - Custom label color (hex code)
- `value_color` - Custom value color (hex code)

**Example:**
```bash
curl http://localhost:5335/memo/mykey.svg?theme=dark
```

### PUT `/memo/:key`

Create or update a memo badge.

**Request Body:**
```json
{
  "label": "custom label",
  "value": "custom value",
  "color": "22c55e"  // optional hex color
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
![Coverage](http://your-server.com/memo/coverage.svg?theme=dark)
```

### Status Indicators
```bash
# Update status
curl -X PUT http://localhost:5335/memo/status \
  -H "Content-Type: application/json" \
  -d '{"label":"status","value":"operational","color":"22c55e"}'

# Display with custom colors
![Status](http://your-server.com/memo/status.svg?label_color=1f2937&value_color=22c55e)
```

## Storage

Memo badges are stored in-memory using SQLite. Data is persisted across server restarts if the database file is configured.

## Notes

- Memo badges are server-specific - they don't persist across different server instances
- Use unique keys to avoid conflicts
- The color parameter is optional - if not provided, the badge uses the default theme colors
