---
name: rust-mcp-server-generator
description: 'Generates a complete Rust MCP server project with tools, prompts, resources, and tests using rmcp 3.4.0, the official Model Context Protocol Rust SDK. Use when scaffolding new MCP servers in Rust, upgrading from rmcp 0.x/1.x/2.x templates, adding Streamable HTTP transport, or supporting multiple MCP protocol versions (2026-07-28, 2025-11-25, 2025-06-18, 2024-11-05) from one server.'
---

# Rust MCP Server Generator

Generate a complete, production-ready Rust Model Context Protocol (MCP) server using rmcp 3.4.0, the official Rust SDK at https://github.com/modelcontextprotocol/rust-sdk.

## Key Facts (rmcp 3.4.0)

- Edition 2024, minimum Rust 1.88.
- `ServerConfig` is a type alias for `InitializeResult`; `ServerInfo` is a deprecated alias. `get_info()` returns `ServerConfig`.
- `ProtocolVersion` supports four MCP versions out of the box: `V_2026_07_28`, `V_2025_11_25` (`LATEST`), `V_2025_06_18` (`STANDARD_HEADERS`), and `V_2024_11_05`. `ProtocolVersion::KNOWN_VERSIONS` contains all four.
- The default `ServerHandler::supported_protocol_versions()` already returns `Cow::Borrowed(ProtocolVersion::KNOWN_VERSIONS)` — one server serves every known protocol version and negotiates per client. Override it only to restrict versions.
- `RequestContext` has no `Default` impl — never use `RequestContext::default()` in tests; construct services via `serve()` instead.
- `RunningService` must be awaited (`waiting()`) or cancelled (`cancel()`); dropping it leaks the task and logs a warning.

## Requirements

- Rust 1.88+ (edition 2024)
- Cargo
- Basic understanding of async Rust and MCP concepts

## Project Structure

The generated project follows this structure:

```
my-mcp-server/
├── Cargo.toml
├── README.md
├── src/
│   ├── main.rs           # Entry point with server setup
│   ├── handler.rs        # MCP handler implementation (tools, prompts, resources)
│   ├── tools/            # Tool implementations
│   │   └── mod.rs
│   ├── prompts/          # Prompt implementations
│   │   └── mod.rs
│   └── resources/        # Resource implementations
│       └── mod.rs
└── tests/                # Integration tests
    └── server_tests.rs
```

## Generated Project Files

### Cargo.toml

```toml
[package]
name = "my-mcp-server"
version = "0.1.0"
edition = "2024"        # rmcp 3.4.0 requires edition 2024 (rust 1.88+)

[dependencies]
# Exact pins: MCP servers are long-lived stdio processes; reproducible builds
# matter more than semver drift. Bump deliberately after reading changelogs.
rmcp = { version = "=3.4.0", features = ["server", "macros", "schemars"] } # official MCP Rust SDK; 3.4.0 adds 2026-07-28 spec support and tasks extension
rmcp-macros = "=3.4.0"  # keep in lockstep with rmcp; #[tool], #[tool_router], #[prompt] macros
tokio = { version = "=1.53.1", features = ["full"] }  # async runtime; full features for process/time/signal
serde = { version = "=1.0.229", features = ["derive"] }  # serialization
serde_json = "=1.0.151"  # JSON for MCP payloads
schemars = "=1.2.2"     # JSON Schema generation for tool parameters (1.x, not 0.8)
anyhow = "=1.0.104"     # application-level errors
async-trait = "=0.1.92" # ServerHandler trait methods
tracing = "=0.1.44"     # structured logging
tracing-subscriber = { version = "=0.3.23", features = ["env-filter"] }  # log output (stderr only — stdout is the MCP channel)
base64 = "=0.23.1"      # resource blob encoding (0.23 API: base64::prelude::*)

# Optional: Streamable HTTP transport (remote servers).
# Verify the exact feature name in rmcp 3.4.0's Cargo.toml before enabling;
# candidate: features = ["transport-streamable-http-server"]
# axum = "=0.8.9"              # HTTP framework for Streamable HTTP transport
# tower-http = { version = "=0.7.1", features = ["cors"] }  # CORS middleware

[dev-dependencies]
tokio-test = "=0.4.5"   # async test utilities
```

### src/main.rs

```rust
use anyhow::Result;
use rmcp::ServiceExt;
use tracing_subscriber::{EnvFilter, fmt};

mod handler;
mod prompts;
mod resources;
mod tools;

use handler::MyMcpServer;

#[tokio::main]
async fn main() -> Result<()> {
    // Logging MUST go to stderr — stdout carries the MCP JSON-RPC stream.
    fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();

    let server = MyMcpServer::new();

    // Stdio transport for local clients (Claude Desktop, Copilot, etc.)
    let service = server
        .serve(rmcp::transport::stdio())
        .await
        .inspect_err(|e| tracing::error!("failed to start server: {e}"))?;

    // Serve until the client disconnects. Never drop a RunningService.
    service.waiting().await?;
    Ok(())
}
```

### src/handler.rs

```rust
use std::borrow::Cow;

use rmcp::{
    ServerHandler, ServerConfig,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::*,
    service::{RequestContext, RoleServer},
    tool, tool_handler, tool_router,
    ErrorData as McpError,
};

use crate::prompts;
use crate::resources;
use crate::tools::{self, ExampleParams};

#[derive(Clone)]
pub struct MyMcpServer {
    tool_router: ToolRouter<Self>,
}

impl MyMcpServer {
    pub fn new() -> Self {
        Self {
            tool_router: Self::tool_router(),
        }
    }
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

#[tool_router]
impl MyMcpServer {
    /// Example tool: echo a message back with a greeting.
    #[tool(description = "Greet someone by name")]
    async fn greet(
        &self,
        Parameters(params): Parameters<ExampleParams>,
    ) -> Result<CallToolResult, McpError> {
        let text = tools::greet(&params.name).await?;
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }
}

// ---------------------------------------------------------------------------
// ServerHandler
// ---------------------------------------------------------------------------

#[tool_handler]
#[rmcp::prompt_handler]
impl ServerHandler for MyMcpServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(
            ServerCapabilities::builder()
                .enable_tools()
                .enable_prompts()
                .enable_resources()
                .build(),
        )
        .with_server_info(Implementation {
            name: "my-mcp-server".into(),
            version: env!("CARGO_PKG_VERSION").into(),
            ..Default::default()
        })
        .with_instructions("A template MCP server with tools, prompts, and resources.".into())
    }

    /// Serve every MCP protocol version rmcp 3.4.0 knows about:
    /// 2026-07-28, 2025-11-25 (LATEST), 2025-06-18, and 2024-11-05.
    /// rmcp negotiates the highest mutually supported version per client.
    ///
    /// NOTE: this matches the SDK default; shown explicitly so you can
    /// restrict versions (e.g. drop 2024-11-05) in one obvious place.
    fn supported_protocol_versions(&self) -> Cow<'static, [ProtocolVersion]> {
        Cow::Borrowed(ProtocolVersion::KNOWN_VERSIONS)
    }

    // Prompts
    async fn list_prompts(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListPromptsResult, McpError> {
        prompts::list_prompts().await
    }

    async fn get_prompt(
        &self,
        request: GetPromptRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<GetPromptResult, McpError> {
        prompts::get_prompt(request, context).await
    }

    // Resources
    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, McpError> {
        resources::list_resources().await
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResult, McpError> {
        resources::read_resource(request, context).await
    }
}
```

### src/tools/mod.rs

```rust
use rmcp::{ErrorData as McpError, model::ErrorCode};
use serde::Deserialize;
use schemars::JsonSchema;

/// Parameters for the `greet` tool. Deriving JsonSchema lets rmcp
/// advertise the input schema to clients automatically.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct ExampleParams {
    /// Name of the person to greet.
    pub name: String,
}

pub async fn greet(name: &str) -> Result<String, McpError> {
    if name.trim().is_empty() {
        return Err(McpError::new(
            ErrorCode::INVALID_PARAMS,
            "name must not be empty".into(),
            None,
        ));
    }
    Ok(format!("Hello, {name}!"))
}
```

### src/prompts/mod.rs

Prompts can be defined either with the `#[prompt]` macro family (preferred for
static prompts) or as plain async functions behind `list_prompts`/`get_prompt`
(shown in handler.rs). Macro form:

```rust
use rmcp::{
    ErrorData as McpError,
    handler::server::wrapper::Parameters,
    model::*,
    prompt, prompt_handler, prompt_router,
    service::{RequestContext, RoleServer},
};
use serde::Deserialize;
use schemars::JsonSchema;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SummarizeArgs {
    /// Text to summarize.
    pub text: String,
}

// On the server struct:
#[prompt_router]
impl MyMcpServer {
    /// Summarize a piece of text.
    #[prompt(name = "summarize", description = "Summarize the given text")]
    async fn summarize(
        &self,
        Parameters(args): Parameters<SummarizeArgs>,
    ) -> Result<GetPromptResult, McpError> {
        Ok(GetPromptResult {
            description: Some("Summarize text".into()),
            messages: vec![PromptMessage::new_text(
                PromptMessageRole::User,
                format!("Summarize this concisely:\n\n{}", args.text),
            )],
        })
    }
}
```

Function-based fallback (`list_prompts` / `get_prompt`) for dynamic catalogs:

```rust
use rmcp::{ErrorData as McpError, model::*, service::{RequestContext, RoleServer}};

pub async fn list_prompts() -> Result<ListPromptsResult, McpError> {
    Ok(ListPromptsResult {
        prompts: vec![Prompt::new(
            "summarize",
            Some("Summarize the given text".into()),
            Some(vec![PromptArgument {
                name: "text".into(),
                description: Some("Text to summarize".into()),
                required: Some(true),
                ..Default::default()
            }]),
        )],
        next_cursor: None,
        meta: None,
    })
}

pub async fn get_prompt(
    request: GetPromptRequestParams,
    _context: RequestContext<RoleServer>,
) -> Result<GetPromptResult, McpError> {
    match request.name.as_str() {
        "summarize" => {
            let text = request
                .arguments
                .as_ref()
                .and_then(|a| a.get("text"))
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            Ok(GetPromptResult {
                description: Some("Summarize text".into()),
                messages: vec![PromptMessage::new_text(
                    PromptMessageRole::User,
                    format!("Summarize this concisely:\n\n{text}"),
                )],
            })
        }
        _ => Err(McpError::invalid_params(
            format!("unknown prompt: {}", request.name),
            None,
        )),
    }
}
```

### src/resources/mod.rs

```rust
use rmcp::{ErrorData as McpError, model::*, service::{RequestContext, RoleServer}};

pub async fn list_resources() -> Result<ListResourcesResult, McpError> {
    Ok(ListResourcesResult {
        resources: vec![
            RawResource {
                uri: "example://data/info".into(),
                name: "Server info".into(),
                description: Some("Static metadata about this server".into()),
                mime_type: Some("text/plain".into()),
                ..Default::default()
            }
            .no_annotation(),
        ],
        next_cursor: None,
        meta: None,
    })
}

pub async fn read_resource(
    request: ReadResourceRequestParams,
    _context: RequestContext<RoleServer>,
) -> Result<ReadResourceResult, McpError> {
    match request.uri.as_str() {
        "example://data/info" => Ok(ReadResourceResult {
            contents: vec![ResourceContents::text(
                "my-mcp-server — built with rmcp 3.4.0",
                request.uri.clone(),
            )],
        }),
        _ => Err(McpError::resource_not_found(
            format!("unknown resource: {}", request.uri),
            None,
        )),
    }
}
```

For binary content, encode with base64 0.23:

```rust
use base64::{Engine, prelude::BASE64_STANDARD};

let blob = BASE64_STANDARD.encode(&bytes);
// then ResourceContents::blob(blob, uri) with an appropriate mime_type
```

### tests/server_tests.rs

```rust
use my_mcp_server::handler::MyMcpServer;
use rmcp::{ServerHandler, handler::server::router::tool::ToolCallContext};

// NOTE: RequestContext has no Default impl. Exercise handler behavior
// through tool_router / get_info / supported_protocol_versions, or spin
// up an in-memory service pair with rmcp::transport::Transport channels.

#[tokio::test]
async fn lists_tools() {
    let server = MyMcpServer::new();
    let tools = server.tool_router().list_all();
    assert!(tools.iter().any(|t| t.name == "greet"));
}

#[tokio::test]
async fn advertises_capabilities() {
    let server = MyMcpServer::new();
    let info = server.get_info();
    assert!(info.capabilities.tools.is_some());
    assert!(info.capabilities.prompts.is_some());
    assert!(info.capabilities.resources.is_some());
}

#[tokio::test]
async fn serves_all_protocol_versions() {
    let server = MyMcpServer::new();
    let versions = server.supported_protocol_versions();
    assert!(versions.contains(&rmcp::model::ProtocolVersion::V_2026_07_28));
    assert!(versions.contains(&rmcp::model::ProtocolVersion::V_2025_11_25));
    assert!(versions.contains(&rmcp::model::ProtocolVersion::V_2025_06_18));
    assert!(versions.contains(&rmcp::model::ProtocolVersion::V_2024_11_05));
}
```

### Optional: Streamable HTTP transport

For remote servers, use the tower-based Streamable HTTP transport. Verify
exact type/feature names against rmcp 3.4.0's `transport-streamable-http-server`
docs before shipping:

```rust
// UNVERIFIED — check rmcp 3.4.0 docs for the exact service constructor.
use rmcp::transport::streamable_http_server::{
    StreamableHttpServerConfig, StreamableHttpService,
};

let service = StreamableHttpService::new(
    || Ok(MyMcpServer::new()),
    Default::default(),
    StreamableHttpServerConfig::default(),
);
// Mount `service` on an axum 0.8 router and serve with tokio.
```

### README.md template

````markdown
# my-mcp-server

A Model Context Protocol server built with [rmcp](https://github.com/modelcontextprotocol/rust-sdk) 3.4.0.

Supports MCP protocol versions **2026-07-28**, **2025-11-25**, **2025-06-18**, and **2024-11-05** with automatic version negotiation.

## Features

- Tools: `greet`
- Prompts: `summarize`
- Resources: `example://data/info`

## Build & Run

```bash
cargo build
cargo run          # stdio transport
cargo test
```

## Client configuration (stdio)

```json
{
  "mcpServers": {
    "my-mcp-server": {
      "command": "/path/to/target/debug/my-mcp-server"
    }
  }
}
```

## Logging

Logs go to **stderr** only; stdout is reserved for the MCP JSON-RPC stream.
Set `RUST_LOG=debug` for verbose output.
````

## Implementation Guidelines

1. **Never write to stdout** in server code — it corrupts the JSON-RPC stream. Use `tracing` with a stderr writer.
2. **Keep `rmcp` and `rmcp-macros` versions in lockstep.**
3. **Await or cancel every `RunningService`** — dropping leaks the task.
4. **Derive `JsonSchema` on all parameter structs** so clients get accurate input schemas.
5. **Return `McpError` (`ErrorData`) with precise codes** (`INVALID_PARAMS`, `RESOURCE_NOT_FOUND`) instead of panicking.
6. **Prefer `#[tool]`/`#[prompt]` macros**; use manual `list_*`/`read_*` handlers only for dynamic catalogs.
7. **Serve all known protocol versions by default**; restrict `supported_protocol_versions()` only with a documented reason.
8. **Do not invent OAuth/stateless-HTTP APIs** — if a transport detail isn't verified against rmcp 3.4.0 source or docs.rs, mark it unverified or omit it.

## Tool Implementation Pattern

```rust
#[tool_router]
impl MyMcpServer {
    /// Divide two numbers safely.
    #[tool(description = "Divide a by b")]
    async fn divide(
        &self,
        Parameters(p): Parameters<DivideParams>,
    ) -> Result<CallToolResult, McpError> {
        if p.b == 0.0 {
            return Err(McpError::invalid_params("b must be non-zero".into(), None));
        }
        Ok(CallToolResult::success(vec![Content::text(
            format!("{}", p.a / p.b),
        )]))
    }
}
```

Combine `#[tool_router(server_handler)]` when the server exposes **only** tools;
otherwise use separate `#[tool_handler]` + `#[prompt_handler]` attributes on the
`ServerHandler` impl as shown in handler.rs.
