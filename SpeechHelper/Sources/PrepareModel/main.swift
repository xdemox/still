import FluidAudio
import Foundation

@main struct PrepareModel {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let result = try await AsrModels.download(to: folder, version: .v3)
        print(result.path)
    }
}
