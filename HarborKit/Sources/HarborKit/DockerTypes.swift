import Foundation

/// One row from `docker ps -a --format '{{json .}}'`.
public struct DockerContainer: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: String         // "ID" field (short hash)
    public var names: String      // "Names" field (comma-separated if multiple)
    public var image: String      // "Image"
    public var state: String      // "State": "running" | "exited" | "created" | "paused"
    public var status: String     // "Status": human "Up 2 hours" / "Exited (0) 5 minutes ago"
    public var ports: String      // "Ports": "0.0.0.0:8080->8080/tcp" or ""
    public var command: String    // "Command"

    enum CodingKeys: String, CodingKey {
        case id = "ID"; case names = "Names"; case image = "Image"
        case state = "State"; case status = "Status"; case ports = "Ports"
        case command = "Command"
    }

    public var displayName: String { names.split(separator: ",").first.map(String.init) ?? id }
    public var isRunning: Bool { state == "running" }
}

/// One row from `docker images --format '{{json .}}'`.
public struct DockerImage: Codable, Identifiable, Sendable, Equatable {
    public var id: String         // "ID" (short hash)
    public var repository: String // "Repository"
    public var tag: String        // "Tag"
    public var size: String       // "Size": "142MB"
    public var createdAt: String  // "CreatedAt"

    enum CodingKeys: String, CodingKey {
        case id = "ID"; case repository = "Repository"; case tag = "Tag"
        case size = "Size"; case createdAt = "CreatedAt"
    }

    public var displayName: String {
        repository == "<none>" ? id : "\(repository):\(tag)"
    }
}

/// Pure parsing helpers — no IO, fully testable.
public enum DockerParser {
    /// Parse `docker ps -a --format '{{json .}}'` stdout (one JSON object per line).
    public static func parseContainers(_ text: String) -> [DockerContainer] {
        text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(DockerContainer.self, from: Data(line.utf8))
        }
    }

    /// Parse `docker images --format '{{json .}}'` stdout.
    public static func parseImages(_ text: String) -> [DockerImage] {
        text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(DockerImage.self, from: Data(line.utf8))
        }
    }
}
