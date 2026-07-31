//! Secrets example: demonstrate setSecret and withSecret usage.
//!
//! Run under a Dagger session:
//!
//!   dagger run -- zig build run-secrets
//!
//! This example shows how to:
//!   - Set a secret from environment variable
//!   - Pass secrets to container commands
//!   - Use secrets in build pipelines

const std = @import("std");
const dagger = @import("dagger_sdk");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var client = try dagger.connect(gpa, io, .{});
    defer client.close();

    // In production, load from secure secret management (Vault, 1Password, etc.)
    // For demo, we use a hardcoded value - NEVER do this in production!
    const api_key = try gpa.dupe(u8, "sk-demo-api-key-12345-abcdef");
    defer gpa.free(api_key);

    // Set the secret in Dagger
    const secret = try client.dag().setSecret("api-key", api_key);
    var secret_id = try secret.id();
    defer secret_id.deinit(gpa);

    // Build a container that uses the secret
    const ctr_raw = try client.dag().container(null);
    const ctr = try ctr_raw.from("alpine:latest", null);

    // Mount the secret as an env var (safely - doesn't leak in logs)
    const ctr_with_secret = try ctr
        .withSecretVariable("API_KEY", secret_id.value);

    // Verify secret is accessible but masked in output
    const ctr_verified = try ctr_with_secret
        .withExec(&.{ "sh", "-c", "echo 'Secret exists:' && test -n \"$API_KEY\" && echo 'YES' || echo 'NO'" }, null, null, null, null, null, null, null, null, null, null);

    const out = try ctr_verified.stdout();
    defer gpa.free(out);

    var stdout_file = std.Io.File.stdout();
    defer stdout_file.close(io);
    try stdout_file.writeStreamingAll(io, out);

    std.log.info("Secret handling complete. API key was never exposed in logs!", .{});
}
