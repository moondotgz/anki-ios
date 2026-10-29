import Foundation

/// A profile, as in Anki desktop: its own collection, media and AnkiWeb
/// account.
struct Profile: Codable, Identifiable, Hashable {
    var id: String
    var name: String

    /// The profile that existed before profiles were added. It keeps the
    /// original folder, settings keys and keychain entry.
    static let legacyID = "default"

    var isLegacy: Bool { id == Profile.legacyID }

    /// Settings and keychain keys are suffixed per profile, except for the
    /// original profile, which keeps the keys it always used.
    func key(_ name: String) -> String { isLegacy ? name : "\(name).\(id)" }

    var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = docs.appendingPathComponent("Anki", isDirectory: true)
        return isLegacy ? base : base.appendingPathComponent("Profiles/\(id)", isDirectory: true)
    }

    var collectionURL: URL { folder.appendingPathComponent("collection.anki2") }
    var mediaFolder: URL { folder.appendingPathComponent("collection.media", isDirectory: true) }
    var mediaDBURL: URL { folder.appendingPathComponent("collection.media.db") }
}

enum ProfileStore {
    private static let listKey = "profiles"
    private static let currentKey = "currentProfile"

    static func load() -> [Profile] {
        if let data = UserDefaults.standard.data(forKey: listKey),
           let list = try? JSONDecoder().decode([Profile].self, from: data), !list.isEmpty
        {
            return list
        }
        return [Profile(id: Profile.legacyID, name: "User 1")]
    }

    static func save(_ profiles: [Profile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }

    static var currentID: String? {
        get { UserDefaults.standard.string(forKey: currentKey) }
        set { UserDefaults.standard.set(newValue, forKey: currentKey) }
    }

    static func current(in profiles: [Profile]) -> Profile {
        profiles.first { $0.id == currentID } ?? profiles[0]
    }

    static let settingKeys = ["syncUsername", "customSyncServer", "syncMedia", "autoSync", "syncEndpoint"]
}
