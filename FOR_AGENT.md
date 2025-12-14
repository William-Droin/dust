# Dust Project Structure Guide for LLM Agents

## Overview

Dust is a sophisticated AI platform that enables users to interact with LLM agents, access various data sources, and build custom workflows. This guide provides a comprehensive overview of the project structure to help LLM agents understand how to navigate and work with the codebase effectively.

## Project Architecture

### High-Level Structure

```
dust/
├── core/              # Rust backend services
├── front/             # TypeScript frontend (Next.js)
├── connectors/        # Data source connectors
├── cli/               # Command-line interface
├── extension/         # Browser extension
├── sdks/              # Software Development Kits
└── viz/               # Visualization components
```

### Core Components

#### 1. Core (Rust Backend)

**Location:** `core/src/`

The Rust backend handles the heavy lifting of the Dust platform:

- **Providers System**: LLM provider integrations (Anthropic, OpenAI, Mistral, etc.)
- **Data Processing**: Document processing, embedding, search
- **API Services**: Core business logic and data management
- **Performance-Critical Operations**: Tokenization, caching, etc.

**Key Files:**
- `core/src/providers/provider.rs` - Provider registration system
- `core/src/providers/anthropic/` - Anthropic provider implementation
- `core/src/providers/openai/` - OpenAI provider implementation
- `core/src/lib.rs` - Main library exports

#### 2. Frontend (TypeScript/Next.js)

**Location:** `front/`

The frontend is a Next.js application that provides the user interface and API endpoints:

**Key Directories:**
- `front/lib/` - Core business logic and API functions
- `front/pages/api/` - API endpoints
- `front/components/` - React components
- `front/types/` - TypeScript type definitions
- `front/migrations/` - Database migrations

**Key Files:**
- `front/lib/api/assistant/global_agents/` - Global agent system
- `front/types/assistant/assistant.ts` - Agent type definitions
- `front/lib/api/assistant/configuration/agent.ts` - Agent creation logic

#### 3. Data Connectors

**Location:** `connectors/`

Connectors integrate with external data sources:

- **Supported Connectors**: Slack, GitHub, Notion, Google Drive, etc.
- **Functionality**: Data synchronization, indexing, search
- **Architecture**: Modular design for easy addition of new connectors

## Agent System Architecture

### Global Agents vs. Custom Agents

**Global Agents:**
- Pre-defined agents available to all workspaces
- Generated on-the-fly from configuration files
- Include: Dust, Claude, GPT models, Gemini, etc.
- Defined in `GLOBAL_AGENTS_SID` enum

**Custom Agents:**
- Created by users within specific workspaces
- Stored in the database
- Can be based on global agent templates

### Agent Configuration

**Location:** `front/lib/api/assistant/global_agents/configurations/`

Each agent type has its own configuration file:
- `anthropic.ts` - Claude agents
- `openai.ts` - OpenAI/GPT agents
- `google.ts` - Gemini agents
- `mistral.ts` - Mistral agents
- `noop.ts` - Test/debug agent

### Agent Retrieval Flow

1. **Request**: User requests available agents
2. **Filtering**: System applies feature flags and workspace settings
3. **Generation**: Agent configurations are created on-the-fly
4. **Customization**: Workspace-specific settings are applied
5. **Delivery**: Agents are returned to the user interface

## Database Structure

### Key Models

**Agent-Related Models:**
- `AgentConfiguration` - Agent definitions and settings
- `GlobalAgentSettings` - Workspace-specific agent settings
- `AgentUserRelation` - User-agent relationships (favorites)
- `AgentMCPServerConfiguration` - Agent tool configurations

**Conversation Models:**
- `Conversation` - Conversation metadata
- `AgentMessage` - Agent-generated messages
- `UserMessage` - User messages
- `Message` - Message content

**Data Source Models:**
- `DataSource` - Connected data sources
- `DataSourceView` - Data source views and permissions

### Database Initialization

**Location:** `front/admin/db.ts`

The database initialization script:
- Synchronizes all model schemas
- Does NOT seed default data (agents are virtual)
- Sets up table relationships and constraints

## Provider System

### Provider Architecture

**Location:** `core/src/providers/`

The provider system follows a modular architecture:

1. **Provider Interface**: `Provider` trait in `provider.rs`
2. **Individual Implementations**: Each provider implements the trait
3. **Registration**: Providers are registered in the `provider()` function
4. **Usage**: Providers are accessed via the `provider()` function

### Supported Providers

- **Anthropic**: Claude models
- **OpenAI**: GPT models
- **Mistral**: Mistral models
- **Google AI Studio**: Gemini models
- **DeepSeek**: DeepSeek models
- **Fireworks**: Fireworks models
- **Noop**: Test/debug provider

### Provider Features

Each provider implements:
- LLM (Language Model) functionality
- Embedding functionality
- Tokenization
- Model-specific features

## API Structure

### API Endpoints

**Location:** `front/pages/api/`

Key API categories:
- **Assistant APIs**: Agent management and interactions
- **Conversation APIs**: Message handling
- **Data Source APIs**: Data management
- **Workspace APIs**: Workspace administration
- **Provider APIs**: Provider configuration

### API Authentication

**Location:** `front/lib/auth.ts`

- Session-based authentication
- Workspace context management
- Role-based access control
- Internal admin authentication for system operations

## Development Patterns

### TypeScript Patterns

- **SWR Hooks**: Data fetching and caching (`front/lib/swr/`)
- **Resource Pattern**: Database model wrappers (`front/lib/resources/`)
- **Factory Pattern**: Test data generation (`front/tests/utils/`)

### Rust Patterns

- **Trait-Based Design**: Provider system
- **Async/Await**: Throughout the codebase
- **Error Handling**: Comprehensive error types and handling
- **Logging**: Structured logging with OpenTelemetry

### Testing

- **Unit Tests**: Individual function testing
- **Integration Tests**: API endpoint testing
- **Migration Tests**: Database migration testing
- **E2E Tests**: End-to-end workflow testing

## Key Concepts

### Workspaces

- Fundamental organizational unit in Dust
- Each workspace has its own data, agents, and users
- Workspace-specific configurations and settings

### Spaces (Vaults)

- Data containers within workspaces
- Different types: Global, System, Restricted
- Control data access and permissions

### Conversations

- Interaction context between users and agents
- Contain messages, attachments, and metadata
- Support complex workflows and tool usage

### Actions and Tools

- Agents can perform actions using tools
- Tools include: Web search, data queries, API calls
- MCP (Model-Connect-Process) server architecture

## Development Workflow

### Adding New Features

1. **Type Definitions**: Define new types in `front/types/`
2. **API Endpoints**: Create new endpoints in `front/pages/api/`
3. **Business Logic**: Implement logic in `front/lib/`
4. **Database Models**: Add/modify models if needed
5. **UI Components**: Create/update React components
6. **Tests**: Write comprehensive tests

### Adding New Providers

1. **Provider Implementation**: Create in `core/src/providers/`
2. **Register Provider**: Add to `provider()` function
3. **Type Definitions**: Add provider ID to enums
4. **Agent Configurations**: Create agent configs if needed
5. **Tests**: Write provider-specific tests

### Adding New Connectors

1. **Connector Implementation**: Create in `connectors/src/`
2. **Database Models**: Add connector-specific models
3. **API Endpoints**: Create management endpoints
4. **Sync Logic**: Implement data synchronization
5. **Tests**: Write connector tests

## Performance Considerations

- **Caching**: Extensive use of Redis caching
- **Database Optimization**: Indexes, query optimization
- **Async Processing**: Background jobs and workers
- **Rate Limiting**: API rate limiting
- **Error Handling**: Comprehensive error recovery

## Security Considerations

- **Authentication**: Secure session management
- **Authorization**: Role-based access control
- **Data Isolation**: Workspace and space-level isolation
- **Secret Management**: Secure handling of API keys
- **Audit Logging**: Comprehensive logging

## Documentation Resources

- **Code Comments**: Extensive inline documentation
- **Type Definitions**: Self-documenting TypeScript types
- **README Files**: Component-specific documentation
- **Coding Rules**: `CODING_RULES.md` files

## Getting Started Tips

1. **Understand the Architecture**: Start with this guide
2. **Explore Key Files**: Look at the files mentioned in this guide
3. **Follow Existing Patterns**: Use established patterns for consistency
4. **Write Tests**: Test-driven development approach
5. **Ask Questions**: Use the team's knowledge and experience

This guide provides a foundation for understanding the Dust project structure. The codebase is extensive and complex, so take time to explore and understand the various components and their interactions.
