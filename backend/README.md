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
- **`AgentLoop.swift`**: Handles the reasoning loop (ReAct loop). It parses the LLM output to decide whether to query a tool or return a final response to the user.

### 3. Language Model Integration (`LLM/`)
- **`LLMProtocol.swift`**: Defines the required interface for any LLM service (e.g., a `generate(prompt:)` function).
- **`LLMService.swift` / `MLXLLM.swift`**: Implements the LLM interactions. `MLXLLM` suggests local AI model execution using Apple's MLX framework.
- **`OutputParser.swift`**: Parses the raw text output from the LLM into structured commands (e.g., extracting tool calls vs. conversational text).

### 4. Memory Management (`Memory/`)
- **`ConversationMemory.swift`**: Keeps track of the current conversation session context.
- **`MemoryActor.swift`**: An actor ensuring thread-safe access to the memory state, preventing race conditions during asynchronous operations.
- **`ShortTermMemory.swift`**: Holds recent chat context dynamically.
- **`SQLiteStore.swift`**: Handles persistent, long-term memory storage using a SQLite database.

### 5. Tools & Execution (`Tools/`)
- **`Tool.swift` / `ToolRegistry.swift`**: Defines the base structure for tools and a registry to register and look up available tools.
- **`ToolExecutor.swift`**: Routes the LLM's requested tool calls to the actual tool instances and returns the results back to the loop.
- **`MedicalSearchTool.swift` & `CalculatorTool.swift`**: Specific tool implementations that the LLM can leverage to search for medical literature or perform math.

### 6. Supporting Services & Data (`Services/`, `Models/`, `Utils/`)
- **`PromptBuilder.swift`**: Constructs the complex system prompts, injecting current context, memory, and available tools into a format the LLM understands.
- **`ChatMessage.swift`**: The fundamental data model representing a message role (user, assistant, system) and content.
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
