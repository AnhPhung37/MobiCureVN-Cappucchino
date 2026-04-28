import Foundation
import ChatEngineCore

@main
struct Main {
    static func main() async {
        let orchestrator = ChatOrchestrator()
        let response = await orchestrator.handleMessage("I have a headache")
        print("Assistant: \(response.reply)")
    }
}
