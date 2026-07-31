//! GraphQL introspection query + response schema.
//!
//! Sent to the Dagger engine once at codegen time; the result is a complete
//! description of every type, field, arg, and enum in the engine's API.
//! We then walk that description and emit Zig code.

const std = @import("std");

pub const query =
    \\query IntrospectionQuery {
    \\  __schema {
    \\    queryType { name }
    \\    types {
    \\      ...FullType
    \\    }
    \\  }
    \\}
    \\fragment FullType on __Type {
    \\  kind
    \\  name
    \\  description
    \\  fields(includeDeprecated: true) {
    \\    name
    \\    description
    \\    args {
    \\      ...InputValue
    \\    }
    \\    type {
    \\      ...TypeRef
    \\    }
    \\    isDeprecated
    \\    deprecationReason
    \\  }
    \\  inputFields {
    \\    ...InputValue
    \\  }
    \\  interfaces {
    \\    ...TypeRef
    \\  }
    \\  enumValues(includeDeprecated: true) {
    \\    name
    \\    description
    \\    isDeprecated
    \\    deprecationReason
    \\  }
    \\  possibleTypes {
    \\    ...TypeRef
    \\  }
    \\}
    \\fragment InputValue on __InputValue {
    \\  name
    \\  description
    \\  type { ...TypeRef }
    \\  defaultValue
    \\}
    \\fragment TypeRef on __Type {
    \\  kind
    \\  name
    \\  ofType {
    \\    kind
    \\    name
    \\    ofType {
    \\      kind
    \\      name
    \\      ofType {
    \\        kind
    \\        name
    \\        ofType {
    \\          kind
    \\          name
    \\          ofType {
    \\            kind
    \\            name
    \\            ofType {
    \\              kind
    \\              name
    \\              ofType {
    \\                kind
    \\                name
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

pub const TypeKind = enum {
    SCALAR,
    OBJECT,
    INTERFACE,
    UNION,
    ENUM,
    INPUT_OBJECT,
    LIST,
    NON_NULL,
};

/// A type reference in the schema. `kind` tells you what `name`/`of_type` mean:
///   - SCALAR, OBJECT, ENUM, INPUT_OBJECT: `name` is set, `of_type` is null
///   - NON_NULL, LIST: `name` is null, `of_type` holds the wrapped type
pub const TypeRef = struct {
    kind: []const u8,
    name: ?[]const u8 = null,
    of_type: ?*TypeRef = null,
};

pub const InputValue = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    type: TypeRef,
    default_value: ?[]const u8 = null,
};

pub const Field = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    args: []const InputValue = &.{},
    type: TypeRef,
    is_deprecated: bool = false,
    deprecation_reason: ?[]const u8 = null,
};

pub const EnumValue = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    is_deprecated: bool = false,
    deprecation_reason: ?[]const u8 = null,
};

pub const FullType = struct {
    kind: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    fields: ?[]const Field = null,
    input_fields: ?[]const InputValue = null,
    enum_values: ?[]const EnumValue = null,
};

pub const Schema = struct {
    types: []const FullType,
};

pub fn parse(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(Schema) {
    // Body is `{"data":{"__schema":{"types":[...]}}}` — walk down before
    // handing to the parser so we can use a tidy struct shape.
    const Outer = struct {
        data: struct {
            __schema: Schema,
        },
    };
    const p = try std.json.parseFromSlice(Outer, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    // Re-wrap so the caller gets a Schema directly. We leak the Outer arena
    // into the Parsed wrapper — it stays alive until the caller deinit()s.
    return .{
        .arena = p.arena,
        .value = p.value.data.__schema,
    };
}
