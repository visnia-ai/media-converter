import Foundation

enum VideoSourceTypes {
    static let native: Set<String> = ["mov", "mp4", "m4v"]
    static let additional: Set<String> = [
        "mkv", "avi", "webm", "mts", "m2ts", "ts", "mpg", "mpeg",
        "wmv", "asf", "flv", "3gp", "3g2", "ogv", "vob"
    ]
    static let all = native.union(additional)
}
