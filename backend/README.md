# LocalChatEngine Backend

This is the Swift-based backend for the LocalChatEngine project, an AI conversational agent designed with tool execution and memory capabilities. It is structured as a Swift Package with a core library and a command-line interface (CLI).

## How It Works

The system is designed as an autonomous Agent Loop. When a user sends a message, the message is stored in memory, and the `AgentLoop` interacts with an LLM (Large Language Model) to determine the next action. The LLM can choose to respond directly to the user or execute specific tools (like a Calculator or Medical Search). The process continues in a loop until the LLM produces a final conversational response.

## Project Structure & File Interactions

### 1. Entry Point
- **`main.swift`**: The CLI executable entry point. It initializes the `ChatOrchestrator` and sends test prompts.
- **`Package.swift`**: Defines the project configuration, specifying dependencies and defining the `ChatEngineCore` library and `ChatEngineCLI` executable target.

### 2. Orchestration & Core Logic (`Core/` & `Chat/`)
- **`ChatOrchestrator.swift`**: The high-level coordinator. It sets up the system, bridging the `ChatEngine`, `ConversationMemory`, and user I/O. 
- **`ChatEngine.swift`**: The core engine brain. It receives the resolved prompts and orchestrates the turn-by-turn workflow.

### 3. Language Model Integration (`LLM/`)
- **`LLMService.swift` / `MLXLLM.swift`**: Implements the LLM interactions. `MLXLLM` suggests local AI model execution using Apple's MLX framework.

### 4. Memory Management (`Memory/`)
- **`ConversationMemory.swift`**: Keeps track of the current conversation session context.

### 5. Tools & Execution (`Tools/`)
- **`Tool.swift` / `ToolRegistry.swift`**: Defines the base structure for tools and a registry to register and look up available tools.
- **`ToolExecutor.swift`**: Routes the LLM's requested tool calls to the actual tool instances and returns the results back to the loop.

### 6. Supporting Services & Data (`Services/`, `Models/`, `Utils/`)
- **`Logger.swift`**: Utility for consistent debugging and system logging.

---

## How to Run

### Prerequisites
Make sure you have **Swift 5.9+** installed on your system.

### Running the Project
Navigate to the `backend` directory in your terminal and use the Swift Package Manager:

1. **Build the project:**
   ```bash
   swift build
   ```

2. **Run the CLI executable:**
   ```bash
   swift run
   ```
   This will execute `main.swift`, instantiate the orchestrator, process the hardcoded prompt, and print the assistant's reply.

3. **Running tests:**
   If you have test targets configured in the future, you can run them with:
   ```bash
   swift test
   ```
